import Foundation

public protocol SimulatorWorkspaceClient: Sendable {
  func overview() async throws -> WorkspaceOverview
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
