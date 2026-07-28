import AppKit
import Darwin
import ImageIO
import SimulatorSlimmerCore

private let stopHelperNotification = Notification.Name(
  "com.neolabsapp.simulatorslimmer.stop-menu-helper"
)

@main
enum SimulatorSlimmerMenuHelper {
  @MainActor
  static func main() {
    guard let lock = HelperProcessLock.acquire() else { return }

    let application = NSApplication.shared
    #if DEBUG
      let isComputerUseTesting =
        ProcessInfo.processInfo.environment[
          "SIMULATOR_SLIMMER_COMPUTER_USE_TESTING"
        ] == "1"
      application.setActivationPolicy(
        isComputerUseTesting ? .regular : .accessory
      )
    #else
      application.setActivationPolicy(.accessory)
    #endif
    let delegate = MenuHelperDelegate(processLock: lock)
    application.delegate = delegate
    application.run()
  }
}

@MainActor
private final class MenuHelperDelegate: NSObject, NSApplicationDelegate {
  private let processLock: HelperProcessLock
  private let menuController = MenuBarController(workspace: MenuBarWorkspace())
  #if DEBUG
    private var testingWindowController: MenuTestingWindowController?
  #endif

  init(processLock: HelperProcessLock) {
    self.processLock = processLock
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    menuController.install()
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "SIMULATOR_SLIMMER_COMPUTER_USE_TESTING"
      ] == "1" {
        let controller = MenuTestingWindowController { [weak menuController] in
          menuController?.presentMenuForTesting()
        }
        testingWindowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
    #endif
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(stopHelper),
      name: stopHelperNotification,
      object: nil
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    DistributedNotificationCenter.default().removeObserver(self)
    menuController.remove()
    _ = processLock
  }

  @objc private func stopHelper() {
    NSApplication.shared.terminate(nil)
  }
}

@MainActor
private final class MenuBarController: NSObject, NSMenuDelegate {
  private let workspace: any MenuBarWorkspaceClient
  private let menu = NSMenu()
  private var statusItem: NSStatusItem?
  private var snapshotTask: Task<Void, Never>?
  private var applicationTasks: [SimulatorID: Task<Void, Never>] = [:]
  private var deviceBySubmenu: [ObjectIdentifier: MenuBarDeviceSnapshot] = [:]
  private var generation = 0
  private var isPresentingMenu = false

  init(workspace: any MenuBarWorkspaceClient) {
    self.workspace = workspace
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
  }

