import AppKit
import SimulatorSlimmerCore
import Sparkle
import SwiftUI

private let stopMenuHelperNotification = Notification.Name(
  "com.neolabsapp.simulatorslimmer.stop-menu-helper"
)

@MainActor
final class SimulatorSlimmerAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
@MainActor
struct SimulatorSlimmerApp: App {
  @NSApplicationDelegateAdaptor(SimulatorSlimmerAppDelegate.self)
  private var appDelegate
  @AppStorage("menuBarEnabled") private var menuBarEnabled = true
  @State private var model: AppModel
  @State private var menuHelperManager = MenuHelperManager()
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  init() {
    _model = State(initialValue: AppModel(workspace: WorkspaceFactory.make()))
  }

  var body: some Scene {
    Window("Simulator Slimmer", id: "main") {
      WorkspaceRootView(model: model)
        .environment(model)
        .tint(.mint)
        .frame(minWidth: 980, minHeight: 640)
        .background {
          MenuHelperInstaller(
            manager: menuHelperManager,
            isEnabled: menuBarEnabled
          )
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      SimulatorSlimmerCommands(
        model: model,
        updaterController: updaterController
      )
    }
  }
}

private struct MenuHelperInstaller: View {
  let manager: MenuHelperManager
  let isEnabled: Bool

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        manager.configure(isEnabled: isEnabled)
      }
      .onChange(of: isEnabled) {
        manager.configure(isEnabled: isEnabled)
      }
  }
}

@MainActor
final class MenuHelperManager {
  private var launchedProcess: Process?
  private var pendingLaunchTask: Task<Void, Never>?
  private var isEnabled = false
  private var remainingLaunchAttempts = 0

  func configure(isEnabled: Bool) {
    self.isEnabled = isEnabled
    pendingLaunchTask?.cancel()
    pendingLaunchTask = nil
    if isEnabled {
      remainingLaunchAttempts = 5
      stopRunningHelper()
      launchIfNeeded()
    } else {
      remainingLaunchAttempts = 0
      stopRunningHelper()
    }
  }

  private func stopRunningHelper() {
    launchedProcess?.terminate()
    launchedProcess = nil
    DistributedNotificationCenter.default().post(
      name: stopMenuHelperNotification,
      object: nil
    )
  }

  private func scheduleLaunch(after delay: Duration) {
    pendingLaunchTask?.cancel()
    pendingLaunchTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.launchIfNeeded()
    }
  }

  private func launchIfNeeded() {
    guard isEnabled,
      remainingLaunchAttempts > 0,
      launchedProcess?.isRunning != true
    else { return }
    remainingLaunchAttempts -= 1
    let executableURL =
      Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("SimulatorSlimmerMenu.app", isDirectory: true)
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("SimulatorSlimmerMenu", isDirectory: false)
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      return
    }

    let process = Process()
    process.executableURL = executableURL
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self, weak process] _ in
      Task { @MainActor in
        guard self?.launchedProcess === process else { return }
        self?.launchedProcess = nil
        guard self?.isEnabled == true,
          self?.remainingLaunchAttempts ?? 0 > 0
        else { return }
        self?.scheduleLaunch(after: .milliseconds(300))
      }
    }
    do {
      try process.run()
      launchedProcess = process
    } catch {
      launchedProcess = nil
      if isEnabled, remainingLaunchAttempts > 0 {
        scheduleLaunch(after: .milliseconds(300))
      }
    }
  }
}
