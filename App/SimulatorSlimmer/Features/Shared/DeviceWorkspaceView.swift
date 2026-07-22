import SimulatorSlimmerCore
import SwiftUI

struct DeviceWorkspaceView: View {
  let deviceID: SimulatorID
  @Bindable var model: AppModel

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.instrumentBackground
        .ignoresSafeArea()

      RadialGradient(
        colors: [.mint.opacity(0.09), .clear],
        center: .topTrailing,
        startRadius: 10,
        endRadius: 420
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      if let device = model.selectedDevice, device.id == deviceID {
        VStack(spacing: 0) {
          DeviceHeader(device: device, model: model)

          Divider()
          if model.isLoadingSnapshot, model.snapshot?.device.id != deviceID {
            LoadingDetailView()
          } else if let snapshot = model.snapshot, snapshot.device.id == deviceID {
            if snapshot.optimizationSupport == .supported {
              sectionPicker
              sectionContent(snapshot)
            } else {
              unsupportedWorkspace(snapshot)
            }
          } else {
            ContentUnavailableView(
              "empty.snapshot.title",
              systemImage: "waveform.path.ecg.rectangle",
              description: Text("empty.snapshot.message")
            )
          }
        }
      } else {
        LoadingDetailView()
      }
    }
  }

  private var sectionPicker: some View {
    Picker("device.section", selection: $model.selectedSection) {
      ForEach(DeviceSection.allCases) { section in
        Text(section.title).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 380)
    .frame(minHeight: InstrumentTheme.minimumHitSize)
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 14)
    .accessibilityLabel("device.section")
  }

  private func unsupportedWorkspace(_ snapshot: DeviceSnapshot) -> some View {
    VStack(spacing: 14) {
      NoticeStrip(
        tone: snapshot.optimizationSupport == .unavailableRuntime ? .error : .warning,
        title: snapshot.optimizationSupport == .unavailableRuntime
          ? L10n.text("runtime.unavailable.title")
          : L10n.text("runtime.unsupported.title"),
        message: snapshot.optimizationSupport == .unavailableRuntime
          ? snapshot.device.availabilityError ?? L10n.text("runtime.unavailable.message")
          : L10n.formatted("runtime.unsupported.message", snapshot.device.runtimeName)
      )
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.top, 14)

      DeviceManagementView(snapshot: snapshot, model: model)
    }
    .onAppear { model.selectedSection = .device }
    .accessibilityIdentifier("runtime-unsupported.page")
  }

  @ViewBuilder
  private func sectionContent(_ snapshot: DeviceSnapshot) -> some View {
    switch model.selectedSection {
    case .optimization:
      OptimizationView(snapshot: snapshot, model: model)
    case .storage:
      StorageView(snapshot: snapshot, model: model)
    case .device:
      DeviceManagementView(snapshot: snapshot, model: model)
    }
  }
}

private struct DeviceHeader: View {
  let device: SimulatorDevice
  let model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.mint.opacity(0.11))
        Image(systemName: device.deviceTypeIdentifier.contains("iPad") ? "ipad" : "iphone")
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(.mint)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(device.name)
            .font(.title2.weight(.semibold))
          SimulatorStateChip(state: device.state)
        }
        HStack(spacing: 8) {
          Text(device.runtimeName)
          Text("·")
          Text(ValueFormatter.shortIdentifier(device.id.rawValue))
            .monospaced()
          Button {
            model.copy(device.id.rawValue)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .minimumHitArea()
          .help("action.copy-udid")
          .accessibilityLabel("action.copy-udid")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Menu {
        if model.latestRestorableReceipt != nil,
          model.optimizationSupport(for: device.id) == .supported
        {
          Button("action.restore-last", systemImage: "arrow.uturn.backward") {
            model.restoreLatest()
          }
        }
        Button("action.copy-udid", systemImage: "doc.on.doc") {
          model.copy(device.id.rawValue)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .minimumHitArea()
      .accessibilityLabel("action.more")

      Button {
        model.runDeviceOperation(.openSimulator)
      } label: {
        Label("action.open-simulator", systemImage: "rectangle.on.rectangle")
      }
      .disabled(model.isDeviceBusy(device.id) || !device.isAvailable)
      .minimumHitArea()
    }
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 14)
    .background(.bar)
  }
}
