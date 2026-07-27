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
    let menuBarModel = MenuBarModel(workspace: workspace)
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
  private let model: MenuBarModel
  private var statusItem: NSStatusItem?
  private var showMainWindow: (() -> Void)?
  private var isMenuOpen = false
  private var needsMenuRebuild = false

  init(model: MenuBarModel) {
    self.model = model
    super.init()
    model.didChange = { [weak self] in
      guard let self else { return }
      if isMenuOpen {
        needsMenuRebuild = true
      } else {
        rebuildMenu()
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
    isMenuOpen = true
    // AppKit 不允许在菜单开关回调中同步修改菜单结构。
    DispatchQueue.main.async { [weak self] in
      self?.model.refresh()
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    isMenuOpen = false
    // 先让当前菜单项的 action 完整执行，再替换菜单结构。
    DispatchQueue.main.async { [weak self] in
      guard let self, !isMenuOpen, needsMenuRebuild else { return }
      needsMenuRebuild = false
      rebuildMenu()
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
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
    self.statusItem = statusItem
    rebuildMenu()
    model.refresh()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    model.cancelRefresh()
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    isMenuOpen = false
    needsMenuRebuild = false
  }

  private func rebuildMenu() {
    guard let menu = statusItem?.menu else { return }
    menu.removeAllItems()

    menu.addItem(
      menuItem(
        title: "显示主界面",
        action: #selector(showMainWindowAction)
      )
    )
    menu.addItem(.separator())

    if !model.devices.isEmpty {
      for device in model.devices {
        menu.addItem(deviceMenuItem(device))
      }
      if let refreshError = model.refreshError {
        menu.addItem(.separator())
        let item = disabledItem(title: "设备数据更新失败")
        item.toolTip = refreshError
        menu.addItem(item)
        menu.addItem(
          menuItem(
            title: "重新读取",
            action: #selector(retryRefreshAction)
          )
        )
      }
    } else if model.isRefreshing {
      menu.addItem(disabledItem(title: "正在读取模拟器…"))
    } else if let refreshError = model.refreshError {
      let item = disabledItem(title: "读取失败")
      item.toolTip = refreshError
      menu.addItem(item)
      menu.addItem(
        menuItem(
          title: "重新读取",
          action: #selector(retryRefreshAction)
        )
      )
    } else {
      menu.addItem(disabledItem(title: "没有已启动的模拟器"))
    }

    if let actionError = model.actionError {
      menu.addItem(.separator())
      menu.addItem(disabledItem(title: "⚠︎ \(actionError)"))
    }

    menu.addItem(.separator())
    let quitItem = menuItem(
      title: "退出",
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    menu.addItem(quitItem)
  }

  private func deviceMenuItem(_ item: MenuBarDeviceItem) -> NSMenuItem {
    let device = item.snapshot.device
    let title = "\(device.name) · \(memoryText(item.snapshot.memory?.bytes))"
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
      title: "显示此模拟器",
      action: #selector(showSimulatorAction)
    )
    showSimulatorItem.image = symbolImage("rectangle.on.rectangle")
    showSimulatorItem.representedObject = MenuBarDeviceAction(
      deviceID: device.id,
      name: device.name
    )
    submenu.addItem(showSimulatorItem)
    submenu.addItem(.separator())
    submenu.addItem(disabledItem(title: "应用数据目录"))
    submenu.addItem(.separator())

    if item.applications.isEmpty {
      submenu.addItem(
        disabledItem(
          title: item.applicationError == nil
            ? "没有用户应用"
            : "应用读取失败"
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
        applicationItem.toolTip = "打开 \(application.application.displayName) 的数据目录"
        applicationItem.representedObject = MenuBarApplicationAction(
          application: application.application,
          deviceID: device.id
        )
        submenu.addItem(applicationItem)
      }

      if item.applicationError != nil {
        submenu.addItem(.separator())
        let errorItem = disabledItem(title: "部分应用信息暂不可用")
        errorItem.toolTip = item.applicationError
        submenu.addItem(errorItem)
      }
    }

    if item.applicationError != nil {
      let retryItem = menuItem(
        title: "重新读取应用",
        action: #selector(retryApplicationsAction)
      )
      retryItem.representedObject = MenuBarDeviceAction(
        deviceID: device.id,
        name: device.name
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

  @objc private func showMainWindowAction() {
    showMainWindow?()
  }

  @objc private func openApplicationDataContainer(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? MenuBarApplicationAction else {
      NSSound.beep()
      return
    }
    model.openDataContainer(
      for: action.application,
      deviceID: action.deviceID
    )
  }

  @objc private func showSimulatorAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? MenuBarDeviceAction else {
      NSSound.beep()
      return
    }
    model.showSimulator(action.deviceID, name: action.name)
  }

  @objc private func retryRefreshAction() {
    model.refresh()
  }

  @objc private func retryApplicationsAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? MenuBarDeviceAction else {
      NSSound.beep()
      return
    }
    model.retryApplications(for: action.deviceID)
  }

  @objc private func quitApplication() {
    NSApplication.shared.terminate(nil)
  }
}

private final class MenuBarApplicationAction: NSObject {
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

private final class MenuBarDeviceAction: NSObject {
  let deviceID: SimulatorID
  let name: String

  init(deviceID: SimulatorID, name: String) {
    self.deviceID = deviceID
    self.name = name
  }
}
