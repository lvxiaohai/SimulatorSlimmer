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

  @Test("服务存在性探测忽略 Runtime 中已失效的目录规则")
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
      presentLabels: ["com.apple.present"]
    )
    let adapter = SimctlAdapter(runner: runner)
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    let present = try await adapter.presentServiceLabels(
      ["com.apple.present", "com.apple.removed"],
      for: deviceID
    )

    #expect(present == ["com.apple.present"])
    #expect(
      await runner.probedLabels() == ["com.apple.present", "com.apple.removed"]
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
  private var probes = Set<String>()

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
      arguments[4] == "print"
    {
      let target = arguments[5]
      let label = target.replacingOccurrences(of: "system/", with: "")
      probes.insert(label)
      if presentLabels.contains(label) {
        return CommandOutput(
          standardOutput: "system/\(label) = { state = running }",
          standardError: "",
          exitCode: 0
        )
      }
      throw SimulatorWorkspaceError.commandFailed(
        command: command.displayName,
        code: 113,
        message: "Could not find service \"\(label)\" in domain for system"
      )
    }
    throw FixtureContractError.unexpectedCommand(arguments.joined(separator: " "))
  }

  func probedLabels() -> Set<String> { probes }
}

private enum FixtureContractError: Error {
  case missingResource(String)
  case unexpectedCommand(String)
}
