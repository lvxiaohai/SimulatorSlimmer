import AppKit
import SimulatorSlimmerCore
import SwiftUI

struct SettingsView: View {
  let model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("automaticRefresh") private var automaticRefresh = true
  @AppStorage("automaticRefreshInterval") private var automaticRefreshInterval = 30.0
  @AppStorage("showUnavailableDevices") private var showUnavailableDevices = false
  @AppStorage("defaultProfile") private var defaultProfile = OptimizationProfile.balanced.rawValue

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        generalSettings
        safetySettings
        privacyPanel
        aboutPanel
      }
      .frame(maxWidth: 760)
      .padding(InstrumentTheme.pagePadding)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(Color.instrumentBackground)
    .navigationTitle("sidebar.settings")
    .accessibilityIdentifier("settings.page")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("settings.title")
        .font(.title2.weight(.semibold))
      Text("settings.subtitle")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var generalSettings: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        InstrumentSectionLabel(title: "settings.general")

        settingToggle(
          title: L10n.text("settings.auto-refresh"),
          summary: L10n.text("settings.auto-refresh.summary"),
          isOn: $automaticRefresh
        )

        if automaticRefresh {
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("settings.refresh-interval")
              Text("settings.refresh-interval.summary")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("settings.refresh-interval", selection: $automaticRefreshInterval) {
              Text("settings.interval.15").tag(15.0)
              Text("settings.interval.30").tag(30.0)
              Text("settings.interval.60").tag(60.0)
            }
            .labelsHidden()
            .frame(width: 120)
          }
          .frame(minHeight: 40)
        }

        Divider()
        settingToggle(
          title: L10n.text("settings.show-unavailable"),
          summary: L10n.text("settings.show-unavailable.summary"),
          isOn: $showUnavailableDevices
        )

        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("settings.default-profile")
            Text("settings.default-profile.summary")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Picker("settings.default-profile", selection: $defaultProfile) {
            ForEach(OptimizationProfile.allCases.filter { $0 != .custom }) { profile in
              Text(profile.localizedTitle).tag(profile.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 140)
        }
        .frame(minHeight: 40)
      }
    }
  }

  private var safetySettings: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        InstrumentSectionLabel(title: "settings.safety")
        HStack(spacing: 10) {
          Image(systemName: "checkmark.shield.fill")
            .foregroundStyle(.mint)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("settings.cleanup-confirmation-required")
            Text("settings.cleanup-confirmation-required.summary")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .frame(minHeight: 40)

        Divider()

        HStack(spacing: 10) {
          Image(systemName: "lock.shield.fill")
            .foregroundStyle(.mint)
            .accessibilityHidden(true)
          Text("settings.destructive-note")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(minHeight: 40)
      }
    }
  }

  private var privacyPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: "network.slash")
            .font(.title2)
            .foregroundStyle(.mint)
            .frame(width: 36)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text("settings.privacy.title")
              .font(.headline)
            Text("settings.privacy.message")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Divider()

        HStack(spacing: 12) {
          Image(systemName: "doc.zipper")
            .foregroundStyle(.mint)
            .frame(width: 36)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("diagnostics.export.label")
            Text("diagnostics.export.summary")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if model.isExportingDiagnostics {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("diagnostics.export.progress")
          }
          Button("diagnostics.export.action") {
            model.exportDiagnostics()
          }
          .disabled(model.isExportingDiagnostics)
          .minimumHitArea()
        }
      }
    }
  }

  private var aboutPanel: some View {
    InstrumentCard {
      HStack(spacing: 14) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(
                colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                lineWidth: 1
              )
          }
          .frame(width: 52, height: 52)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("app.name")
            .font(.headline)
          Text(L10n.formatted("settings.version", appVersion))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          Text("settings.copyright")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("settings.license")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("settings.reset") {
          resetSettings()
        }
        .minimumHitArea()
      }
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
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .frame(minHeight: 40)
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  private func resetSettings() {
    automaticRefresh = true
    automaticRefreshInterval = 30
    showUnavailableDevices = false
    defaultProfile = OptimizationProfile.balanced.rawValue
  }
}
