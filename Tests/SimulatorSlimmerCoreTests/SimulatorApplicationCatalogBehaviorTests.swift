import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("模拟器应用目录行为")
struct SimulatorApplicationCatalogBehaviorTests {
  @Test("解析 simctl 返回的 OpenStep 属性列表")
  func parsesOpenStepApplicationList() async throws {
    try await withApplicationFixture { fixture in
      let bundle = try fixture.makeBundle(named: "OpenStep", info: [:])
      let output = """
        {
          "com.example.openstep" = {
            ApplicationType = User;
            Bundle = "\(bundle.absoluteString)";
            CFBundleDisplayName = "OpenStep 应用";
            CFBundleIdentifier = "com.example.openstep";
            CFBundleVersion = 5;
            DataContainer = "(null)";
          };
        }
        """
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: output)
      )

      let application = try #require(
        try await catalog.applications(
          for: SimulatorID(rawValue: "10101010-2020-4030-8040-505050505050")
        ).first
      )

      #expect(application.kind == .user)
      #expect(application.displayName == "OpenStep 应用")
      #expect(application.bundleIdentifier == "com.example.openstep")
      #expect(application.bundleURL == bundle.standardizedFileURL)
      #expect(application.buildVersion == "5")
      #expect(application.dataContainerURL == nil)
    }
  }

  @Test("返回用户、系统和未知应用")
  func returnsEveryApplicationWithBundleMetadata() async throws {
    try await withApplicationFixture { fixture in
      let userBundle = try fixture.makeBundle(
        named: "Demo",
        info: [
          "CFBundleDisplayName": "包内名称",
          "CFBundleShortVersionString": "2.3.0",
          "CFBundleVersion": "42",
          "CFBundleIcons": [
            "CFBundlePrimaryIcon": [
              "CFBundleIconName": "AppIcon",
              "CFBundleIconFiles": ["AppIcon60x60"],
            ]
          ],
        ],
        files: ["AppIcon60x60@2x.png"]
      )
      let dataContainer = fixture.root.appendingPathComponent(
        "Containers/Data/Application/USER",
        isDirectory: true
      )
      let output = applicationListOutput([
        "com.example.demo": [
          "ApplicationType": "User",
          "Bundle": userBundle.absoluteString,
          "CFBundleDisplayName": "演示应用",
          "CFBundleIdentifier": "com.example.demo",
          "CFBundleVersion": "1",
          "DataContainer": dataContainer.absoluteString,
        ],
        "com.apple.system": [
          "ApplicationType": "System",
          "Bundle": fixture.root.appendingPathComponent("System.app").absoluteString,
          "CFBundleName": "系统应用",
          "CFBundleIdentifier": "com.apple.system",
          "DataContainer": "(null)",
        ],
        "org.example.unknown": [
          "ApplicationType": "FutureType",
          "Bundle": fixture.root.appendingPathComponent("Unknown.app").absoluteString,
          "CFBundleIdentifier": "org.example.unknown",
        ],
      ])
      let runner = ApplicationCatalogRunner(output: output)
      let catalog = SimulatorApplicationCatalog(runner: runner)
      let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

      let applications = try await catalog.applications(for: deviceID)
      let byID = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundleIdentifier, $0) })
      let user = try #require(byID["com.example.demo"])
      let system = try #require(byID["com.apple.system"])

      #expect(applications.count == 3)
      #expect(user.kind == .user)
      #expect(user.displayName == "演示应用")
      #expect(user.bundleURL == userBundle.standardizedFileURL)
      #expect(user.dataContainerURL == dataContainer.standardizedFileURL)
      #expect(user.marketingVersion == "2.3.0")
      #expect(user.buildVersion == "42")
      #expect(user.icon.declaredName == "AppIcon")
      #expect(
        user.icon.fileURL
          == userBundle.appendingPathComponent("AppIcon60x60@2x.png").standardizedFileURL
      )
      #expect(system.kind == .system)
      #expect(system.displayName == "系统应用")
      #expect(system.dataContainerURL == nil)
      #expect(byID["org.example.unknown"]?.kind == .unknown)
      #expect(byID["org.example.unknown"]?.displayName == "org.example.unknown")

      let command = try #require(await runner.receivedCommands().first)
      #expect(command.executable.path == "/usr/bin/xcrun")
      #expect(command.arguments == ["simctl", "listapps", deviceID.rawValue])
    }
  }

  @Test("包信息不可读时使用 listapps 字段和稳定名称回退")
  func fallsBackToListAppsMetadata() async throws {
    try await withApplicationFixture { fixture in
      let pathOnlyBundle = fixture.root.appendingPathComponent("PathOnly.app")
      let output = applicationListOutput([
        "com.example.named": [
          "ApplicationType": "user",
          "Path": pathOnlyBundle.path,
          "CFBundleName": "回退名称",
          "CFBundleIdentifier": "com.example.named",
          "CFBundleShortVersionString": "7.1",
          "CFBundleVersion": 19,
        ],
        "com.example.identifier-only": [
          "CFBundleIdentifier": "com.example.identifier-only"
        ],
      ])
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: output)
      )

      let applications = try await catalog.applications(
        for: SimulatorID(rawValue: "22222222-3333-4444-8555-666666666666")
      )
      let byID = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundleIdentifier, $0) })

      #expect(byID["com.example.named"]?.displayName == "回退名称")
      #expect(byID["com.example.named"]?.bundleURL == pathOnlyBundle.standardizedFileURL)
      #expect(byID["com.example.named"]?.marketingVersion == "7.1")
      #expect(byID["com.example.named"]?.buildVersion == "19")
      #expect(byID["com.example.identifier-only"]?.displayName == "com.example.identifier-only")
      #expect(byID["com.example.identifier-only"]?.bundleURL == nil)
    }
  }

  @Test("拒绝包含目录或上级跳转的图标声明")
  func rejectsUnsafeIconNames() async throws {
    try await withApplicationFixture { fixture in
      for (index, unsafeName) in ["../OutsideIcon", "Assets/AppIcon", #"Assets\AppIcon"#]
        .enumerated()
      {
        let bundle = try fixture.makeBundle(
          named: "Unsafe-\(index)",
          info: [
            "CFBundleIcons": [
              "CFBundlePrimaryIcon": [
                "CFBundleIconName": unsafeName,
                "CFBundleIconFiles": [unsafeName],
              ]
            ]
          ]
        )
        let output = applicationListOutput([
          "com.example.unsafe\(index)": [
            "ApplicationType": "User",
            "Bundle": bundle.absoluteString,
            "CFBundleIdentifier": "com.example.unsafe\(index)",
          ]
        ])
        let catalog = SimulatorApplicationCatalog(
          runner: ApplicationCatalogRunner(output: output)
        )

        let application = try #require(
          try await catalog.applications(
            for: SimulatorID(rawValue: "33333333-4444-4555-8666-777777777777")
          ).first
        )

        #expect(application.icon.declaredName == nil)
        #expect(application.icon.fileURL == nil)
      }
    }
  }

  @Test("图标文件列表缺失时使用安全的图标名称查找文件")
  func resolvesIconFileFromDeclaredNameFallback() async throws {
    try await withApplicationFixture { fixture in
      let bundle = try fixture.makeBundle(
        named: "NamedIcon",
        info: [
          "CFBundleIcons": [
            "CFBundlePrimaryIcon": [
              "CFBundleIconName": "NamedAppIcon"
            ]
          ]
        ],
        files: ["NamedAppIcon@3x.png"]
      )
      let output = applicationListOutput([
        "com.example.named-icon": [
          "ApplicationType": "User",
          "Bundle": bundle.absoluteString,
          "CFBundleIdentifier": "com.example.named-icon",
        ]
      ])
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: output)
      )

      let application = try #require(
        try await catalog.applications(
          for: SimulatorID(rawValue: "3A3A3A3A-4B4B-4C4C-8D8D-5E5E5E5E5E5E")
        ).first
      )

      #expect(
        application.icon.fileURL
          == bundle.appendingPathComponent("NamedAppIcon@3x.png").standardizedFileURL
      )
    }
  }

  @Test("图标文件经符号链接逃出应用包时拒绝返回")
  func rejectsIconSymlinkEscapingBundle() async throws {
    try await withApplicationFixture { fixture in
      let bundle = try fixture.makeBundle(
        named: "Linked",
        info: [
          "CFBundleIcons": [
            "CFBundlePrimaryIcon": [
              "CFBundleIconFiles": ["AppIcon"]
            ]
          ]
        ]
      )
      let outsideIcon = fixture.root.appendingPathComponent("Outside.png")
      try Data("outside".utf8).write(to: outsideIcon)
      try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("AppIcon@2x.png"),
        withDestinationURL: outsideIcon
      )
      let output = applicationListOutput([
        "com.example.linked": [
          "ApplicationType": "User",
          "Bundle": bundle.absoluteString,
          "CFBundleIdentifier": "com.example.linked",
        ]
      ])
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: output)
      )

      let application = try #require(
        try await catalog.applications(
          for: SimulatorID(rawValue: "44444444-5555-4666-8777-888888888888")
        ).first
      )

      #expect(application.icon.declaredName == "AppIcon")
      #expect(application.icon.fileURL == nil)
    }
  }

  @Test("关机设备映射为可识别错误")
  func mapsShutdownCommandFailure() async {
    let deviceID = SimulatorID(rawValue: "55555555-6666-4777-8888-999999999999")
    let runner = ApplicationCatalogRunner(
      error: SimulatorWorkspaceError.commandFailed(
        command: "xcrun simctl listapps \(deviceID.rawValue)",
        code: 149,
        message: "Unable to lookup in current state: Shutdown"
      )
    )
    let catalog = SimulatorApplicationCatalog(runner: runner)

    do {
      _ = try await catalog.applications(for: deviceID)
      Issue.record("预期返回 deviceNotBooted")
    } catch SimulatorWorkspaceError.deviceNotBooted(let actualID) {
      #expect(actualID == deviceID)
    } catch {
      Issue.record("错误类型不正确：\(error)")
    }

    do {
      _ = try await catalog.dataContainer(
        for: deviceID,
        bundleIdentifier: "com.example.demo"
      )
      Issue.record("预期数据容器查询返回 deviceNotBooted")
    } catch SimulatorWorkspaceError.deviceNotBooted(let actualID) {
      #expect(actualID == deviceID)
    } catch {
      Issue.record("数据容器错误类型不正确：\(error)")
    }
  }

  @Test("点击文件夹时重新查询并返回当前设备的数据容器")
  func resolvesCurrentDataContainerOnDemand() async throws {
    try await withApplicationFixture { fixture in
      let deviceID = SimulatorID(rawValue: "66666666-7777-4888-8999-AAAAAAAAAAAA")
      let devicesRoot = fixture.root.appendingPathComponent("Devices", isDirectory: true)
      let container =
        devicesRoot
        .appendingPathComponent(deviceID.rawValue, isDirectory: true)
        .appendingPathComponent(
          "data/Containers/Data/Application/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: container,
        withIntermediateDirectories: true
      )
      let runner = ApplicationCatalogRunner(output: "\(container.path)\n")
      let catalog = SimulatorApplicationCatalog(
        runner: runner,
        devicesRootURL: devicesRoot
      )

      let resolved = try await catalog.dataContainer(
        for: deviceID,
        bundleIdentifier: "com.example.demo"
      )

      #expect(resolved == container.standardizedFileURL)
      let command = try #require(await runner.receivedCommands().first)
      #expect(
        command.arguments == [
          "simctl", "get_app_container", deviceID.rawValue,
          "com.example.demo", "data",
        ]
      )
    }
  }

  @Test("空输出与 null 数据容器均表示应用没有数据目录")
  func mapsAbsentDataContainerToNil() async throws {
    try await withApplicationFixture { fixture in
      let deviceID = SimulatorID(rawValue: "77777777-8888-4999-8AAA-BBBBBBBBBBBB")
      let devicesRoot = fixture.root.appendingPathComponent("Devices", isDirectory: true)

      for output in ["", " \n", "(null)\n"] {
        let catalog = SimulatorApplicationCatalog(
          runner: ApplicationCatalogRunner(output: output),
          devicesRootURL: devicesRoot
        )
        let result = try await catalog.dataContainer(
          for: deviceID,
          bundleIdentifier: "com.example.demo"
        )
        #expect(result == nil)
      }
    }
  }

  @Test("拒绝其他设备或非数据容器根目录的路径")
  func rejectsDataContainerOutsideCurrentDevice() async throws {
    try await withApplicationFixture { fixture in
      let deviceID = SimulatorID(rawValue: "88888888-9999-4AAA-8BBB-CCCCCCCCCCCC")
      let otherDeviceID = "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD"
      let devicesRoot = fixture.root.appendingPathComponent("Devices", isDirectory: true)
      let otherContainer =
        devicesRoot
        .appendingPathComponent(otherDeviceID, isDirectory: true)
        .appendingPathComponent(
          "data/Containers/Data/Application/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: otherContainer,
        withIntermediateDirectories: true
      )
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: otherContainer.path),
        devicesRootURL: devicesRoot
      )

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await catalog.dataContainer(
          for: deviceID,
          bundleIdentifier: "com.example.demo"
        )
      }
    }
  }

  @Test("数据容器符号链接逃出当前设备时拒绝返回")
  func rejectsDataContainerSymlinkEscape() async throws {
    try await withApplicationFixture { fixture in
      let deviceID = SimulatorID(rawValue: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
      let devicesRoot = fixture.root.appendingPathComponent("Devices", isDirectory: true)
      let applicationRoot =
        devicesRoot
        .appendingPathComponent(deviceID.rawValue, isDirectory: true)
        .appendingPathComponent(
          "data/Containers/Data/Application",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: applicationRoot,
        withIntermediateDirectories: true
      )
      let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let linkedContainer = applicationRoot.appendingPathComponent(
        "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF",
        isDirectory: true
      )
      try FileManager.default.createSymbolicLink(
        at: linkedContainer,
        withDestinationURL: outside
      )
      let catalog = SimulatorApplicationCatalog(
        runner: ApplicationCatalogRunner(output: linkedContainer.path),
        devicesRootURL: devicesRoot
      )

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await catalog.dataContainer(
          for: deviceID,
          bundleIdentifier: "com.example.demo"
        )
      }
    }
  }
}

