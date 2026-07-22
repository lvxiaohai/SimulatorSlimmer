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

private enum FixtureContractError: Error {
  case missingResource(String)
  case unexpectedCommand(String)
}
