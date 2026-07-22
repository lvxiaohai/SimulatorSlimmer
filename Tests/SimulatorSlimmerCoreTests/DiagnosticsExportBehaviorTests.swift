import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("诊断包导出")
struct DiagnosticsExportBehaviorTests {
  @Test("导出可解压诊断包并移除清单中的完整本机路径")
  func exportsRedactedArchive() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimulatorSlimmerDiagnosticsTests-\(UUID())", isDirectory: true)
    let archiveURL = root.appendingPathComponent("diagnostics.zip")
    let extractedURL = root.appendingPathComponent("extracted", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let device = SimulatorDevice(
      id: SimulatorID(rawValue: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"),
      name: "测试设备",
      runtimeIdentifier: "runtime-ios-26",
      runtimeName: "iOS 26.5",
      deviceTypeIdentifier: "iphone",
      state: .shutdown,
      isAvailable: true,
      dataPath: URL(fileURLWithPath: "/Users/private/Simulator/data"),
      logPath: URL(fileURLWithPath: "/Users/private/Simulator/logs"),
      dataSize: 1_024,
      logSize: 128
    )
    let inventory = SimulatorInventory(runtimes: [], devices: [device])
    let receipt = OperationReceipt(
      kind: .scanStorage,
      deviceID: device.id,
      deviceName: device.name,
      status: .succeeded,
      originalDeviceState: .shutdown
    )

    let result = try await DiagnosticsExporter().export(
      inventory: inventory,
      receipts: [receipt],
      to: archiveURL
    )
    #expect(result == archiveURL)
    #expect(FileManager.default.fileExists(atPath: archiveURL.path))

    _ = try await FoundationCommandRunner().run(
      Command(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", archiveURL.path, extractedURL.path]
      )
    )
    let packageURL = extractedURL.appendingPathComponent(
      "SimulatorSlimmer-Diagnostics",
      isDirectory: true
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let exportedInventory = try decoder.decode(
      SimulatorInventory.self,
      from: Data(contentsOf: packageURL.appendingPathComponent("inventory.json"))
    )
    #expect(exportedInventory.devices.first?.dataPath == nil)
    #expect(exportedInventory.devices.first?.logPath == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent("Receipts/operations.json").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent("Logs/events.ndjson").path
      )
    )

    let replacedResult = try await DiagnosticsExporter().export(
      inventory: inventory,
      receipts: [receipt],
      to: archiveURL
    )
    #expect(replacedResult == archiveURL)
    #expect(FileManager.default.fileExists(atPath: archiveURL.path))
  }

  @Test("拒绝覆盖符号链接诊断包目标")
  func rejectsSymbolicLinkDestination() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimulatorSlimmerDiagnosticsTests-\(UUID())", isDirectory: true)
    let targetURL = root.appendingPathComponent("target.zip")
    let linkURL = root.appendingPathComponent("diagnostics.zip")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("原有文件".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await DiagnosticsExporter().export(
        inventory: SimulatorInventory(runtimes: [], devices: []),
        receipts: [],
        to: linkURL
      )
    }
    #expect(try String(contentsOf: targetURL, encoding: .utf8) == "原有文件")
  }
}
