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
        .frame(minWidth: 980, minHeight: 640)
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      SimulatorSlimmerCommands(model: model)
    }
  }
}
