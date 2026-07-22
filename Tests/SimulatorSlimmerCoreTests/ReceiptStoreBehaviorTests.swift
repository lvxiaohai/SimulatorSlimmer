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
      let futureReceipt = OperationReceipt(
        schemaVersion: 2,
        kind: .optimize,
        deviceID: SimulatorID(
          rawValue: "11111111-2222-4333-8444-555555555555"
        ),
        deviceName: "未来设备",
        status: .running,
        startedAt: Date(timeIntervalSince1970: 400),
        originalDeviceState: .booted
      )
      try await store.save(futureReceipt)

      let visibleReceipts = try await store.allReceipts()
      #expect(visibleReceipts.count == 1)
      #expect(visibleReceipts.first?.id == futureReceipt.id)
      #expect(visibleReceipts.first?.schemaVersion == 2)
      #expect(visibleReceipts.first?.status == .running)

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await store.receipt(id: futureReceipt.id)
      }

      let recovered = try await store.recoverInterruptedReceipts()
      #expect(recovered.isEmpty)
      #expect(try await store.allReceipts().first?.status == .running)
      #expect(try await store.allReceipts().first?.schemaVersion == 2)
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
