import SimulatorSlimmerCore

enum WorkspaceFactory {
  static func make() -> any SimulatorWorkspaceClient {
    SimulatorWorkspace()
  }
}
