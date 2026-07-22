import Darwin
import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("操作并发与进程树")
struct OperationSafetyBehaviorTests {
  @Test("同一设备在锁释放前不能再次进入")
  func gateSerializesOperationsForSameDevice() async throws {
    try await withTemporaryDirectory { directory in
      let gate = OperationGate(locksDirectoryURL: directory)
      let deviceID = SimulatorID(
        rawValue: "11111111-2222-4333-8444-555555555555"
      )
      let firstLock = try await gate.acquire(for: deviceID)

      do {
        _ = try await gate.acquire(for: deviceID)
        Issue.record("同一设备的第二个操作不应获得锁")
      } catch let error as SimulatorWorkspaceError {
        guard case .operationAlreadyRunning(let lockedID) = error else {
          Issue.record("收到错误类型不符合预期：\(error)")
          await firstLock.release()
          return
        }
        #expect(lockedID == deviceID)
      }

      await firstLock.release()
      let nextLock = try await gate.acquire(for: deviceID)
      await nextLock.release()
    }
  }

  @Test("进程树包含所有层级后代且排除无关进程")
  func descendantProcessTreeTraversesBranchesAndCyclesSafely() {
    let parents: [pid_t: pid_t] = [
      100: 99,
      101: 100,
      102: 101,
      103: 100,
      104: 200,
      105: 105,
      106: 102,
      200: 201,
      201: 200,
    ]

    let descendants = LibprocMemoryInspector.descendantPIDs(
      parents: parents,
      rootPID: 100
    )

    #expect(descendants == [100, 101, 102, 103, 106])
    #expect(!descendants.contains(104))
    #expect(!descendants.contains(105))
    #expect(!descendants.contains(200))
    #expect(!descendants.contains(201))
  }
}
