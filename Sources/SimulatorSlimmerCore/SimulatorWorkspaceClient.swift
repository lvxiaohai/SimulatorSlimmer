import Foundation

public protocol SimulatorWorkspaceClient: Sendable {
  func overview() async throws -> WorkspaceOverview
  func inspect(_ deviceID: SimulatorID) async throws -> DeviceSnapshot
  func preview(_ operation: SimulatorOperation) async throws -> OperationPreview
  func perform(
    _ operation: SimulatorOperation
  ) async -> AsyncThrowingStream<OperationEvent, Error>
  func exportDiagnostics(to destinationURL: URL) async throws -> URL
}
