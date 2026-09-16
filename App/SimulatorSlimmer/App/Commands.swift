import AppKit
import Sparkle
import SwiftUI

struct SimulatorSlimmerCommands: Commands {
  @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
  @AppStorage("menuBarEnabled") private var menuBarEnabled = true
  @Environment(\.dismissWindow) private var dismissWindow
  let model: AppModel
  let updaterController: SPUStandardUpdaterController

  var body: some Commands {
    CommandGroup(replacing: .appTermination) {
      Button(L10n.text("command.quit")) {
        if menuBarEnabled {
          dismissWindow(id: "main")
          NSApp.setActivationPolicy(.accessory)
        } else {
          NSApp.terminate(nil)
        }
      }
      .keyboardShortcut("q", modifiers: .command)
    }

    CommandGroup(replacing: .newItem) {
      Button(L10n.text("command.create-simulator")) {
        model.showCreateSimulator()
      }
      .keyboardShortcut("n", modifiers: .command)
    }

    CommandGroup(after: .sidebar) {
      Button(L10n.text("command.refresh")) {
        WindowFocus.endTextEditing()
        model.refreshOverview(reason: .manual)
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isLoadingOverview)
    }

    CommandGroup(replacing: .appSettings) {
      Button(L10n.text("command.settings")) {
        WindowFocus.endTextEditing()
        model.showSettings()
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandGroup(after: .appInfo) {
      Button(L10n.text("command.check-for-updates")) {
        updaterController.checkForUpdates(nil)
      }
    }
  }
}
