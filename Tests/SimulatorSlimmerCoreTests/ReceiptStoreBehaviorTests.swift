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
