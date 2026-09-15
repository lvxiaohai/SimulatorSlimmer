import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("CoreSimulator 输出契约")
struct SimctlFixtureContractTests {
  @Test("simctl Runtime 与设备清单可转换为领域模型")
  func inventoryFixturesDecodeThroughProductionAdapter() async throws {
    let runtimeJSON = try fixtureText(
      named: "simctl-list-runtimes",
      extension: "json"
    )
    let deviceJSON = try fixtureText(
      named: "simctl-list-devices",
      extension: "json"
    )
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": runtimeJSON,
      "simctl list devices -j": deviceJSON,
    ])

    let inventory = try await SimctlAdapter(runner: runner).inventory()

    #expect(inventory.runtimes.map(\.version) == ["26.5", "26.3.1"])
    #expect(inventory.runtimes.count == 2)
    #expect(inventory.devices.count == 2)

    let phone = try #require(
      inventory.devices.first { $0.name == "契约测试 iPhone" }
    )
    #expect(phone.id.rawValue == "11111111-2222-4333-8444-555555555555")
    #expect(phone.runtimeName == "iOS 26.5")
    #expect(phone.state == .booted)
    #expect(phone.isAvailable)
    #expect(phone.dataSize == 3_221_225_472)
    #expect(phone.logSize == 16_777_216)
    #expect(phone.lastBootedAt != nil)

    let tablet = try #require(
      inventory.devices.first { $0.name == "契约测试 iPad" }
    )
    #expect(tablet.runtimeName == "iOS 26.3")
    #expect(tablet.state == .shutdown)
    #expect(tablet.isAvailable)
    #expect(tablet.dataSize == 2_147_483_648)
  }

  @Test("显示设备兼容新旧 Xcode 且不重复启动设备", arguments: [true, false])
  func openingBootedSimulatorSkipsBootStatus(useDeviceHub: Bool) async throws {
    let runtimeJSON = try fixtureText(
      named: "simctl-list-runtimes",
      extension: "json"
    )
    let deviceJSON = try fixtureText(
      named: "simctl-list-devices",
      extension: "json"
    )
    let deviceID = "11111111-2222-4333-8444-555555555555"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let developer = root.appendingPathComponent("Xcode Fixture.app/Contents/Developer")
    let app =
      useDeviceHub
      ? developer.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app")
      : developer.appendingPathComponent("Applications/Simulator.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let openArguments =
      useDeviceHub
      ? "-a \(app.path) devices:///manage/select?id=\(deviceID)"
      : "-a \(app.path) --args -CurrentDeviceUDID \(deviceID)"
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": runtimeJSON,
      "simctl list devices -j": deviceJSON,
      "--print-path": developer.path + "\n",
      openArguments: "",
    ])

    try await SimctlAdapter(runner: runner).openSimulator(
      SimulatorID(rawValue: deviceID)
    )
  }

  @Test("显示入口失败返回可本地化错误", arguments: [true, false])
  func simulatorWindowErrorsAreTyped(invalidDirectory: Bool) async throws {
    let developerPath = invalidDirectory ? "" : "/missing-\(UUID().uuidString)/Contents/Developer"
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": try fixtureText(named: "simctl-list-runtimes", extension: "json"),
      "simctl list devices -j": try fixtureText(named: "simctl-list-devices", extension: "json"),
      "--print-path": developerPath,
    ])
    do {
      try await SimctlAdapter(runner: runner).openSimulator(
        SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")
      )
      Issue.record("缺少显示应用时不应成功")
    } catch let error as SimulatorWorkspaceError {
      #expect(error.localizationKey != nil)
      switch error {
      case .invalidDeveloperDirectory: #expect(invalidDirectory)
      case .simulatorApplicationNotFound: #expect(!invalidDirectory)
      default: Issue.record("错误类型不符合预期：\(error)")
      }
    }
  }

  @Test("显示模拟器不会启动已关机设备")
  func openingShutdownSimulatorDoesNotBootIt() async throws {
    let runtimeJSON = try fixtureText(
      named: "simctl-list-runtimes",
      extension: "json"
    )
    let deviceJSON = try fixtureText(
      named: "simctl-list-devices",
      extension: "json"
    )
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": runtimeJSON,
      "simctl list devices -j": deviceJSON,
    ])

    await #expect(throws: SimulatorWorkspaceError.self) {
      try await SimctlAdapter(runner: runner).openSimulator(
        SimulatorID(rawValue: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
      )
    }
  }

  @Test("Runtime 与设备按数字版本从新到旧排序")
  func inventoryUsesNumericRuntimeOrder() async throws {
    let runtime263ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-3"
    let runtime265ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    let runtime2610ID = "com.apple.CoreSimulator.SimRuntime.iOS-26-10"
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": """
      {"runtimes":[
        {"identifier":"\(runtime263ID)","name":"iOS 26.3","version":"26.3.1","isAvailable":true},
        {"identifier":"\(runtime2610ID)","name":"iOS 26.10","version":"26.10","isAvailable":true},
        {"identifier":"\(runtime265ID)","name":"iOS 26.5","version":"26.5","isAvailable":true}
      ]}
      """,
      "simctl list devices -j": """
      {"devices":{
        "\(runtime263ID)":[{"udid":"11111111-2222-4333-8444-555555555555","name":"iOS 26.3 设备","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}],
        "\(runtime2610ID)":[{"udid":"22222222-3333-4444-8555-666666666666","name":"iOS 26.10 设备","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}],
        "\(runtime265ID)":[{"udid":"33333333-4444-4555-8666-777777777777","name":"iOS 26.5 设备","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]
      }}
      """,
    ])

    let inventory = try await SimctlAdapter(runner: runner).inventory()

    #expect(inventory.runtimes.map(\.version) == ["26.10", "26.5", "26.3.1"])
    #expect(
      inventory.devices.map(\.runtimeIdentifier) == [
        runtime2610ID,
        runtime265ID,
        runtime263ID,
      ])
  }

  @Test("print-disabled 只提取明确禁用的 label")
  func printDisabledFixtureDecodesThroughProductionParser() throws {
    let output = try fixtureText(
      named: "launchctl-print-disabled",
      extension: "txt"
    )

    let disabledLabels = SimctlAdapter.parseDisabledLabels(output)

    #expect(
      disabledLabels == [
        "com.apple.newsd",
        "com.apple.weatherd",
        "com.example.unmanaged.fixture",
      ]
    )
    #expect(!disabledLabels.contains("com.apple.sharingd"))
    #expect(!disabledLabels.contains("com.apple.SpringBoard"))
  }

  @Test("服务存在性从前台用户域读取新建设备的服务")
  func servicePresenceProbeUsesExactLaunchdTargets() async throws {
    let runtimeJSON = try fixtureText(
      named: "simctl-list-runtimes",
      extension: "json"
    )
    let deviceJSON = try fixtureText(
      named: "simctl-list-devices",
      extension: "json"
    )
    let runner = ServicePresenceFixtureRunner(
      runtimeJSON: runtimeJSON,
      deviceJSON: deviceJSON,
      presentLabels: ["com.apple.configured", "com.apple.present"]
    )
    let adapter = SimctlAdapter(runner: runner)
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    let present = try await adapter.presentServiceLabels(
      [
        "com.apple.configured",
        "com.apple.endpoint-only",
        "com.apple.present",
        "com.apple.removed",
      ],
      for: deviceID
    )

    #expect(present == ["com.apple.configured", "com.apple.present"])
    #expect(await runner.bulkProbeCount() == 1)
  }

  @Test("服务状态读取与变更统一使用前台用户域")
  func serviceOperationsUseForegroundUserDomain() async throws {
    let runner = LaunchdDomainFixtureRunner()
    let adapter = SimctlAdapter(runner: runner)
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    _ = try await adapter.disabledLabels(for: deviceID)
    try await adapter.setService(
      "com.apple.fixture",
      transition: .disable,
      deviceID: deviceID
    )

    let commands = await runner.recordedCommands()
    #expect(
      commands == [
        [
          "simctl", "spawn", deviceID.rawValue,
          "launchctl", "print-disabled", "user/foreground",
        ],
        [
          "simctl", "spawn", deviceID.rawValue,
          "launchctl", "disable", "user/foreground/com.apple.fixture",
        ],
      ]
    )
  }

  @Test("空 Runtime 与设备数组返回空清单")
  func emptyInventoryDecodes() async throws {
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": #"{"runtimes":[]}"#,
      "simctl list devices -j": #"{"devices":{}}"#,
    ])

    let inventory = try await SimctlAdapter(runner: runner).inventory()

    #expect(inventory.runtimes.isEmpty)
    #expect(inventory.devices.isEmpty)
  }

  @Test("损坏的 simctl JSON 会明确失败")
  func malformedInventoryIsRejected() async {
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": "{not-json",
      "simctl list devices -j": #"{"devices":{}}"#,
    ])

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await SimctlAdapter(runner: runner).inventory()
    }
  }

  @Test("不可用 iOS Runtime 保留只读可见并禁用设备")
  func unavailableRuntimeMarksItsDeviceUnavailable() async throws {
    let runtimeID = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": """
      {"runtimes":[{
        "identifier":"\(runtimeID)","name":"iOS 26.4","version":"26.4",
        "buildversion":"23E000","isAvailable":false,
        "platformIdentifier":"com.apple.platform.iphonesimulator"
      }]}
      """,
      "simctl list devices -j": """
      {"devices":{"\(runtimeID)":[{
        "udid":"22222222-3333-4444-8555-666666666666",
        "name":"不可用测试设备","state":"Shutdown","isAvailable":true,
        "availabilityError":"Runtime profile not found",
        "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"
      }]}}
      """,
    ])

    let inventory = try await SimctlAdapter(runner: runner).inventory()

    #expect(inventory.runtimes.count == 1)
    let device = try #require(inventory.devices.first)
    #expect(!device.isAvailable)
    #expect(device.state == .unavailable)
  }

  @Test("只纳入 iOS Runtime 并排除同版本其他平台")
  func nonIOSRuntimesAreExcluded() async throws {
    let iOSRuntimeID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    let tvRuntimeID = "com.apple.CoreSimulator.SimRuntime.tvOS-26-5"
    let runner = FixtureCommandRunner(outputs: [
      "simctl list runtimes -j": """
      {"runtimes":[
        {"identifier":"\(iOSRuntimeID)","name":"iOS 26.5","version":"26.5","isAvailable":true,"platformIdentifier":"com.apple.platform.iphonesimulator"},
        {"identifier":"\(tvRuntimeID)","name":"tvOS 26.5","version":"26.5","isAvailable":true,"platformIdentifier":"com.apple.platform.appletvsimulator"}
      ]}
      """,
      "simctl list devices -j": """
      {"devices":{
        "\(iOSRuntimeID)":[{"udid":"33333333-4444-4555-8666-777777777777","name":"iPhone","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}],
        "\(tvRuntimeID)":[{"udid":"44444444-5555-4666-8777-888888888888","name":"Apple TV","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K"}]
      }}
      """,
    ])

    let inventory = try await SimctlAdapter(runner: runner).inventory()

    #expect(inventory.runtimes.map(\.id) == [iOSRuntimeID])
    #expect(inventory.devices.map(\.name) == ["iPhone"])
  }

  @Test("fixture 不包含本机用户名或真实设备标识")
  func fixturesAreDeidentified() throws {
    let runtimeJSON = try fixtureText(
      named: "simctl-list-runtimes",
      extension: "json"
    )
    let deviceJSON = try fixtureText(
      named: "simctl-list-devices",
      extension: "json"
    )
    let combined = runtimeJSON + deviceJSON

    #expect(!combined.localizedCaseInsensitiveContains("tianshui"))
    #expect(combined.contains("/Users/fixture/"))
    #expect(combined.contains("11111111-2222-4333-8444-555555555555"))
    #expect(combined.contains("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
  }

  private func fixtureText(named name: String, extension fileExtension: String) throws
    -> String
  {
    let url =
      Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures"
      ) ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    guard let url else {
      throw FixtureContractError.missingResource("\(name).\(fileExtension)")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

private actor FixtureCommandRunner: CommandRunning {
  let outputs: [String: String]

  init(outputs: [String: String]) {
    self.outputs = outputs
  }

  func run(_ command: Command) async throws -> CommandOutput {
    let key = command.arguments.joined(separator: " ")
    guard let output = outputs[key] else {
      throw FixtureContractError.unexpectedCommand(key)
    }
    return CommandOutput(
      standardOutput: output,
      standardError: "",
      exitCode: 0
    )
  }
}

private actor ServicePresenceFixtureRunner: CommandRunning {
  let runtimeJSON: String
  let deviceJSON: String
  let presentLabels: Set<String>
  private var bulkProbes = 0

  init(runtimeJSON: String, deviceJSON: String, presentLabels: Set<String>) {
    self.runtimeJSON = runtimeJSON
    self.deviceJSON = deviceJSON
    self.presentLabels = presentLabels
  }

  func run(_ command: Command) async throws -> CommandOutput {
    let arguments = command.arguments
    if arguments == ["simctl", "list", "runtimes", "-j"] {
      return CommandOutput(standardOutput: runtimeJSON, standardError: "", exitCode: 0)
    }
    if arguments == ["simctl", "list", "devices", "-j"] {
      return CommandOutput(standardOutput: deviceJSON, standardError: "", exitCode: 0)
    }
    if arguments.count == 6,
      arguments[0] == "simctl",
      arguments[1] == "spawn",
      arguments[3] == "launchctl",
      arguments[4] == "print",
      arguments[5] == "user/foreground"
    {
      bulkProbes += 1
      let sortedLabels = presentLabels.sorted()
      let loaded = sortedLabels.first ?? "com.apple.fixture"
      let configured = sortedLabels.dropFirst().map {
        "\"\($0)\" => enabled"
      }.joined(separator: "\n")
      return CommandOutput(
        standardOutput: """
          user/foreground = {
            services = {
              42 - \(loaded)
            }
            endpoints = {
              0x1234 M A com.apple.endpoint-only
            }
            disabled services = {
              \(configured)
            }
          }
          """,
        standardError: "",
        exitCode: 0
      )
    }
    throw FixtureContractError.unexpectedCommand(arguments.joined(separator: " "))
  }

  func bulkProbeCount() -> Int { bulkProbes }
}

private actor LaunchdDomainFixtureRunner: CommandRunning {
  private var commands: [[String]] = []

  func run(_ command: Command) async throws -> CommandOutput {
    commands.append(command.arguments)
    return CommandOutput(standardOutput: "", standardError: "", exitCode: 0)
  }

  func recordedCommands() -> [[String]] { commands }
}

private enum FixtureContractError: Error {
  case missingResource(String)
  case unexpectedCommand(String)
}
