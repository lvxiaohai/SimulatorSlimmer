import Foundation

public protocol SimulatorWorkspaceClient: Sendable {
  func overview() async throws -> WorkspaceOverview
  func menuBarSnapshot() async throws -> MenuBarSnapshot
  func simulatorCreationOptions() async throws -> SimulatorCreationOptions
  func createSimulator(_ request: SimulatorCreationRequest) async throws -> SimulatorID
  func inspect(_ deviceID: SimulatorID) async throws -> DeviceSnapshot
  func applications(for deviceID: SimulatorID) async throws -> SimulatorApplicationListSnapshot
  func dataContainer(
    for deviceID: SimulatorID,
    bundleIdentifier: String
  ) async throws -> URL?
  func showSimulator(_ deviceID: SimulatorID) async throws
  func preview(_ operation: SimulatorOperation) async throws -> OperationPreview
  func perform(
    _ operation: SimulatorOperation
  ) async -> AsyncThrowingStream<OperationEvent, Error>
  func exportDiagnostics(to destinationURL: URL) async throws -> URL
}

public extension SimulatorWorkspaceClient {
  func menuBarSnapshot() async throws -> MenuBarSnapshot {
    let inventory = try await overview().inventory
    let devices = inventory.devices
      .filter { $0.isAvailable && $0.state == .booted }
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      .map {
        MenuBarDeviceSnapshot(
          device: $0,
          memory: nil,
          memoryError: "当前工作区不支持轻量内存采集"
        )
      }
    return MenuBarSnapshot(devices: devices)
  }
}
