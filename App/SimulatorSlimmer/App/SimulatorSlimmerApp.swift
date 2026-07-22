import SimulatorSlimmerCore
import SwiftUI

@main
@MainActor
struct SimulatorSlimmerApp: App {
  @State private var model = AppModel(workspace: WorkspaceFactory.make())

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
        .environment(model)
        .tint(.mint)
        .frame(minWidth: 920, minHeight: 620)
    }
    .defaultSize(width: 1120, height: 720)
    .commands {
      SimulatorSlimmerCommands(model: model)
    }
  }
}
