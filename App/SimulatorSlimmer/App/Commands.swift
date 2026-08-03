import Sparkle
import SwiftUI

struct SimulatorSlimmerCommands: Commands {
  let model: AppModel
  let updaterController: SPUStandardUpdaterController

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
        model.refreshOverview(reason: .manual)
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

    CommandGroup(after: .appInfo) {
      Button("command.check-for-updates") {
        updaterController.checkForUpdates(nil)
      }
    }
  }
}
