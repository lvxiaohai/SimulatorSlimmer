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
          sectionPicker
          sectionContent(for: device)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    .frame(maxWidth: 480)
    .minimumHitArea()
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 10)
    .accessibilityLabel("device.section")
  }

  private func unsupportedFeature(_ snapshot: DeviceSnapshot) -> some View {
    ScrollView {
      NoticeStrip(
        tone: snapshot.optimizationSupport == .unavailableRuntime ? .error : .warning,
        title: snapshot.optimizationSupport == .unavailableRuntime
          ? L10n.text("runtime.unavailable.title")
          : L10n.text("runtime.unsupported.title"),
        message: snapshot.optimizationSupport == .unavailableRuntime
          ? snapshot.device.availabilityError ?? L10n.text("runtime.unavailable.message")
          : L10n.formatted("runtime.unsupported.message", snapshot.device.runtimeName)
      )
      .frame(maxWidth: 760)
      .padding(InstrumentTheme.pagePadding)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .accessibilityIdentifier("runtime-unsupported.page")
  }

  @ViewBuilder
  private func sectionContent(for device: SimulatorDevice) -> some View {
    switch model.selectedSection {
    case .applications:
      ApplicationsView(device: device, model: model)
    case .optimization, .storage, .device:
      snapshotDependentContent
    }
  }

  @ViewBuilder
  private var snapshotDependentContent: some View {
    if let snapshot = model.snapshot, snapshot.device.id == deviceID {
      sectionContent(snapshot)
    } else if let message = model.snapshotLoadError {
      ContentUnavailableView {
        Label("error.inspect.title", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("action.retry") {
          model.inspectSelectedDevice()
        }
        .buttonStyle(PressablePrimaryButtonStyle())
      }
    } else {
      LoadingDetailView()
    }
  }

  @ViewBuilder
  private func sectionContent(_ snapshot: DeviceSnapshot) -> some View {
    switch model.selectedSection {
    case .optimization:
      if snapshot.optimizationSupport == .supported {
        OptimizationView(snapshot: snapshot, model: model)
      } else {
        unsupportedFeature(snapshot)
      }
    case .storage:
      if snapshot.optimizationSupport == .supported {
        StorageView(snapshot: snapshot, model: model)
      } else {
        unsupportedFeature(snapshot)
      }
    case .device:
      DeviceManagementView(snapshot: snapshot, model: model)
    case .applications:
      EmptyView()
    }
  }
}

private struct DeviceHeader: View {
  let device: SimulatorDevice
  let model: AppModel
  @State private var isShowingShutdownConfirmation = false

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

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(device.name)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          SimulatorStateChip(state: device.state)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.name)
        .accessibilityValue(device.state.localizedTitle)

        Button {
          model.copyUDID(device.id.rawValue)
        } label: {
          HStack(spacing: 8) {
            Text(device.runtimeName)
              .lineLimit(1)
            Text("·")
            HStack(spacing: 5) {
              Text(device.id.rawValue)
                .monospaced()
                .fixedSize(horizontal: true, vertical: false)
              Image(systemName: "doc.on.doc")
                .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 3)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("action.copy-udid")
        .accessibilityLabel("action.copy-udid")
        .accessibilityValue("\(device.runtimeName)，\(device.id.rawValue)")
      }
      .layoutPriority(1)

      Spacer()

      if model.latestRestorableReceipt != nil,
        model.optimizationSupport(for: device.id) == .supported
      {
        Menu {
          Button("action.restore-last", systemImage: "arrow.uturn.backward") {
            model.restoreLatest()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .minimumHitArea()
        .accessibilityLabel("action.more")
      }

      switch device.state {
      case .shutdown:
        Button {
          model.runDeviceOperation(.boot)
        } label: {
          compactActionLabel(title: "action.boot", symbol: "power")
        }
        .buttonStyle(.borderedProminent)
        .tint(.mint)
        .disabled(isActionDisabled)
        .minimumHitArea()
        .help("action.boot.summary")
        .accessibilityLabel("action.boot")
        .accessibilityIdentifier("device.header.boot")

      case .booted:
        Button {
          isShowingShutdownConfirmation = true
        } label: {
          compactActionLabel(title: "action.shutdown", symbol: "power")
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .disabled(isActionDisabled)
        .minimumHitArea()
        .help("action.shutdown.summary")
        .accessibilityLabel("action.shutdown")
        .accessibilityIdentifier("device.header.shutdown")

        Button {
          model.showSelectedSimulator()
        } label: {
          compactActionLabel(
            title: "action.show-simulator",
            symbol: "macwindow.on.rectangle"
          )
        }
        .buttonStyle(.borderedProminent)
        .tint(.mint)
        .disabled(isActionDisabled)
        .minimumHitArea()
        .help("action.open-simulator.summary")
        .accessibilityLabel("action.open-simulator")
        .accessibilityIdentifier("device.header.show-simulator")

      case .creating, .shuttingDown:
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(device.state.localizedTitle)

      case .unavailable, .unknown:
        EmptyView()
      }
    }
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 10)
    .background(.bar)
    .confirmationDialog(
      "operation.shutdown",
      isPresented: $isShowingShutdownConfirmation,
      titleVisibility: .visible
    ) {
      Button("action.shutdown") {
        model.runDeviceOperation(.shutdown)
      }
      Button("action.cancel", role: .cancel) {}
    } message: {
      Text("action.shutdown.summary")
    }
  }

  private var isActionDisabled: Bool {
    model.isDeviceBusy(device.id) || !device.isAvailable
  }

  private func compactActionLabel(title: LocalizedStringKey, symbol: String) -> some View {
    ViewThatFits(in: .horizontal) {
      Label(title, systemImage: symbol)
      Image(systemName: symbol)
    }
  }
}
