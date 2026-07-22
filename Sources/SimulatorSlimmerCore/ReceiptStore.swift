import Darwin
import Foundation

protocol ReceiptStoring: Sendable {
  func save(_ receipt: OperationReceipt) async throws
  func receipt(id: ReceiptID) async throws -> OperationReceipt
  func allReceipts() async throws -> [OperationReceipt]
  func recoverInterruptedReceipts() async throws -> [OperationReceipt]
}

actor ReceiptStore: ReceiptStoring {
  private static let supportedSchemaVersion = 1
  private static let maximumReceiptBytes = 16 * 1_024 * 1_024
  static let interruptionMarker = "应用上次运行期间意外中断"
  static let interruptionResolutionMarker = "中断回执已处理"

  private let directoryURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    directoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.directoryURL =
      directoryURL
      ?? Self.defaultApplicationSupportURL(fileManager: fileManager)
      .appendingPathComponent("Receipts", isDirectory: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func save(_ receipt: OperationReceipt) async throws {
    guard receipt.schemaVersion == Self.supportedSchemaVersion,
      receipt.opaquePayload == nil
    else {
      throw SimulatorWorkspaceError.invalidOperation("未知版本或损坏的回执只能读取和导出")
    }
    let data = try encoder.encode(receipt)
    let directoryDescriptor = try openOrCreateReceiptDirectory()
    defer { _ = Darwin.close(directoryDescriptor) }
    try writeReceiptData(
      data,
      named: url(for: receipt.id).lastPathComponent,
      directoryDescriptor: directoryDescriptor
    )
  }

  func receipt(id: ReceiptID) async throws -> OperationReceipt {
    guard let directoryDescriptor = try openReceiptDirectoryIfPresent() else {
      throw SimulatorWorkspaceError.receiptNotFound(id)
    }
    defer { _ = Darwin.close(directoryDescriptor) }

    let url = url(for: id)
    guard
      try Self.directoryEntryExists(
        named: url.lastPathComponent,
        directoryDescriptor: directoryDescriptor
      )
    else {
      throw SimulatorWorkspaceError.receiptNotFound(id)
    }
    return try decodeReceipt(
      at: url,
      id: id,
      directoryDescriptor: directoryDescriptor,
      requireSupportedSchema: true
    )
  }

  private func decodeReceipt(
    at url: URL,
    id: ReceiptID,
    directoryDescriptor: Int32,
    requireSupportedSchema: Bool
  ) throws -> OperationReceipt {
    let modificationDate =
      Self.modificationDate(
        named: url.lastPathComponent,
        directoryDescriptor: directoryDescriptor
      ) ?? Date.distantPast
    let data: Data
    do {
      data = try readReceiptData(
        named: url.lastPathComponent,
        directoryDescriptor: directoryDescriptor
      )
    } catch {
      if !requireSupportedSchema {
        return Self.corruptedPlaceholder(
          id: id,
          sourceURL: url,
          schemaVersion: nil,
          envelope: nil,
          rawJSON: nil,
          modificationDate: modificationDate,
          error: error
        )
      }
      throw Self.corruptedError(id: id, error: error)
    }

    let rawJSON = String(data: data, encoding: .utf8)
    let envelope: ReceiptEnvelope
    do {
      envelope = try ReceiptEnvelope(data: data)
    } catch {
      if !requireSupportedSchema {
        return Self.corruptedPlaceholder(
          id: id,
          sourceURL: url,
          schemaVersion: nil,
          envelope: nil,
          rawJSON: rawJSON,
          modificationDate: modificationDate,
          error: error
        )
      }
      throw Self.corruptedError(id: id, error: error)
    }

    guard let schemaVersion = envelope.schemaVersion else {
      let error = SimulatorWorkspaceError.malformedOutput("回执缺少结构版本")
      if !requireSupportedSchema {
        return Self.corruptedPlaceholder(
          id: id,
          sourceURL: url,
          schemaVersion: nil,
          envelope: envelope,
          rawJSON: rawJSON,
          modificationDate: modificationDate,
          error: error
        )
      }
      throw Self.corruptedError(id: id, error: error)
    }

    guard schemaVersion == Self.supportedSchemaVersion else {
      if requireSupportedSchema {
        throw SimulatorWorkspaceError.malformedOutput(
          "回执 \(id.rawValue.uuidString) 使用不支持的版本 \(schemaVersion)"
        )
      }
      return Self.unsupportedPlaceholder(
        id: id,
        sourceURL: url,
        schemaVersion: schemaVersion,
        envelope: envelope,
        rawJSON: rawJSON,
        modificationDate: modificationDate
      )
    }

    do {
      return try decoder.decode(OperationReceipt.self, from: data)
    } catch {
      if !requireSupportedSchema {
        return Self.corruptedPlaceholder(
          id: id,
          sourceURL: url,
          schemaVersion: schemaVersion,
          envelope: envelope,
          rawJSON: rawJSON,
          modificationDate: modificationDate,
          error: error
        )
      }
      throw Self.corruptedError(id: id, error: error)
    }
  }

  func allReceipts() async throws -> [OperationReceipt] {
    guard let directoryDescriptor = try openReceiptDirectoryIfPresent() else { return [] }
    defer { _ = Darwin.close(directoryDescriptor) }

    var receipts: [OperationReceipt] = []
    for fileName in try receiptFileNames(directoryDescriptor: directoryDescriptor) {
      let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
      let id = Self.receiptID(for: url)
      receipts.append(
        try decodeReceipt(
          at: url,
          id: id,
          directoryDescriptor: directoryDescriptor,
          requireSupportedSchema: false
        )
      )
    }
    return receipts.sorted { $0.startedAt > $1.startedAt }
  }

  func recoverInterruptedReceipts() async throws -> [OperationReceipt] {
    var recovered: [OperationReceipt] = []
    for var receipt in try await allReceipts()
    where receipt.schemaVersion == Self.supportedSchemaVersion
      && (receipt.status == .prepared || receipt.status == .running)
    {
      receipt.status = .partial
      receipt.finishedAt = Date()
      receipt.messages.append("\(Self.interruptionMarker)；已保留现状，可继续验证或按回执恢复")
      try await save(receipt)
      recovered.append(receipt)
    }
    return recovered
  }

  private func openOrCreateReceiptDirectory() throws -> Int32 {
    if let directoryDescriptor = try openReceiptDirectoryIfPresent() {
      return directoryDescriptor
    }

    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      if let directoryDescriptor = try openReceiptDirectoryIfPresent() {
        return directoryDescriptor
      }
      throw SimulatorWorkspaceError.malformedOutput(
        "无法创建回执目录：\(error.localizedDescription)"
      )
    }
    guard let directoryDescriptor = try openReceiptDirectoryIfPresent() else {
      throw SimulatorWorkspaceError.malformedOutput("回执目录创建后不可用")
    }
    return directoryDescriptor
  }

  private func url(for id: ReceiptID) -> URL {
    directoryURL.appendingPathComponent(id.rawValue.uuidString.lowercased())
      .appendingPathExtension("json")
  }

  private func writeReceiptData(
    _ data: Data,
    named fileName: String,
    directoryDescriptor: Int32
  ) throws {
    let temporaryName = ".\(UUID().uuidString.lowercased()).receipt.tmp"
    let descriptor = Darwin.openat(
      directoryDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw Self.posixError(context: "无法创建回执临时文件", code: errno)
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var shouldRemoveTemporaryFile = true
    defer {
      try? handle.close()
      if shouldRemoveTemporaryFile {
        _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
      }
    }

    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(
        "无法原子写入回执：\(error.localizedDescription)"
      )
    }

    guard Darwin.renameat(directoryDescriptor, temporaryName, directoryDescriptor, fileName) == 0
    else {
      throw Self.posixError(context: "无法提交回执文件", code: errno)
    }
    shouldRemoveTemporaryFile = false

    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw Self.posixError(context: "无法同步回执目录", code: errno)
    }
  }

  private func receiptFileNames(directoryDescriptor: Int32) throws -> [String] {
    let enumerationDescriptor = Darwin.openat(
      directoryDescriptor,
      ".",
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK
    )
    guard enumerationDescriptor >= 0 else {
      throw Self.posixError(context: "无法打开回执目录流", code: errno)
    }
    guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
      let errorCode = errno
      _ = Darwin.close(enumerationDescriptor)
      throw Self.posixError(context: "无法读取回执目录流", code: errorCode)
    }
    defer { _ = Darwin.closedir(directory) }

    var fileNames: [String] = []
    while true {
      errno = 0
      guard let entry = Darwin.readdir(directory) else {
        let errorCode = errno
        guard errorCode == 0 else {
          throw Self.posixError(context: "无法枚举回执目录", code: errorCode)
        }
        break
      }
      let fileName = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
        String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      guard !fileName.hasPrefix("."), (fileName as NSString).pathExtension == "json" else {
        continue
      }
      fileNames.append(fileName)
    }
    return fileNames
  }

  private func readReceiptData(
    named fileName: String,
    directoryDescriptor: Int32
  ) throws -> Data {
    let descriptor = Darwin.openat(
      directoryDescriptor,
      fileName,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      let errorCode = errno
      if errorCode == ELOOP {
        throw SimulatorWorkspaceError.malformedOutput("回执不是普通文件或使用了符号链接")
      }
      throw Self.posixError(context: "无法安全打开回执", code: errorCode)
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw Self.posixError(context: "无法检查回执文件", code: errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw SimulatorWorkspaceError.malformedOutput("回执不是普通文件或使用了符号链接")
    }
    if metadata.st_size > off_t(Self.maximumReceiptBytes) {
      throw SimulatorWorkspaceError.malformedOutput(
        "回执超过 \(Self.maximumReceiptBytes) 字节读取上限"
      )
    }

    let data = try handle.read(upToCount: Self.maximumReceiptBytes + 1) ?? Data()
    guard data.count <= Self.maximumReceiptBytes else {
      throw SimulatorWorkspaceError.malformedOutput(
        "回执超过 \(Self.maximumReceiptBytes) 字节读取上限"
      )
    }
    return data
  }

  private func openReceiptDirectoryIfPresent() throws -> Int32? {
    let descriptor = Darwin.open(
      directoryURL.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      let errorCode = errno
      if errorCode == ENOENT { return nil }
      if errorCode == ELOOP || errorCode == ENOTDIR {
        throw SimulatorWorkspaceError.malformedOutput(
          "回执目录不是普通目录或使用了符号链接"
        )
      }
      throw Self.posixError(context: "无法安全打开回执目录", code: errorCode)
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      let errorCode = errno
      _ = Darwin.close(descriptor)
      throw Self.posixError(context: "无法检查回执目录", code: errorCode)
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
      _ = Darwin.close(descriptor)
      throw SimulatorWorkspaceError.malformedOutput(
        "回执目录不是普通目录或使用了符号链接"
      )
    }
    return descriptor
  }

  private static func directoryEntryExists(
    named fileName: String,
    directoryDescriptor: Int32
  ) throws -> Bool {
    var metadata = stat()
    guard
      Darwin.fstatat(
        directoryDescriptor,
        fileName,
        &metadata,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    else {
      let errorCode = errno
      if errorCode == ENOENT { return false }
      throw posixError(context: "无法检查回执文件", code: errorCode)
    }
    return true
  }

  private static func unsupportedPlaceholder(
    id: ReceiptID,
    sourceURL: URL,
    schemaVersion: Int,
    envelope: ReceiptEnvelope,
    rawJSON: String?,
    modificationDate: Date
  ) -> OperationReceipt {
    let message = "此回执使用不支持的结构版本 \(schemaVersion)，只能读取和导出，不能恢复或继续验证。"
    return placeholder(
      id: id,
      sourceURL: sourceURL,
      schemaVersion: schemaVersion,
      envelope: envelope,
      status: envelope.status.flatMap(OperationStatus.init(rawValue:)) ?? .failed,
      modificationDate: modificationDate,
      messages: placeholderMessages(primary: message, envelope: envelope),
      opaquePayload: OpaqueReceiptPayload(
        reason: .unsupportedSchema,
        sourceFileName: sourceURL.lastPathComponent,
        rawJSON: rawJSON,
        errorMessage: message
      )
    )
  }

  private static func corruptedPlaceholder(
    id: ReceiptID,
    sourceURL: URL,
    schemaVersion: Int?,
    envelope: ReceiptEnvelope?,
    rawJSON: String?,
    modificationDate: Date,
    error: Error
  ) -> OperationReceipt {
    let detail = "回执文件已损坏：\(error.localizedDescription)"
    return placeholder(
      id: id,
      sourceURL: sourceURL,
      schemaVersion: schemaVersion ?? 0,
      envelope: envelope,
      status: .failed,
      modificationDate: modificationDate,
      messages: placeholderMessages(primary: detail, envelope: envelope),
      opaquePayload: OpaqueReceiptPayload(
        reason: .corrupted,
        sourceFileName: sourceURL.lastPathComponent,
        rawJSON: rawJSON,
        errorMessage: detail
      )
    )
  }

  private static func placeholder(
    id: ReceiptID,
    sourceURL: URL,
    schemaVersion: Int,
    envelope: ReceiptEnvelope?,
    status: OperationStatus,
    modificationDate: Date,
    messages: [String],
    opaquePayload: OpaqueReceiptPayload
  ) -> OperationReceipt {
    let fallbackName = "只读回执 \(id.rawValue.uuidString.lowercased().prefix(8))"
    let deviceName = safeDisplayText(envelope?.deviceName) ?? fallbackName
    let deviceID =
      envelope?.deviceID.flatMap { rawValue in
        SimctlAdapter.isValidUDID(rawValue) ? SimulatorID(rawValue: rawValue) : nil
      } ?? SimulatorID(rawValue: "opaque-\(id.rawValue.uuidString.lowercased())")

    return OperationReceipt(
      id: id,
      schemaVersion: schemaVersion,
      kind: envelope?.kind.flatMap(OperationKind.init(rawValue:)) ?? .preflight,
      deviceID: deviceID,
      deviceName: deviceName,
      status: status,
      startedAt: envelope?.startedAt ?? modificationDate,
      finishedAt: envelope?.finishedAt,
      originalDeviceState: envelope?.originalDeviceState
        .flatMap(SimulatorState.init(rawValue:)) ?? .unknown,
      finalDeviceState: envelope?.finalDeviceState.flatMap(SimulatorState.init(rawValue:)),
      messages: messages,
      opaquePayload: opaquePayload
    )
  }

  private static func placeholderMessages(
    primary: String,
    envelope: ReceiptEnvelope?
  ) -> [String] {
    var messages = [primary]
    if let kind = envelope?.kind, OperationKind(rawValue: kind) == nil {
      messages.append("原回执操作类型：\(safeDisplayText(kind) ?? "无法安全显示")")
    }
    if let status = envelope?.status, OperationStatus(rawValue: status) == nil {
      messages.append("原回执状态：\(safeDisplayText(status) ?? "无法安全显示")")
    }
    return messages
  }

  private static func safeDisplayText(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 128,
      !value.contains("/"), !value.contains("\\"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return value
  }

  private static func corruptedError(id: ReceiptID, error: Error) -> SimulatorWorkspaceError {
    .malformedOutput(
      "回执 \(id.rawValue.uuidString) 已损坏：\(error.localizedDescription)"
    )
  }

  private static func modificationDate(
    named fileName: String,
    directoryDescriptor: Int32
  ) -> Date? {
    var metadata = stat()
    guard
      Darwin.fstatat(
        directoryDescriptor,
        fileName,
        &metadata,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    else { return nil }
    let seconds = TimeInterval(metadata.st_mtimespec.tv_sec)
    let nanoseconds = TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
    return Date(timeIntervalSince1970: seconds + nanoseconds)
  }

  private static func posixError(
    context: String,
    code: Int32
  ) -> SimulatorWorkspaceError {
    let detail = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    return .malformedOutput("\(context)：\(detail)")
  }

  private static func receiptID(for url: URL) -> ReceiptID {
    let fileStem = url.deletingPathExtension().lastPathComponent
    if let uuid = UUID(uuidString: fileStem) {
      return ReceiptID(rawValue: uuid)
    }

    var first: UInt64 = 0xcbf2_9ce4_8422_2325
    var second: UInt64 = 0x8422_2325_cbf2_9ce4
    for byte in fileStem.utf8 {
      first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
      second = (second ^ UInt64(byte &+ 0x5d)) &* 0x0000_0100_0000_01b3
    }
    let hexadecimal = String(format: "%016llx%016llx", first, second)
    let uuidText =
      "\(hexadecimal.prefix(8))-\(hexadecimal.dropFirst(8).prefix(4))-\(hexadecimal.dropFirst(12).prefix(4))-\(hexadecimal.dropFirst(16).prefix(4))-\(hexadecimal.dropFirst(20).prefix(12))"
    return ReceiptID(rawValue: UUID(uuidString: uuidText)!)
  }

  static func defaultApplicationSupportURL(fileManager: FileManager = .default) -> URL {
    let base =
      (try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ))
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Simulator Slimmer", isDirectory: true)
  }
}

private struct ReceiptEnvelope: Sendable {
  let schemaVersion: Int?
  let kind: String?
  let deviceID: String?
  let deviceName: String?
  let status: String?
  let startedAt: Date?
  let finishedAt: Date?
  let originalDeviceState: String?
  let finalDeviceState: String?

  init(data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
      throw SimulatorWorkspaceError.malformedOutput("回执顶层不是 JSON 对象")
    }

    self.schemaVersion = Self.integer(dictionary["schemaVersion"])
    self.kind = Self.string(dictionary["kind"])
    self.deviceID = Self.rawRepresentableString(dictionary["deviceID"])
    self.deviceName = Self.string(dictionary["deviceName"])
    self.status = Self.string(dictionary["status"])
    self.startedAt = Self.date(dictionary["startedAt"])
    self.finishedAt = Self.date(dictionary["finishedAt"])
    self.originalDeviceState = Self.string(dictionary["originalDeviceState"])
    self.finalDeviceState = Self.string(dictionary["finalDeviceState"])
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      String(cString: number.objCType) != "c"
    else { return nil }
    return number.intValue
  }

  private static func string(_ value: Any?) -> String? {
    value as? String
  }

  private static func rawRepresentableString(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    return (value as? [String: Any])?["rawValue"] as? String
  }

  private static func date(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
