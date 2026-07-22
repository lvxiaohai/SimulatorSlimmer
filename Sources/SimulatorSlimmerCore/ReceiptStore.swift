import Foundation

protocol ReceiptStoring: Sendable {
  func save(_ receipt: OperationReceipt) async throws
  func receipt(id: ReceiptID) async throws -> OperationReceipt
  func allReceipts() async throws -> [OperationReceipt]
  func recoverInterruptedReceipts() async throws -> [OperationReceipt]
}

actor ReceiptStore: ReceiptStoring {
  private static let supportedSchemaVersion = 1

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
    try ensureDirectory()
    let data = try encoder.encode(receipt)
    try data.write(to: url(for: receipt.id), options: [.atomic, .completeFileProtection])
  }

  func receipt(id: ReceiptID) async throws -> OperationReceipt {
    let url = url(for: id)
    guard fileManager.fileExists(atPath: url.path) else {
      throw SimulatorWorkspaceError.receiptNotFound(id)
    }
    return try decodeReceipt(at: url, id: id, requireSupportedSchema: true)
  }

  private func decodeReceipt(
    at url: URL,
    id: ReceiptID,
    requireSupportedSchema: Bool
  ) throws -> OperationReceipt {
    do {
      let receipt = try decoder.decode(OperationReceipt.self, from: Data(contentsOf: url))
      guard !requireSupportedSchema || receipt.schemaVersion == Self.supportedSchemaVersion else {
        throw SimulatorWorkspaceError.malformedOutput(
          "回执 \(id.rawValue.uuidString) 使用不支持的版本 \(receipt.schemaVersion)"
        )
      }
      return receipt
    } catch let error as SimulatorWorkspaceError {
      throw error
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(
        "回执 \(id.rawValue.uuidString) 已损坏：\(error.localizedDescription)"
      )
    }
  }

  func allReceipts() async throws -> [OperationReceipt] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    let urls = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var receipts: [OperationReceipt] = []
    for url in urls where url.pathExtension == "json" {
      guard let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
        continue
      }
      let id = ReceiptID(rawValue: uuid)
      if let receipt = try? decodeReceipt(at: url, id: id, requireSupportedSchema: false) {
        receipts.append(receipt)
      }
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
      receipt.messages.append("应用上次运行期间意外中断；已保留现状，可按回执恢复")
      try await save(receipt)
      recovered.append(receipt)
    }
    return recovered
  }

  private func ensureDirectory() throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func url(for id: ReceiptID) -> URL {
    directoryURL.appendingPathComponent(id.rawValue.uuidString.lowercased())
      .appendingPathExtension("json")
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