  func install() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(
        systemSymbolName: "iphone.gen3",
        accessibilityDescription: "Simulator Slimmer"
      )
      image?.isTemplate = true
      button.image = image
      button.target = self
      button.action = #selector(presentMenu)
      button.setAccessibilityLabel("Simulator Slimmer")
    }
    statusItem = item
  }

  func remove() {
    cancelPresentation()
    guard let statusItem else { return }
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard menu !== self.menu,
      let device = deviceBySubmenu[ObjectIdentifier(menu)],
      applicationTasks[device.id] == nil
    else { return }
    loadApplications(for: device, in: menu)
  }

  func menuDidClose(_ menu: NSMenu) {
    if menu === self.menu {
      cancelPresentation()
      return
    }
    guard let device = deviceBySubmenu[ObjectIdentifier(menu)] else { return }
    applicationTasks.removeValue(forKey: device.id)?.cancel()
    buildUnloadedDeviceMenu(menu, device: device.device)
  }

  @objc private func presentMenu() {
    guard !isPresentingMenu,
      let statusItem,
      let button = statusItem.button
    else { return }

    isPresentingMenu = true
    beginPresentation()
    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
    cancelPresentation()
  }

  func presentMenuForTesting() {
    presentMenu()
  }

  private func beginPresentation() {
    generation &+= 1
    let currentGeneration = generation
    rebuildMenu(devices: nil, error: nil)

    snapshotTask = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await workspace.menuBarSnapshot()
        guard !Task.isCancelled, generation == currentGeneration else { return }
        rebuildMenu(devices: snapshot.devices, error: nil)
      } catch is CancellationError {
        return
      } catch {
        guard generation == currentGeneration else { return }
        rebuildMenu(devices: [], error: error.localizedDescription)
      }
    }
  }

  private func cancelPresentation() {
    generation &+= 1
    snapshotTask?.cancel()
    snapshotTask = nil
    for task in applicationTasks.values {
      task.cancel()
    }
    applicationTasks.removeAll(keepingCapacity: false)
    deviceBySubmenu.removeAll(keepingCapacity: false)
    menu.removeAllItems()
    Task {
      await MenuApplicationIconLoader.shared.removeAll()
    }
    isPresentingMenu = false
  }

  private func rebuildMenu(
    devices: [MenuBarDeviceSnapshot]?,
    error: String?
  ) {
    deviceBySubmenu.removeAll(keepingCapacity: true)
    menu.removeAllItems()
    menu.addItem(
      actionItem(title: "显示主界面", action: #selector(showMainWindow))
    )
    menu.addItem(.separator())

    if let devices {
      if devices.isEmpty {
        let title = error == nil ? "没有正在运行的模拟器" : "无法读取模拟器"
        let item = disabledItem(title: title)
        item.toolTip = error
        menu.addItem(item)
      } else {
        for device in devices {
          menu.addItem(makeDeviceItem(device))
        }
      }
    } else {
      menu.addItem(disabledItem(title: "正在读取模拟器…"))
    }

    menu.addItem(.separator())
    let quitItem = actionItem(title: "退出", action: #selector(quitApplication))
    quitItem.keyEquivalent = "q"
    quitItem.keyEquivalentModifierMask = [.command]
    menu.addItem(quitItem)
    menu.update()
  }

  private func makeDeviceItem(_ snapshot: MenuBarDeviceSnapshot) -> NSMenuItem {
    let device = snapshot.device
    let title = "\(device.name) · \(memoryText(snapshot.memory?.bytes))"
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    if let image = symbolImage(
      device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
        ? "ipad"
        : "iphone"
    ) {
      item.attributedTitle = menuTitle(title, leadingImage: image)
    }

    let submenu = NSMenu()
    submenu.autoenablesItems = false
    submenu.delegate = self
    deviceBySubmenu[ObjectIdentifier(submenu)] = snapshot
    buildUnloadedDeviceMenu(submenu, device: device)
    item.submenu = submenu
    return item
  }

  private func buildUnloadedDeviceMenu(
    _ submenu: NSMenu,
    device: SimulatorDevice
  ) {
    submenu.removeAllItems()
    let showItem = actionItem(
      title: "显示模拟器",
      action: #selector(showSimulator)
    )
    showItem.image = symbolImage("rectangle.on.rectangle")
    showItem.representedObject = DeviceContext(device: device)
    submenu.addItem(showItem)
    submenu.addItem(.separator())
    submenu.addItem(disabledItem(title: "点击应用打开数据目录"))
    submenu.addItem(.separator())
    submenu.addItem(disabledItem(title: "展开后读取应用"))
  }

  private func loadApplications(
    for device: MenuBarDeviceSnapshot,
    in submenu: NSMenu
  ) {
    let currentGeneration = generation
    replaceApplicationRows(
      in: submenu,
      with: [disabledItem(title: "正在读取应用…")]
    )

    let task = Task { [weak self, weak submenu] in
      guard let self, let submenu else { return }
      do {
        let snapshot = try await workspace.applications(for: device.id)
        var items: [ApplicationMenuItem] = []
        for application in snapshot.applications where application.kind == .user {
          try Task.checkCancellation()
          let icon: NSImage?
          if let fileURL = application.icon.fileURL,
            let cgImage = await MenuApplicationIconLoader.shared.icon(at: fileURL)
          {
            icon = NSImage(
              cgImage: cgImage,
              size: NSSize(width: 18, height: 18)
            )
          } else {
            icon = nil
          }
          items.append(
            ApplicationMenuItem(
              application: application,
              memory: snapshot.memoryByBundleIdentifier[application.bundleIdentifier],
              icon: icon
            )
          )
        }
        items.sort(by: Self.sortApplications)
        guard !Task.isCancelled, generation == currentGeneration else { return }
        showApplications(items, memoryError: snapshot.memoryError, for: device, in: submenu)
        applicationTasks.removeValue(forKey: device.id)
      } catch is CancellationError {
        return
      } catch {
        guard generation == currentGeneration else { return }
        let item = disabledItem(title: "无法读取应用")
        item.toolTip = error.localizedDescription
        replaceApplicationRows(in: submenu, with: [item])
        applicationTasks.removeValue(forKey: device.id)
      }
    }
    applicationTasks[device.id] = task
  }

  private func showApplications(
    _ applications: [ApplicationMenuItem],
    memoryError: String?,
    for device: MenuBarDeviceSnapshot,
    in submenu: NSMenu
  ) {
    var rows: [NSMenuItem] = []
    if applications.isEmpty {
      rows.append(disabledItem(title: "没有用户应用"))
    } else {
      for application in applications {
        let item = actionItem(
          title:
            "\(application.application.displayName) · \(memoryText(application.memory?.bytes))",
          action: #selector(openApplicationDataDirectory)
        )
        item.image = application.icon.map(roundedApplicationIcon) ?? symbolImage("app")
        item.representedObject = ApplicationContext(
          application: application.application,
          deviceID: device.id
        )
        item.toolTip = "打开 \(application.application.displayName) 的数据目录"
        rows.append(item)
      }
    }

    if let memoryError {
      let item = disabledItem(title: "部分内存数据不可用")
      item.toolTip = memoryError
      rows.append(.separator())
      rows.append(item)
    }
    replaceApplicationRows(in: submenu, with: rows)
  }

  private func replaceApplicationRows(
    in submenu: NSMenu,
    with rows: [NSMenuItem]
  ) {
    while submenu.numberOfItems > 4 {
      submenu.removeItem(at: 4)
    }
    for row in rows {
      submenu.addItem(row)
    }
    submenu.update()
  }

  private func actionItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
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

  private func menuTitle(
    _ title: String,
    leadingImage image: NSImage
  ) -> NSAttributedString {
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)

    let attributedTitle = NSMutableAttributedString(attachment: attachment)
    attributedTitle.append(NSAttributedString(string: "  \(title)"))
    return attributedTitle
  }

  private func roundedApplicationIcon(_ source: NSImage) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    return NSImage(size: size, flipped: false) { bounds in
      NSGraphicsContext.current?.imageInterpolation = .high
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).addClip()
      source.draw(in: bounds)
      return true
    }
  }

  private func memoryText(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
  }

  @objc private func showMainWindow() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: HelperLocation.mainApplicationURL,
      configuration: configuration
    )
  }

  @objc private func showSimulator(_ sender: NSMenuItem) {
    guard let context = sender.representedObject as? DeviceContext else {
      NSSound.beep()
      return
    }
    Task {
      do {
        try await workspace.showSimulator(context.device.id)
      } catch {
        NSSound.beep()
      }
    }
  }

  @objc private func openApplicationDataDirectory(_ sender: NSMenuItem) {
    guard let context = sender.representedObject as? ApplicationContext else {
      NSSound.beep()
      return
    }
    Task {
      do {
        guard
          let url = try await workspace.dataContainer(
            for: context.deviceID,
            bundleIdentifier: context.application.bundleIdentifier
          )
        else {
          NSSound.beep()
          return
        }
        if !NSWorkspace.shared.open(url) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        NSRunningApplication
          .runningApplications(withBundleIdentifier: "com.apple.finder")
          .first?
          .activate(options: [.activateAllWindows])
      } catch {
        NSSound.beep()
      }
    }
  }

  @objc private func quitApplication() {
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.neolabsapp.simulatorslimmer"
    ) {
      application.terminate()
    }
    NSApplication.shared.terminate(nil)
  }

  private static func sortApplications(
    _ lhs: ApplicationMenuItem,
    _ rhs: ApplicationMenuItem
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

#if DEBUG
  @MainActor
  private final class MenuTestingWindowController: NSWindowController {
    private let actionTarget: MenuTestingActionTarget

    init(openMenu: @escaping @MainActor () -> Void) {
      self.actionTarget = MenuTestingActionTarget(action: openMenu)

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 112),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "菜单栏 Computer Use 测试"
      window.isReleasedWhenClosed = false

      let label = NSTextField(labelWithString: "打开真实菜单栏菜单进行验证")
      label.alignment = .center

      let button = NSButton(
        title: "打开菜单", target: actionTarget,
        action: #selector(
          MenuTestingActionTarget.performAction
        ))
      button.bezelStyle = .rounded
      button.setAccessibilityIdentifier("menu-testing.open")

      let stack = NSStackView(views: [label, button])
      stack.orientation = .vertical
      stack.alignment = .centerX
      stack.spacing = 12
      stack.translatesAutoresizingMaskIntoConstraints = false

      let contentView = NSView()
      contentView.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
      window.contentView = contentView
      window.center()
      super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) 未实现")
    }
  }

  @MainActor
  private final class MenuTestingActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
      self.action = action
    }

    @objc func performAction() {
      action()
    }
  }
