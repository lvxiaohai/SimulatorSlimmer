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
  @State private var menuBarController: MenuBarController

  init() {
    let workspace = WorkspaceFactory.make()
    let menuBarModel = MenuBarContentModel(workspace: workspace)
    _model = State(initialValue: AppModel(workspace: workspace))
    _menuBarController = State(
      initialValue: MenuBarController(model: menuBarModel)
    )
  }

  var body: some Scene {
    Window("Simulator Slimmer", id: "main") {
      WorkspaceRootView(model: model)
        .environment(model)
        .tint(.mint)
        .frame(minWidth: 980, minHeight: 640)
        .background {
          MenuBarInstaller(
            controller: menuBarController,
            isEnabled: menuBarEnabled
          )
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      SimulatorSlimmerCommands(model: model)
    }
  }
}

private struct MenuBarInstaller: View {
  let controller: MenuBarController
  let isEnabled: Bool
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        configureController()
      }
      .onChange(of: isEnabled) {
        configureController()
      }
  }

  private func configureController() {
    controller.configure(isEnabled: isEnabled) {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

@MainActor
private final class MenuBarController: NSObject, NSMenuDelegate {
  private let model: MenuBarContentModel
  private let menu = NSMenu()
  private var statusItem: NSStatusItem?
  private var showMainWindow: (() -> Void)?
  private var isPreparingMenu = false

  init(model: MenuBarContentModel) {
    self.model = model
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    model.onContentChange = { [weak self] in
      self?.replaceDynamicMenuContent()
    }
  }

  func configure(
    isEnabled: Bool,
    showMainWindow: @escaping () -> Void
  ) {
    self.showMainWindow = showMainWindow
    if isEnabled {
      installStatusItemIfNeeded()
    } else {
      removeStatusItem()
    }
  }

  private func installStatusItemIfNeeded() {
    guard statusItem == nil else { return }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      let image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel("Simulator Slimmer")
      button.target = self
      button.action = #selector(presentMenu)
    }
    self.statusItem = statusItem
    installMenuContent()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    model.cancelRefresh()
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    isPreparingMenu = false
  }

  private func installMenuContent() {
    menu.removeAllItems()
    menu.addItem(
      menuItem(
        title: L10n.text("menu-bar.show-main-window"),
        action: #selector(showMainWindowAction)
      )
    )
    menu.addItem(.separator())
    menu.addItem(.separator())
    let quitItem = menuItem(
      title: L10n.text("menu-bar.quit"),
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    menu.addItem(quitItem)
    replaceDynamicMenuContent()
  }

  private func replaceDynamicMenuContent() {
    guard menu.numberOfItems >= 4 else { return }
    while menu.numberOfItems > 4 {
      menu.removeItem(at: 2)
    }
    var insertionIndex = 2
    func insert(_ item: NSMenuItem) {
      menu.insertItem(item, at: insertionIndex)
      insertionIndex += 1
    }

    if !model.deviceItems.isEmpty {
      for deviceItem in model.deviceItems {
        insert(makeDeviceMenuItem(deviceItem))
      }
      if model.isRefreshing {
        insert(.separator())
        insert(disabledItem(title: L10n.text("menu-bar.loading")))
      }
      if let refreshError = model.refreshError {
        insert(.separator())
        let item = disabledItem(title: L10n.text("menu-bar.device-update-failed"))
        item.toolTip = refreshError
        insert(item)
        insert(
          menuItem(
            title: L10n.text("menu-bar.reload"),
            action: #selector(retryRefreshAction)
          )
        )
      }
    } else if model.isRefreshing {
      insert(disabledItem(title: L10n.text("menu-bar.loading")))
    } else if let refreshError = model.refreshError {
      let item = disabledItem(title: L10n.text("menu-bar.load-failed"))
      item.toolTip = refreshError
      insert(item)
      insert(
        menuItem(
          title: L10n.text("menu-bar.reload"),
          action: #selector(retryRefreshAction)
        )
      )
    } else {
      insert(disabledItem(title: L10n.text("menu-bar.no-running-device")))
    }

    if let actionError = model.actionErrorMessage {
      insert(.separator())
      insert(disabledItem(title: "⚠︎ \(actionError)"))
    }
    menu.update()
  }

  private func makeDeviceMenuItem(_ item: MenuBarDeviceItem) -> NSMenuItem {
    let device = item.deviceSnapshot.device
    let title = "\(device.name) · \(memoryText(item.deviceSnapshot.memory?.bytes))"
    let deviceItem = NSMenuItem(
      title: title,
      action: nil,
      keyEquivalent: ""
    )
    if let image = symbolImage(
      device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
        ? "ipad"
        : "iphone"
    ) {
      deviceItem.attributedTitle = menuTitle(title, leadingImage: image)
    }

    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let showSimulatorItem = menuItem(
      title: L10n.text("menu-bar.show-device"),
      action: #selector(showSimulatorAction)
    )
    showSimulatorItem.image = symbolImage("rectangle.on.rectangle")
    showSimulatorItem.representedObject = DeviceMenuContext(device: device)
    submenu.addItem(showSimulatorItem)
    submenu.addItem(.separator())
    submenu.addItem(disabledItem(title: L10n.text("menu-bar.application-directories")))
    submenu.addItem(.separator())

    if item.applications.isEmpty {
      submenu.addItem(
        disabledItem(
          title: item.applicationLoadError == nil
            ? L10n.text("menu-bar.no-user-applications")
            : L10n.text("menu-bar.application-load-failed")
        )
      )
    } else {
      for application in item.applications {
        let applicationItem = menuItem(
          title:
            "\(application.application.displayName) · \(memoryText(application.memory?.bytes))",
          action: #selector(openApplicationDataContainer)
        )
        applicationItem.image =
          application.icon.map(roundedApplicationIcon)
          ?? symbolImage("app")
        applicationItem.toolTip = L10n.formatted(
          "menu-bar.open-application-directory",
          application.application.displayName
        )
        applicationItem.representedObject = ApplicationDataMenuContext(
          application: application.application,
          deviceID: device.id
        )
        submenu.addItem(applicationItem)
      }

      if item.applicationLoadError != nil {
        submenu.addItem(.separator())
        let errorItem = disabledItem(
          title: L10n.text("menu-bar.partial-application-data")
        )
        errorItem.toolTip = item.applicationLoadError
        submenu.addItem(errorItem)
      }
    }

    if item.applicationLoadError != nil {
      let retryItem = menuItem(
        title: L10n.text("menu-bar.reload-applications"),
        action: #selector(retryApplicationsAction)
      )
      submenu.addItem(retryItem)
    }

    deviceItem.submenu = submenu
    return deviceItem
  }

  private func menuItem(
    title: String,
    action: Selector,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
  }

  private func disabledItem(title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func symbolImage(_ name: String) -> NSImage? {
    guard
      let source = NSImage(systemSymbolName: name, accessibilityDescription: nil),
      let image = source.copy() as? NSImage
    else { return nil }
    image.isTemplate = true
    image.size = NSSize(width: 16, height: 16)
    return image
  }

  private func roundedApplicationIcon(_ source: NSImage) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    return NSImage(size: size, flipped: false) { bounds in
      NSGraphicsContext.current?.imageInterpolation = .high
      NSBezierPath(
        roundedRect: bounds,
        xRadius: 4,
        yRadius: 4
      ).addClip()
      source.draw(in: bounds)
      return true
    }
  }

  private func menuTitle(_ title: String, leadingImage image: NSImage) -> NSAttributedString {
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)

    let attributedTitle = NSMutableAttributedString(attachment: attachment)
    attributedTitle.append(NSAttributedString(string: "  \(title)"))
    return attributedTitle
  }

  private func memoryText(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
  }

  @objc private func presentMenu() {
    guard
      !isPreparingMenu,
      let statusItem,
      let button = statusItem.button
    else { return }

    isPreparingMenu = true
    model.refreshContent(force: true)
    replaceDynamicMenuContent()
    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
    isPreparingMenu = false
  }

  @objc private func showMainWindowAction() {
    showMainWindow?()
  }

  @objc private func openApplicationDataContainer(_ sender: NSMenuItem) {
    guard let context = sender.representedObject as? ApplicationDataMenuContext else {
      NSSound.beep()
      return
    }
    model.openApplicationDataDirectory(
      for: context.application,
      deviceID: context.deviceID
    )
  }

  @objc private func showSimulatorAction(_ sender: NSMenuItem) {
    guard let context = sender.representedObject as? DeviceMenuContext else {
      NSSound.beep()
      return
    }
    model.showDeviceInSimulator(context.device)
  }

  @objc private func retryRefreshAction() {
    model.refreshContent(force: true)
  }

  @objc private func retryApplicationsAction() {
    model.refreshContent(force: true)
  }

  @objc private func quitApplication() {
    NSApplication.shared.terminate(nil)
  }
}

private final class ApplicationDataMenuContext: NSObject {
  let application: SimulatorApplication
  let deviceID: SimulatorID

  init(
    application: SimulatorApplication,
    deviceID: SimulatorID
  ) {
    self.application = application
    self.deviceID = deviceID
  }
}

private final class DeviceMenuContext: NSObject {
  let device: SimulatorDevice

  init(device: SimulatorDevice) {
    self.device = device
  }
}

struct MenuBarApplicationItem {
  let application: SimulatorApplication
  let memory: ApplicationMemorySnapshot?
  let icon: NSImage?
}

struct MenuBarDeviceItem {
  let deviceSnapshot: MenuBarDeviceSnapshot
  let applications: [MenuBarApplicationItem]
  let applicationLoadError: String?
}

@MainActor
final class MenuBarContentModel {
  private let workspace: any SimulatorWorkspaceClient

  private(set) var deviceItems: [MenuBarDeviceItem] = []
  private(set) var isRefreshing = false
  private(set) var refreshError: String?
  private(set) var actionErrorMessage: String?

  private var refreshTask: Task<Void, Never>?
  private var menuActionTask: Task<Void, Never>?
  private var refreshGeneration = 0
  var onContentChange: (() -> Void)?

  init(workspace: any SimulatorWorkspaceClient) {
    self.workspace = workspace
  }

  @discardableResult
  func refreshContent(force: Bool = false) -> Task<Void, Never> {
    if !force, let refreshTask {
      return refreshTask
    }

    refreshTask?.cancel()
    refreshGeneration += 1
    let generation = refreshGeneration
    isRefreshing = true
    refreshError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await workspace.menuBarSnapshot()
        var resolvedDevices: [MenuBarDeviceItem] = []
        resolvedDevices.reserveCapacity(snapshot.devices.count)

        for deviceSnapshot in snapshot.devices {
          try Task.checkCancellation()
          let deviceID = deviceSnapshot.device.id

          do {
            let applicationSnapshot = try await workspace.applications(
              for: deviceID
            )
            var applications: [MenuBarApplicationItem] = []
            for application in applicationSnapshot.applications where application.kind == .user {
              try Task.checkCancellation()
              let image: NSImage?
              if let fileURL = application.icon.fileURL,
                let cgImage = await ApplicationIconLoader.shared.icon(
                  at: fileURL,
                  maximumPixelSize: 36
                )
              {
                image = NSImage(
                  cgImage: cgImage,
                  size: NSSize(width: 18, height: 18)
                )
              } else {
                image = nil
              }
              applications.append(
                MenuBarApplicationItem(
                  application: application,
                  memory: applicationSnapshot.memoryByBundleIdentifier[
                    application.bundleIdentifier
                  ],
                  icon: image
                )
              )
            }
            applications.sort(by: Self.sortApplicationsByMemory)
            resolvedDevices.append(
              MenuBarDeviceItem(
                deviceSnapshot: deviceSnapshot,
                applications: applications,
                applicationLoadError: applicationSnapshot.memoryError
              )
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            resolvedDevices.append(
              MenuBarDeviceItem(
                deviceSnapshot: deviceSnapshot,
                applications: [],
                applicationLoadError: error.localizedDescription
              )
            )
          }
        }

        guard !Task.isCancelled else { return }
        deviceItems = resolvedDevices
        isRefreshing = false
        refreshTask = nil
        guard generation == refreshGeneration else { return }
        onContentChange?()
      } catch is CancellationError {
        guard generation == refreshGeneration else { return }
        finishRefresh()
      } catch {
        guard generation == refreshGeneration else { return }
        refreshError = error.localizedDescription
        finishRefresh()
      }
    }
    refreshTask = task
    return task
  }

  func cancelRefresh() {
    refreshGeneration += 1
    refreshTask?.cancel()
    refreshTask = nil
    isRefreshing = false
  }

  func openApplicationDataDirectory(
    for application: SimulatorApplication,
    deviceID: SimulatorID
  ) {
    menuActionTask?.cancel()
    clearActionError()
    menuActionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let folderURL = try await workspace.dataContainer(
          for: deviceID,
          bundleIdentifier: application.bundleIdentifier
        )
        guard !Task.isCancelled else { return }
        guard let folderURL else {
          actionErrorMessage = L10n.formatted(
            "menu-bar.data-directory-missing",
            application.displayName
          )
          menuActionTask = nil
          onContentChange?()
          NSSound.beep()
          return
        }
        FinderFolderOpener.open(folderURL)
        actionErrorMessage = nil
        menuActionTask = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        actionErrorMessage = L10n.formatted(
          "menu-bar.data-directory-open-failed",
          application.displayName
        )
        menuActionTask = nil
        onContentChange?()
        NSSound.beep()
      }
    }
  }

  func showDeviceInSimulator(_ device: SimulatorDevice) {
    menuActionTask?.cancel()
    clearActionError()
    menuActionTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await workspace.showSimulator(device.id)
        guard !Task.isCancelled else { return }
        actionErrorMessage = nil
        menuActionTask = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        actionErrorMessage = L10n.formatted(
          "menu-bar.show-device-failed",
          device.name
        )
        menuActionTask = nil
        onContentChange?()
        NSSound.beep()
      }
    }
  }

  private func finishRefresh() {
    isRefreshing = false
    refreshTask = nil
    onContentChange?()
  }

  private func clearActionError() {
    guard actionErrorMessage != nil else { return }
    actionErrorMessage = nil
    onContentChange?()
  }

  private static func sortApplicationsByMemory(
    _ lhs: MenuBarApplicationItem,
    _ rhs: MenuBarApplicationItem
  ) -> Bool {
    let lhsBytes = lhs.memory?.bytes ?? -1
    let rhsBytes = rhs.memory?.bytes ?? -1
    if lhsBytes != rhsBytes {
      return lhsBytes > rhsBytes
    }
    return
      lhs.application.displayName.localizedStandardCompare(
        rhs.application.displayName
      ) == .orderedAscending
  }
}

@MainActor
enum FinderFolderOpener {
  static func open(_ folderURL: URL) {
    if !NSWorkspace.shared.open(folderURL) {
      NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }
    NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.finder")
      .first?
      .activate(options: [.activateAllWindows])
  }
}
