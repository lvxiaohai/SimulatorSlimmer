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
  private var isTrackingMenu = false
  private var isPreparingMenu = false
  private var hasDeferredMenuUpdate = false

  init(model: MenuBarContentModel) {
    self.model = model
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    model.onContentChange = { [weak self] in
      guard let self else { return }
      if isTrackingMenu {
        hasDeferredMenuUpdate = true
      } else {
        rebuildMenuContent()
      }
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

  func menuWillOpen(_ menu: NSMenu) {
    isTrackingMenu = true
  }

  func menuDidClose(_ menu: NSMenu) {
    isTrackingMenu = false
    // 先让当前菜单项的 action 完整执行，再替换菜单结构。
    DispatchQueue.main.async { [weak self] in
      guard let self, !isTrackingMenu, hasDeferredMenuUpdate else { return }
      hasDeferredMenuUpdate = false
      rebuildMenuContent()
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
    rebuildMenuContent()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    model.cancelRefresh()
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    isTrackingMenu = false
    isPreparingMenu = false
    hasDeferredMenuUpdate = false
  }

  private func rebuildMenuContent() {
    menu.removeAllItems()

    menu.addItem(
      menuItem(
        title: L10n.text("menu-bar.show-main-window"),
        action: #selector(showMainWindowAction)
      )
    )
    menu.addItem(.separator())

    if !model.deviceItems.isEmpty {
      for deviceItem in model.deviceItems {
        menu.addItem(makeDeviceMenuItem(deviceItem))
      }
      if let refreshError = model.refreshError {
        menu.addItem(.separator())
        let item = disabledItem(title: L10n.text("menu-bar.device-update-failed"))
        item.toolTip = refreshError
        menu.addItem(item)
        menu.addItem(
          menuItem(
            title: L10n.text("menu-bar.reload"),
            action: #selector(retryRefreshAction)
          )
        )
      }
    } else if model.isRefreshing {
      menu.addItem(disabledItem(title: L10n.text("menu-bar.loading")))
    } else if let refreshError = model.refreshError {
      let item = disabledItem(title: L10n.text("menu-bar.load-failed"))
      item.toolTip = refreshError
      menu.addItem(item)
      menu.addItem(
        menuItem(
          title: L10n.text("menu-bar.reload"),
          action: #selector(retryRefreshAction)
        )
      )
    } else {
      menu.addItem(disabledItem(title: L10n.text("menu-bar.no-running-device")))
    }

    if let actionError = model.actionErrorMessage {
      menu.addItem(.separator())
      menu.addItem(disabledItem(title: "⚠︎ \(actionError)"))
    }

    menu.addItem(.separator())
    let quitItem = menuItem(
      title: L10n.text("menu-bar.quit"),
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    menu.addItem(quitItem)
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
        applicationItem.image = application.icon ?? symbolImage("app")
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
    let refreshTask = model.refreshContent(force: true)
    Task { [weak self, weak button] in
      await refreshTask.value
      guard
        let self,
        let button,
        self.statusItem === statusItem
      else { return }

      rebuildMenuContent()
      statusItem.menu = menu
      button.performClick(nil)
      statusItem.menu = nil
      isPreparingMenu = false
    }
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
