import Foundation
import Testing

@testable import SimulatorSlimmerCore

private let integrationSimulatorUDID = ProcessInfo.processInfo.environment[
  "SIMULATOR_SLIMMER_INTEGRATION_UDID"
]

@Suite("真实 Simulator 集成", .serialized)
struct RealSimulatorIntegrationTests {
  @Test(
    "专用设备完成精简、验证、恢复与电源状态闭环",
    .enabled(
      if: integrationSimulatorUDID != nil,
      "仅在设置 SIMULATOR_SLIMMER_INTEGRATION_UDID 时运行"
    )
  )
  func optimizeVerifyRestoreRoundTrip() async throws {
    let rawDeviceID = try #require(integrationSimulatorUDID)
    try #require(SimctlAdapter.isValidUDID(rawDeviceID))

    let deviceID = SimulatorID(rawValue: rawDeviceID)
    let workspace = SimulatorWorkspace()
    let initialOverview = try await workspace.overview()
    let initialDevice = try #require(
      initialOverview.inventory.devices.first { $0.id == deviceID }
    )
    #expect(initialDevice.isAvailable)

    let optimizeOperation = SimulatorOperation.optimize(
      deviceID: deviceID,
      profile: .conservative,
      customDisabledLabels: []
    )
    _ = try await workspace.preview(optimizeOperation)
    let optimizeReceipt = try #require(
      try await collectIntegrationEvents(
        await workspace.perform(optimizeOperation)
      ).last?.receipt
    )
    #expect(optimizeReceipt.status == .succeeded)
    #expect(!optimizeReceipt.appliedChanges.isEmpty)
    #expect(optimizeReceipt.appliedChanges.allSatisfy { $0.succeeded })

    let restoreOperation = SimulatorOperation.restore(
      deviceID: deviceID,
      receiptID: optimizeReceipt.id
    )
    _ = try await workspace.preview(restoreOperation)
    let restoreReceipt = try #require(
      try await collectIntegrationEvents(
        await workspace.perform(restoreOperation)
      ).last?.receipt
    )
    #expect(restoreReceipt.status == .succeeded)

    let finalOverview = try await workspace.overview()
    let finalDevice = try #require(
      finalOverview.inventory.devices.first { $0.id == deviceID }
    )
    #expect(finalDevice.state == initialDevice.state)
  }
}

private func collectIntegrationEvents(
  _ stream: AsyncThrowingStream<OperationEvent, Error>
) async throws -> [OperationEvent] {
  var events: [OperationEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
}
