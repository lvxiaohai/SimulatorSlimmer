import SwiftUI

struct SimulatorSlimmerCommands: Commands {
  let model: AppModel

  var body: some Commands {
    if !allowsAdditionalWindow {
      CommandGroup(replacing: .newItem) {}
    }

    CommandGroup(after: .sidebar) {
      Button("command.refresh") {
        model.refreshOverview()
      }
      .keyboardShortcut("r", modifiers: .command)

      Divider()

      Button("command.history") {
        model.showHistory()
      }
      .keyboardShortcut("y", modifiers: [.command, .shift])
    }

    CommandGroup(replacing: .appSettings) {
      Button("command.settings") {
        model.showSettings()
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }

  private var allowsAdditionalWindow: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--ui-testing")
    #else
      false
    #endif
  }
}
