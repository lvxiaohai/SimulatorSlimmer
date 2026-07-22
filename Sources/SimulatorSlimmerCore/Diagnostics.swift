import Foundation
import OSLog

actor DiagnosticLogStore {
  static let shared = DiagnosticLogStore()

  private let logger = Logger(
    subsystem: "com.neolabsapp.simulatorslimmer",
    category: "operations"
  )
  private let directoryURL: URL
  private let currentLogURL: URL
  private let archivedLogURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder

  init(
    directoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.directoryURL =
      directoryURL
      ?? ReceiptStore.defaultApplicationSupportURL(fileManager: fileManager)
      .appendingPathComponent("Logs", isDirectory: true)
    self.currentLogURL = self.directoryURL.appendingPathComponent("events.ndjson")
    self.archivedLogURL = self.directoryURL.appendingPathComponent("events.1.ndjson")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  func record(
    level: DiagnosticLogLevel,
    event: String,
    operationID: ReceiptID? = nil,
    deviceID: SimulatorID? = nil,
    detail: String? = nil
  ) {
    let privateDeviceID = deviceID?.rawValue ?? "-"
    switch level {
    case .info:
      logger.info(
        "\(event, privacy: .public) device=\(privateDeviceID, privacy: .private(mask: .hash))"
      )
    case .warning:
      logger.warning(
        "\(event, privacy: .public) device=\(privateDeviceID, privacy: .private(mask: .hash))"
      )
    case .error:
      logger.error(
        "\(event, privacy: .public) device=\(privateDeviceID, privacy: .private(mask: .hash))"
      )
    }

    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try rotateIfNeeded()
      var data = try encoder.encode(
        DiagnosticLogRecord(
          date: Date(),
          level: level,
          event: event,
          operationID: operationID?.rawValue.uuidString.lowercased(),
          device: deviceID.map { String($0.rawValue.prefix(8)) },
          detail: detail
        )
      )
      data.append(0x0A)
      if !fileManager.fileExists(atPath: currentLogURL.path) {
        fileManager.createFile(
          atPath: currentLogURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      }
      let handle = try FileHandle(forWritingTo: currentLogURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      logger.error("写入本地诊断日志失败：\(error.localizedDescription, privacy: .private)")
    }
  }

  func snapshot() -> Data {
    var result = Data()
    for url in [archivedLogURL, currentLogURL] {
      guard let data = try? Data(contentsOf: url) else { continue }
      result.append(data)
      if result.last != 0x0A { result.append(0x0A) }
    }
    return result
  }

  private func rotateIfNeeded() throws {
    let values = try? currentLogURL.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values?.fileSize, size >= 5 * 1_024 * 1_024 else { return }
    if fileManager.fileExists(atPath: archivedLogURL.path) {
      try fileManager.removeItem(at: archivedLogURL)
    }
    try fileManager.moveItem(at: currentLogURL, to: archivedLogURL)
  }
}

enum DiagnosticLogLevel: String, Codable, Sendable {
  case info
  case warning
  case error
}

private struct DiagnosticLogRecord: Codable, Sendable {
  let date: Date
  let level: DiagnosticLogLevel
  let event: String
  let operationID: String?
  let device: String?
  let detail: String?
}

actor DiagnosticsExporter {
  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let dittoURL = URL(fileURLWithPath: "/usr/bin/ditto")

  init(
    runner: any CommandRunning = FoundationCommandRunner(),
    fileManager: FileManager = .default
  ) {
    self.runner = runner
    self.fileManager = fileManager
  }

  func export(
    inventory: SimulatorInventory,
    receipts: [OperationReceipt],
    to destinationURL: URL
  ) async throws -> URL {
    guard destinationURL.isFileURL,
      destinationURL.pathExtension.caseInsensitiveCompare("zip") == .orderedSame
    else {
      throw SimulatorWorkspaceError.invalidOperation("诊断包目标必须是本地 .zip 文件")
    }

    let parentURL = destinationURL.deletingLastPathComponent().standardizedFileURL
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationURL.path) {
      let values = try destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw SimulatorWorkspaceError.unsafePath(destinationURL.path)
      }
    }

    let exportID = UUID().uuidString.lowercased()
    let stagingRoot = fileManager.temporaryDirectory
      .appendingPathComponent("SimulatorSlimmer-Diagnostics-\(exportID)", isDirectory: true)
    let packageURL =
      stagingRoot
      .appendingPathComponent("SimulatorSlimmer-Diagnostics", isDirectory: true)
    let receiptsURL = packageURL.appendingPathComponent("Receipts", isDirectory: true)
    let logsURL = packageURL.appendingPathComponent("Logs", isDirectory: true)
    let temporaryArchiveURL =
      parentURL
      .appendingPathComponent(".SimulatorSlimmer-Diagnostics-\(exportID)")
      .appendingPathExtension("zip")
    defer {
      try? fileManager.removeItem(at: stagingRoot)
      try? fileManager.removeItem(at: temporaryArchiveURL)
    }

    try fileManager.createDirectory(at: receiptsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifest = DiagnosticManifest(
      schemaVersion: 1,
      generatedAt: Date(),
      appVersion: "1.0.0",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      locale: Locale.current.identifier,
      deviceCount: inventory.devices.count,
      receiptCount: receipts.count
    )
    try encoder.encode(manifest).write(
      to: packageURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )
    try encoder.encode(redactedInventory(inventory)).write(
      to: packageURL.appendingPathComponent("inventory.json"),
      options: .atomic
    )
    try encoder.encode(receipts).write(
      to: receiptsURL.appendingPathComponent("operations.json"),
      options: .atomic
    )
    let logData = await DiagnosticLogStore.shared.snapshot()
    try logData.write(to: logsURL.appendingPathComponent("events.ndjson"), options: .atomic)
    try Data(Self.readme.utf8).write(
      to: packageURL.appendingPathComponent("README.txt"),
      options: .atomic
    )

    _ = try await runner.run(
      Command(
        executable: dittoURL,
        arguments: [
          "-c", "-k", "--sequesterRsrc", "--keepParent",
          packageURL.path, temporaryArchiveURL.path,
        ],
        timeout: .seconds(60),
        outputLimit: 1_024 * 1_024
      )
    )

    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: temporaryArchiveURL,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } else {
      try fileManager.moveItem(at: temporaryArchiveURL, to: destinationURL)
    }
    return destinationURL
  }

  private func redactedInventory(_ inventory: SimulatorInventory) -> SimulatorInventory {
    SimulatorInventory(
      runtimes: inventory.runtimes,
      devices: inventory.devices.map { device in
        SimulatorDevice(
          id: device.id,
          name: device.name,
          runtimeIdentifier: device.runtimeIdentifier,
          runtimeName: device.runtimeName,
          deviceTypeIdentifier: device.deviceTypeIdentifier,
          state: device.state,
          isAvailable: device.isAvailable,
          availabilityError: device.availabilityError,
          dataPath: nil,
          logPath: nil,
          dataSize: device.dataSize,
          logSize: device.logSize,
          lastBootedAt: device.lastBootedAt
        )
      },
      collectedAt: inventory.collectedAt
    )
  }

  private static let readme = """
    Simulator Slimmer 本地诊断包

    此归档由用户手动导出，不会自动上传。inventory.json 已移除完整本机路径；
    Receipts/operations.json 包含操作回执和模拟器 UDID，分享前请自行确认接收方。
    Logs/events.ndjson 仅记录本应用的操作生命周期，不包含命令 stdout/stderr 全文。
    """
}

private struct DiagnosticManifest: Codable, Sendable {
  let schemaVersion: Int
  let generatedAt: Date
  let appVersion: String
  let operatingSystem: String
  let locale: String
  let deviceCount: Int
  let receiptCount: Int
}
