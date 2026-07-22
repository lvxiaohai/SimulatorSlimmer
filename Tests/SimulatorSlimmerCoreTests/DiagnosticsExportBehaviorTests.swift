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
      name: "测试设备/中文版",
      runtimeIdentifier: "runtime-ios-26",
      runtimeName: "iOS 26.5",
      deviceTypeIdentifier: "iphone",
      state: .shutdown,
      isAvailable: true,
      availabilityError: "测试路径 /Users/private/Simulator/runtime 不可用",
      dataPath: URL(fileURLWithPath: "/Users/private/Simulator/data"),
      logPath: URL(fileURLWithPath: "/Users/private/Simulator/logs"),
      dataSize: 1_024,
      logSize: 128
    )
    let pathNamedDevice = SimulatorDevice(
      id: SimulatorID(rawValue: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"),
      name: "路径设备 /etc/SimulatorSlimmer/device-name",
      runtimeIdentifier: "runtime-ios-26",
      runtimeName: "iOS 26.5",
      deviceTypeIdentifier: "iphone",
      state: .shutdown,
      isAvailable: true
    )
    let inventory = SimulatorInventory(runtimes: [], devices: [device, pathNamedDevice])
    let receipt = OperationReceipt(
      kind: .scanStorage,
      deviceID: device.id,
      deviceName: device.name,
      status: .succeeded,
      originalDeviceState: .shutdown,
      input: OperationInput(
        customDisabledLabels: ["com.test.normal", "/Users/private/custom-label"],
        cloneName: "副本 \(root.path)/input-private-item"
      ),
      appliedChanges: [
        AppliedChange(
          change: ServiceChange(
            label: "com.test.fixture",
            serviceName: "测试服务",
            categoryID: "test",
            risk: .low,
            transition: .disable
          ),
          succeeded: false,
          errorMessage: "无法读取 \(root.path)/private-item"
        )
      ],
      pendingDeviceAction: PendingDeviceAction(
        kind: .clone,
        cloneName: "待执行副本 \(root.path)/pending-private-item"
      ),
      messages: ["拒绝访问 \(root.path)/receipt-private-item"]
    )
    let futureReceipt = OperationReceipt(
      schemaVersion: 2,
      kind: .preflight,
      deviceID: device.id,
      deviceName: "未来版本回执 /dev/SimulatorSlimmer/receipt-device-name",
      status: .failed,
      originalDeviceState: .unknown,
      messages: ["此回执只能读取和导出"],
      opaquePayload: OpaqueReceiptPayload(
        reason: .unsupportedSchema,
        sourceFileName: "future.json",
        rawJSON:
          """
          {
            "kind": "futureOperation",
            "nested": {"artifact": "\(root.path)/future-private-item"},
            "items": [{"path": "\(root.path)/future-array-item"}],
            "systemPath": "/etc/SimulatorSlimmer/private.conf",
            "/custom-root/SimulatorSlimmer/private-key": "opaque-key",
            "\(root.path)/future-private-key": "opaque-key"
          }
          """,
        errorMessage: "未来回执位于 \(root.path)/future.json"
      )
    )
    let logStore = DiagnosticLogStore(
      directoryURL: root.appendingPathComponent("logs", isDirectory: true)
    )
    await logStore.record(
      level: .error,
      event: "privacy-redaction-test",
      detail: "诊断错误位于 \(root.path)/log-private-item"
    )

    let exporter = DiagnosticsExporter(logStore: logStore, appVersion: "1.0.0 (1)")
    let result = try await exporter.export(
      inventory: inventory,
      receipts: [receipt, futureReceipt],
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
    #expect(exportedInventory.devices.first { $0.id == device.id }?.name == "测试设备/中文版")
    #expect(
      exportedInventory.devices.first { $0.id == pathNamedDevice.id }?.name
        == "路径设备 <本机路径>"
    )
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
    let operationsText = try String(
      contentsOf: packageURL.appendingPathComponent("Receipts/operations.json"),
      encoding: .utf8
    )
    let exportedReceipts = try decoder.decode(
      [OperationReceipt].self,
      from: Data(contentsOf: packageURL.appendingPathComponent("Receipts/operations.json"))
    )
    let logsText = try String(
      contentsOf: packageURL.appendingPathComponent("Logs/events.ndjson"),
      encoding: .utf8
    )
    let inventoryText = try String(
      contentsOf: packageURL.appendingPathComponent("inventory.json"),
      encoding: .utf8
    )
    #expect(!operationsText.contains(root.path))
    #expect(!operationsText.contains("/etc/SimulatorSlimmer/private.conf"))
    #expect(!operationsText.contains("/custom-root/SimulatorSlimmer/private-key"))
    #expect(!operationsText.contains("/dev/SimulatorSlimmer/receipt-device-name"))
    #expect(!operationsText.contains("/Users/private/custom-label"))
    #expect(!logsText.contains(root.path))
    #expect(!inventoryText.contains("/Users/private/Simulator"))
    #expect(operationsText.contains("<本机路径>"))
    #expect(operationsText.contains("futureOperation"))
    #expect(logsText.contains("<本机路径>"))
    let exportedReceipt = try #require(exportedReceipts.first { $0.id == receipt.id })
    #expect(exportedReceipt.deviceName == "测试设备/中文版")
    #expect(exportedReceipt.input?.cloneName?.contains("<本机路径>") == true)
    #expect(exportedReceipt.input?.customDisabledLabels == ["com.test.normal", "<本机路径>"])
    #expect(exportedReceipt.pendingDeviceAction?.cloneName?.contains("<本机路径>") == true)
    #expect(
      exportedReceipts.first { $0.id == futureReceipt.id }?.deviceName
        == "未来版本回执 <本机路径>"
    )

    let replacedResult = try await exporter.export(
      inventory: inventory,
      receipts: [receipt, futureReceipt],
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