private actor ApplicationCatalogRunner: CommandRunning {
  private let output: String
  private let error: (any Error)?
  private var commands: [Command] = []

  init(output: String = "", error: (any Error)? = nil) {
    self.output = output
    self.error = error
  }

  func run(_ command: Command) async throws -> CommandOutput {
    commands.append(command)
    if let error {
      throw error
    }
    return CommandOutput(standardOutput: output, standardError: "", exitCode: 0)
  }

  func receivedCommands() -> [Command] {
    commands
  }
}

private struct ApplicationFixture {
  let root: URL

  func makeBundle(
    named name: String,
    info: [String: Any],
    files: [String] = []
  ) throws -> URL {
    let bundle = root.appendingPathComponent("\(name).app", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundle,
      withIntermediateDirectories: true
    )
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .binary,
      options: 0
    )
    try infoData.write(to: bundle.appendingPathComponent("Info.plist"))
    for file in files {
      try Data(file.utf8).write(to: bundle.appendingPathComponent(file))
    }
    return bundle
  }
}

private func withApplicationFixture(
  _ body: (ApplicationFixture) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SimulatorSlimmer-Applications-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(ApplicationFixture(root: root))
}

private func applicationListOutput(_ applications: [String: [String: Any]]) -> String {
  let data = try! PropertyListSerialization.data(
    fromPropertyList: applications,
    format: .xml,
    options: 0
  )
  return String(decoding: data, as: UTF8.self)
}
