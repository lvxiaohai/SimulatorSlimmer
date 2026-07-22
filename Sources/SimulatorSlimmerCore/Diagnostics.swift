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
          detail: detail.map(Self.redactPaths)
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
      result.append(Self.redactedLogData(data))
      if result.last != 0x0A { result.append(0x0A) }
    }
    return result
  }

  private static func redactedLogData(_ data: Data) -> Data {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    var result = Data()
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      guard let record = try? decoder.decode(DiagnosticLogRecord.self, from: Data(line)) else {
        // 无法确认结构的旧日志宁可不导出，也不冒险泄露绝对路径。
        continue
      }
      let redacted = DiagnosticLogRecord(
        date: record.date,
        level: record.level,
        event: record.event,
        operationID: record.operationID,
        device: record.device,
        detail: record.detail.map(redactPaths)
      )
      guard var encoded = try? encoder.encode(redacted) else { continue }
      encoded.append(0x0A)
      result.append(encoded)
    }
    return result
  }

  fileprivate static func redactPaths(_ value: String) -> String {
    var redacted = value
    let pattern = #"(?<![\p{L}\p{N}._~/-])/(?!/)[^\s，；;：:]+"#
    if let expression = try? NSRegularExpression(pattern: pattern) {
      let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
      redacted = expression.stringByReplacingMatches(
        in: redacted,
        range: range,
        withTemplate: "<本机路径>"
      )
    }

    let roots = Set([
      FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
      FileManager.default.temporaryDirectory.standardizedFileURL.path,
      NSHomeDirectory(),
    ])
    for root in roots.sorted(by: { $0.count > $1.count }) where root.count > 1 {
      redacted = redacted.replacingOccurrences(of: root, with: "<本机路径>")
    }
    return redacted
  }

  fileprivate static func redactOpaqueJSON(_ rawJSON: String) -> String? {
    guard let data = rawJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      JSONSerialization.isValidJSONObject(object),
      let redactedData = try? JSONSerialization.data(
        withJSONObject: redactJSONValue(object),
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    else { return nil }
    return String(data: redactedData, encoding: .utf8)
  }

  private static func redactJSONValue(_ value: Any) -> Any {
    if let string = value as? String {
      return redactPaths(string)
    }
    if let array = value as? [Any] {
      return array.map(redactJSONValue)
    }
    if let dictionary = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (key, nestedValue) in dictionary {
        let redactedKey = redactPaths(key)
        var uniqueKey = redactedKey
        var suffix = 2
        while result[uniqueKey] != nil {
          uniqueKey = "\(redactedKey)#\(suffix)"
          suffix += 1
        }
        result[uniqueKey] = redactJSONValue(nestedValue)
      }
      return result
    }
    return value
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
  private let logStore: DiagnosticLogStore
  private let appVersion: String
  private let dittoURL = URL(fileURLWithPath: "/usr/bin/ditto")

  init(
    runner: any CommandRunning = FoundationCommandRunner(),
    fileManager: FileManager = .default,
    logStore: DiagnosticLogStore = .shared,
    appVersion: String = DiagnosticsExporter.bundleVersion
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.logStore = logStore
    self.appVersion = appVersion
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
      appVersion: appVersion,
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
    try encoder.encode(redactedReceipts(receipts)).write(
      to: receiptsURL.appendingPathComponent("operations.json"),
      options: .atomic
    )
    let logData = await logStore.snapshot()
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
          name: DiagnosticLogStore.redactPaths(device.name),
          runtimeIdentifier: device.runtimeIdentifier,
          runtimeName: device.runtimeName,
          deviceTypeIdentifier: device.deviceTypeIdentifier,
          state: device.state,
          isAvailable: device.isAvailable,
          availabilityError: device.availabilityError.map(DiagnosticLogStore.redactPaths),
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

  private func redactedReceipts(_ receipts: [OperationReceipt]) -> [OperationReceipt] {
    receipts.map { receipt in
      let redactedInput = receipt.input.map { input in
        var redacted = input
        redacted.customDisabledLabels = input.customDisabledLabels.map {
          Set($0.map(DiagnosticLogStore.redactPaths))
        }
        redacted.cloneName = input.cloneName.map(DiagnosticLogStore.redactPaths)
        return redacted
      }
      let redactedChanges = receipt.appliedChanges.map { applied in
        AppliedChange(
          id: applied.id,
          change: applied.change,
          succeeded: applied.succeeded,
          errorMessage: applied.errorMessage.map(DiagnosticLogStore.redactPaths),
          appliedAt: applied.appliedAt
        )
      }
      let redactedPendingDeviceAction = receipt.pendingDeviceAction.map {
        pendingDeviceAction in
        PendingDeviceAction(
          kind: pendingDeviceAction.kind,
          cloneName: pendingDeviceAction.cloneName.map(DiagnosticLogStore.redactPaths),
          startedAt: pendingDeviceAction.startedAt
        )
      }
      let redactedOpaquePayload = receipt.opaquePayload.map { opaque in
        OpaqueReceiptPayload(
          reason: opaque.reason,
          sourceFileName: opaque.sourceFileName,
          rawJSON: opaque.rawJSON.flatMap(DiagnosticLogStore.redactOpaqueJSON),
          errorMessage: DiagnosticLogStore.redactPaths(opaque.errorMessage)
        )
      }
      return OperationReceipt(
        id: receipt.id,
        schemaVersion: receipt.schemaVersion,
        kind: receipt.kind,
        deviceID: receipt.deviceID,
        deviceName: DiagnosticLogStore.redactPaths(receipt.deviceName),
        status: receipt.status,
        startedAt: receipt.startedAt,
        finishedAt: receipt.finishedAt,
        originalDeviceState: receipt.originalDeviceState,
        finalDeviceState: receipt.finalDeviceState,
        shouldRestoreOriginalDeviceState: receipt.shouldRestoreOriginalDeviceState,
        input: redactedInput,
        runtimeIdentifier: receipt.runtimeIdentifier,
        runtimeVersion: receipt.runtimeVersion,
        serviceCatalogVersion: receipt.serviceCatalogVersion,
        baselineCapturedAt: receipt.baselineCapturedAt,
        baselineDisabledLabels: receipt.baselineDisabledLabels,
        pendingChange: receipt.pendingChange,
        appliedChanges: redactedChanges,
        memoryBefore: receipt.memoryBefore,
        memoryAfter: receipt.memoryAfter,
        reclaimedBytes: receipt.reclaimedBytes,
        pendingStorageCleanupPath: receipt.pendingStorageCleanupPath,
        completedStorageCleanupItems: receipt.completedStorageCleanupItems,
        pendingDeviceAction: redactedPendingDeviceAction,
        clonedDeviceID: receipt.clonedDeviceID,
        messages: receipt.messages.map(DiagnosticLogStore.redactPaths),
        opaquePayload: redactedOpaquePayload
      )
    }
  }

  private static let readme = """
    Simulator Slimmer 本地诊断包

    此归档由用户手动导出，不会自动上传。inventory.json 已移除完整本机路径；
    Receipts/operations.json 包含操作回执和模拟器 UDID，分享前请自行确认接收方。
    Logs/events.ndjson 仅记录本应用的操作生命周期，不包含命令 stdout/stderr 全文。
    """

  private static var bundleVersion: String {
    let shortVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "开发构建"
    guard
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      !build.isEmpty
    else { return shortVersion }
    return "\(shortVersion) (\(build))"
  }
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
