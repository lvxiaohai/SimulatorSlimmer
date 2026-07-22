import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("操作回执行为")
struct ReceiptStoreBehaviorTests {
  @Test("同一回执可原子覆盖并完整读回")
  func atomicOverwriteRoundTrip() async throws {
    try await withTemporaryDirectory { directory in
      let store = ReceiptStore(directoryURL: directory)
      var receipt = makeReceipt(
        status: .prepared,
        startedAt: Date(timeIntervalSince1970: 100)
      )

      try await store.save(receipt)
      receipt.status = .succeeded
      receipt.finishedAt = Date(timeIntervalSince1970: 200)
      receipt.messages.append("完成")
      try await store.save(receipt)

      let loaded = try await store.receipt(id: receipt.id)
      #expect(loaded.status == .succeeded)
      #expect(loaded.finishedAt == Date(timeIntervalSince1970: 200))
      #expect(loaded.messages == ["完成"])

      let entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
      #expect(entries.filter { $0.pathExtension == "json" }.count == 1)
      #expect(entries.count == 1)

      let onDiskData = try Data(contentsOf: entries[0])
      #expect(!onDiskData.isEmpty)
      #expect(try JSONSerialization.jsonObject(with: onDiskData) is [String: Any])
    }
  }

  @Test("启动时把准备中和运行中回执标记为部分完成")
  func interruptedReceiptsBecomePartial() async throws {
    try await withTemporaryDirectory { directory in
      let store = ReceiptStore(directoryURL: directory)
      let prepared = makeReceipt(
        status: .prepared,
        startedAt: Date(timeIntervalSince1970: 100)
      )
      let running = makeReceipt(
        status: .running,
        startedAt: Date(timeIntervalSince1970: 200)
      )
      let succeeded = makeReceipt(
        status: .succeeded,
        startedAt: Date(timeIntervalSince1970: 300)
      )
      try await store.save(prepared)
      try await store.save(running)
      try await store.save(succeeded)

      let recovered = try await store.recoverInterruptedReceipts()

      #expect(Set(recovered.map(\.id)) == [prepared.id, running.id])
      #expect(recovered.allSatisfy { $0.status == .partial })
      #expect(recovered.allSatisfy { $0.finishedAt != nil })
      #expect(
        recovered.allSatisfy {
          $0.messages.contains { $0.contains("意外中断") }
        }
      )
      #expect(try await store.receipt(id: succeeded.id).status == .succeeded)
    }
  }

  @Test("未知版本回执只读可见但不可恢复或改写")
  func futureSchemaReceiptRemainsReadOnly() async throws {
    try await withTemporaryDirectory { directory in
      let store = ReceiptStore(directoryURL: directory)
      let receiptID = ReceiptID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
      )
      let futureData = Data(
        """
        {
          "schemaVersion": 2,
          "kind": "futureOptimize",
          "deviceID": {"rawValue": "11111111-2222-4333-8444-555555555555"},
          "deviceName": "未来设备",
          "status": "running",
          "startedAt": "2026-07-22T12:00:00Z",
          "originalDeviceState": "booted",
          "futureTimeline": [{"phase": "quantumVerification", "result": "unknown"}]
        }
        """.utf8
      )
      let futureURL =
        directory
        .appendingPathComponent(receiptID.rawValue.uuidString.lowercased())
        .appendingPathExtension("json")
      try futureData.write(to: futureURL)

      let visibleReceipts = try await store.allReceipts()
      #expect(visibleReceipts.count == 1)
      let visible = try #require(visibleReceipts.first)
      #expect(visible.id == receiptID)
      #expect(visible.schemaVersion == 2)
      #expect(visible.status == .running)
      #expect(visible.deviceName == "未来设备")
      #expect(visible.opaquePayload?.reason == .unsupportedSchema)
      #expect(visible.opaquePayload?.rawJSON?.contains("futureTimeline") == true)

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await store.receipt(id: receiptID)
      }
      await #expect(throws: SimulatorWorkspaceError.self) {
        try await store.save(visible)
      }

      let recovered = try await store.recoverInterruptedReceipts()
      #expect(recovered.isEmpty)
      #expect(try await store.allReceipts().first?.status == .running)
      #expect(try await store.allReceipts().first?.schemaVersion == 2)
      #expect(try Data(contentsOf: futureURL) == futureData)
    }
  }

  @Test("损坏回执会作为显式错误保留而不是静默消失")
  func corruptedReceiptRemainsVisible() async throws {
    try await withTemporaryDirectory { directory in
      let store = ReceiptStore(directoryURL: directory)
      let receiptID = ReceiptID(
        rawValue: UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!
      )
      let corruptedURL =
        directory
        .appendingPathComponent(receiptID.rawValue.uuidString.lowercased())
        .appendingPathExtension("json")
      try Data("{这不是有效 JSON".utf8).write(to: corruptedURL)

      let visibleReceipts = try await store.allReceipts()
      let visible = try #require(visibleReceipts.first)
      #expect(visibleReceipts.count == 1)
      #expect(visible.id == receiptID)
      #expect(visible.schemaVersion == 0)
      #expect(visible.status == .failed)
      #expect(visible.opaquePayload?.reason == .corrupted)
      #expect(visible.messages.contains { $0.contains("已损坏") })

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await store.receipt(id: receiptID)
      }
      #expect(try await store.recoverInterruptedReceipts().isEmpty)
    }
  }

  @Test("符号链接、过大文件和非普通回执会作为只读错误保留")
  func unsafeReceiptFilesRemainVisibleWithoutBeingRead() async throws {
    try await withTemporaryDirectory { directory in
      let store = ReceiptStore(directoryURL: directory)
      let ids = [
        ReceiptID(rawValue: UUID(uuidString: "CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA")!),
        ReceiptID(rawValue: UUID(uuidString: "DDDDDDDD-EEEE-4FFF-8AAA-BBBBBBBBBBBB")!),
        ReceiptID(rawValue: UUID(uuidString: "EEEEEEEE-FFFF-4AAA-8BBB-CCCCCCCCCCCC")!),
      ]
      let receiptURL: (ReceiptID) -> URL = { id in
        directory
          .appendingPathComponent(id.rawValue.uuidString.lowercased())
          .appendingPathExtension("json")
      }

      let hiddenTarget = directory.appendingPathComponent(".symlink-target")
      try Data("不应读取".utf8).write(to: hiddenTarget)
      try FileManager.default.createSymbolicLink(
        at: receiptURL(ids[0]),
        withDestinationURL: hiddenTarget
      )

      _ = FileManager.default.createFile(atPath: receiptURL(ids[1]).path, contents: Data())
      let oversizedHandle = try FileHandle(forWritingTo: receiptURL(ids[1]))
      try oversizedHandle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
      try oversizedHandle.close()

      try FileManager.default.createDirectory(
        at: receiptURL(ids[2]),
        withIntermediateDirectories: false
      )

      let visibleReceipts = try await store.allReceipts()
      #expect(visibleReceipts.count == ids.count)
      #expect(Set(visibleReceipts.map(\.id)) == Set(ids))
      #expect(visibleReceipts.allSatisfy { $0.opaquePayload?.reason == .corrupted })
      #expect(visibleReceipts.allSatisfy { $0.opaquePayload?.rawJSON == nil })

      for id in ids {
        await #expect(throws: SimulatorWorkspaceError.self) {
          _ = try await store.receipt(id: id)
        }
      }
    }
  }

  @Test("回执根目录为符号链接时拒绝读取和写入")
  func symbolicLinkReceiptDirectoryIsRejected() async throws {
    try await withTemporaryDirectory { directory in
      let targetDirectory = directory.appendingPathComponent("target", isDirectory: true)
      let receiptDirectory = directory.appendingPathComponent("Receipts", isDirectory: true)
      try FileManager.default.createDirectory(
        at: targetDirectory,
        withIntermediateDirectories: false
      )

      let existingReceiptID = ReceiptID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
      )
      let existingReceiptURL =
        targetDirectory
        .appendingPathComponent(existingReceiptID.rawValue.uuidString.lowercased())
        .appendingPathExtension("json")
      try Data("{\"schemaVersion\":2}".utf8).write(to: existingReceiptURL)
      try FileManager.default.createSymbolicLink(
        at: receiptDirectory,
        withDestinationURL: targetDirectory
      )

      let store = ReceiptStore(directoryURL: receiptDirectory)
      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await store.allReceipts()
      }
      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await store.receipt(id: existingReceiptID)
      }

      let newReceipt = makeReceipt(status: .prepared, startedAt: Date())
      await #expect(throws: SimulatorWorkspaceError.self) {
        try await store.save(newReceipt)
      }
      let unexpectedWriteURL =
        targetDirectory
        .appendingPathComponent(newReceipt.id.rawValue.uuidString.lowercased())
        .appendingPathExtension("json")
      #expect(!FileManager.default.fileExists(atPath: unexpectedWriteURL.path))
    }
  }

  private func makeReceipt(
    status: OperationStatus,
    startedAt: Date
  ) -> OperationReceipt {
    OperationReceipt(
      kind: .optimize,
      deviceID: SimulatorID(
        rawValue: "11111111-2222-4333-8444-555555555555"
      ),
      deviceName: "测试设备",
      status: status,
      startedAt: startedAt,
      originalDeviceState: .booted
    )
  }
}

func withTemporaryDirectory<T>(
  _ body: (URL) async throws -> T
) async throws -> T {
  let base = URL(
    fileURLWithPath: NSTemporaryDirectory(),
    isDirectory: true
  ).resolvingSymlinksInPath()
  let directory =
    base
    .appendingPathComponent("SimulatorSlimmerTests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await body(directory)
}
