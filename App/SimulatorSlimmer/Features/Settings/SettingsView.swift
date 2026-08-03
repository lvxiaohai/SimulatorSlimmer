import SimulatorSlimmerCore
import SwiftUI

struct SettingsView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
  @AppStorage("automaticRefresh") private var automaticRefresh = true
  @AppStorage("automaticRefreshInterval") private var automaticRefreshInterval = 30.0
  @AppStorage("showUnavailableDevices") private var showUnavailableDevices = false
  @AppStorage("menuBarEnabled") private var menuBarEnabled = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        menuBarSettings
        generalSettings
      }
      .frame(maxWidth: 620)
      .padding(InstrumentTheme.pagePadding)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(Color.instrumentBackground)
    .navigationTitle("sidebar.settings")
    .accessibilityIdentifier("settings.page")
  }

  private var menuBarSettings: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 0) {
        InstrumentSectionLabel(title: "settings.menu-bar")
          .padding(.bottom, 10)

        Divider()
        settingToggle(
          title: L10n.text("settings.menu-bar.enabled"),
          summary: L10n.text("settings.menu-bar.enabled.summary"),
          isOn: $menuBarEnabled
        )
      }
    }
  }

  private var generalSettings: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 0) {
        InstrumentSectionLabel(title: "settings.general")
          .padding(.bottom, 10)

        Divider()
        settingRow(
          title: L10n.text("settings.language"),
          summary: L10n.text("settings.language.summary")
        ) {
          Picker("settings.language", selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(language.title).tag(language.rawValue)
            }
          }
          .labelsHidden()
          .controlSize(.regular)
          .frame(minWidth: 140, alignment: .trailing)
          .fixedSize(horizontal: true, vertical: false)
        }

        Divider()
        settingToggle(
          title: L10n.text("settings.auto-refresh"),
          summary: L10n.text("settings.auto-refresh.summary"),
          isOn: $automaticRefresh
        )

        if automaticRefresh {
          VStack(alignment: .leading, spacing: 0) {
            Divider()
            settingRow(
              title: L10n.text("settings.refresh-interval"),
              summary: L10n.text("settings.refresh-interval.summary")
            ) {
              Picker("settings.refresh-interval", selection: $automaticRefreshInterval) {
                Text("settings.interval.15").tag(15.0)
                Text("settings.interval.30").tag(30.0)
                Text("settings.interval.60").tag(60.0)
              }
              .labelsHidden()
              .controlSize(.regular)
              .frame(minWidth: 112, alignment: .trailing)
              .fixedSize(horizontal: true, vertical: false)
            }
          }
          .padding(.leading, 12)
          .transition(.opacity.combined(with: .offset(y: -6)))
        }

        Divider()
        settingToggle(
          title: L10n.text("settings.show-unavailable"),
          summary: L10n.text("settings.show-unavailable.summary"),
          isOn: $showUnavailableDevices
        )
      }
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.16),
        value: automaticRefresh
      )
    }
  }

  private func settingToggle(
    title: String,
    summary: String,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.medium))
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .frame(
      maxWidth: .infinity,
      minHeight: InstrumentTheme.minimumHitSize,
      alignment: .leading
    )
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  private func settingRow<Control: View>(
    title: String,
    summary: String,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.medium))
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 20)
      control()
    }
    .frame(
      maxWidth: .infinity,
      minHeight: InstrumentTheme.minimumHitSize,
      alignment: .leading
    )
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}
