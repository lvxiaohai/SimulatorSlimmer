import AppKit
import SimulatorSlimmerCore
import SwiftUI

@MainActor
final class SimulatorSlimmerAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    let defaults = UserDefaults.standard
    let menuBarEnabled =
      defaults.object(forKey: "menuBarEnabled") == nil
      ? true
      : defaults.bool(forKey: "menuBarEnabled")
    return !menuBarEnabled
  }
}

@main
@MainActor
struct SimulatorSlimmerApp: App {
  @NSApplicationDelegateAdaptor(SimulatorSlimmerAppDelegate.self)
  private var appDelegate
  @AppStorage("menuBarEnabled") private var menuBarEnabled = true
  @State private var model: AppModel
  @State private var menuBarModel: MenuBarModel

  init() {
    let workspace = WorkspaceFactory.make()
    _model = State(initialValue: AppModel(workspace: workspace))
    _menuBarModel = State(initialValue: MenuBarModel(workspace: workspace))
  }

  var body: some Scene {
    Window("Simulator Slimmer", id: "main") {
      WorkspaceRootView(model: model)
        .environment(model)
        .tint(.mint)
        .frame(minWidth: 980, minHeight: 640)
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      SimulatorSlimmerCommands(model: model)
    }

    MenuBarExtra(
      "Simulator Slimmer",
      systemImage: "iphone.gen3",
      isInserted: $menuBarEnabled
    ) {
      MenuBarContent(model: menuBarModel)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MenuBarContent: View {
  @Bindable var model: MenuBarModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      Button {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        Label("显示主界面", systemImage: "macwindow")
      }

      Divider()

      if model.isRefreshing {
        Text("正在读取模拟器…")
      } else if let refreshError = model.refreshError {
        Text("读取失败：\(refreshError)")
      } else if model.devices.isEmpty {
        Text("没有已启动的模拟器")
      } else {
        ForEach(model.devices) { device in
          deviceMenu(device)
        }
      }

      Divider()

      Button("退出") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      model.refresh()
    }
    .onDisappear {
      model.cancelRefresh()
    }
  }

  private func deviceMenu(_ item: MenuBarDeviceItem) -> some View {
    Menu {
      if item.applications.isEmpty {
        Text(
          item.applicationError == nil
            ? "没有用户应用"
            : "应用读取失败"
        )
      } else {
        ForEach(item.applications) { application in
          Button {
            model.openDataContainer(
              for: application.application,
              deviceID: item.snapshot.device.id
            )
          } label: {
            Label {
              Text(
                "\(application.application.displayName)  \(memoryText(application.memory?.bytes))"
              )
            } icon: {
              if let icon = application.icon {
                Image(nsImage: icon)
              } else {
                Image(systemName: "app")
              }
            }
          }
        }

        if item.applicationError != nil {
          Divider()
          Text("部分应用内存暂不可用")
        }
      }
    } label: {
      Label {
        Text(
          "\(item.snapshot.device.name)  \(memoryText(item.snapshot.memory?.bytes))"
        )
      } icon: {
        Image(systemName: deviceSymbol(for: item.snapshot.device))
      }
    }
  }

  private func memoryText(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
  }

  private func deviceSymbol(for device: SimulatorDevice) -> String {
    device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
      ? "ipad"
      : "iphone"
  }
}