#endif

private struct ApplicationMenuItem {
  let application: SimulatorApplication
  let memory: ApplicationMemorySnapshot?
  let icon: NSImage?
}

private final class DeviceContext: NSObject {
  let device: SimulatorDevice

  init(device: SimulatorDevice) {
    self.device = device
  }
}

private final class ApplicationContext: NSObject {
  let application: SimulatorApplication
  let deviceID: SimulatorID

  init(application: SimulatorApplication, deviceID: SimulatorID) {
    self.application = application
    self.deviceID = deviceID
  }
}

private actor MenuApplicationIconLoader {
  static let shared = MenuApplicationIconLoader()

  private var cache: [URL: CGImage] = [:]

  func icon(at url: URL) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let key = url.standardizedFileURL
    if let cached = cache[key] {
      return cached
    }
    guard
      let source = CGImageSourceCreateWithURL(key as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 36,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      )
    else { return nil }
    guard !Task.isCancelled else { return nil }
    cache[key] = image
    return image
  }

  func removeAll() {
    cache.removeAll(keepingCapacity: false)
  }
}

private enum HelperLocation {
  static let mainApplicationURL: URL = {
    Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }()
}

private final class HelperProcessLock {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  static func acquire() -> HelperProcessLock? {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("SimulatorSlimmer", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return nil
    }

    let path = directory.appendingPathComponent("menu-helper.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    for attempt in 0..<20 {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        return HelperProcessLock(descriptor: descriptor)
      }
      if attempt < 19 {
        usleep(50_000)
      }
    }
    close(descriptor)
    return nil
  }
}
