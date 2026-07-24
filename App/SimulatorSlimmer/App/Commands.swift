import SwiftUI

struct SimulatorSlimmerCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("command.create-simulator") {
        model.showCreateSimulator()
      }
      .keyboardShortcut("n", modifiers: .command)
    }

    CommandGroup(after: .sidebar) {
      Button("command.refresh") {
        WindowFocus.endTextEditing()
        model.refreshOverview()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isLoadingOverview)
    }

    CommandGroup(replacing: .appSettings) {
      Button("command.settings") {
        WindowFocus.endTextEditing()
        model.showSettings()
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}
