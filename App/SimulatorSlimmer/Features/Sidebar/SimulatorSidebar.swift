import SimulatorSlimmerCore
import SwiftUI

struct SimulatorSidebar: View {
  @Bindable var model: AppModel
  @AppStorage("showUnavailableDevices") private var showUnavailableDevices = false

  var body: some View {
    List(selection: $model.sidebarSelection) {
      if model.runtimeGroups.isEmpty, !model.searchText.isEmpty {
        ContentUnavailableView.search(text: model.searchText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(model.runtimeGroups) { group in
          let visibleDevices = group.devices.filter {
            showUnavailableDevices || $0.isAvailable
          }
          if !visibleDevices.isEmpty {
            Section(group.runtime.name) {
              ForEach(visibleDevices) { device in
                SimulatorSidebarRow(
                  device: device,
                  operation: model.operations[device.id]
                )
                .tag(SidebarSelection.device(device.id))
              }
            }
          }
        }
      }

      Section("sidebar.workspace") {
        BatchOptimizationSidebarRow(
          run: model.batchRun,
          select: model.showBatchOptimization
        )
        .tag(SidebarSelection.batchOptimization)

        Label("sidebar.history", systemImage: "clock.arrow.circlepath")
          .tag(SidebarSelection.history)
          .minimumHitArea()
          .accessibilityIdentifier("sidebar.history")

        Label("sidebar.settings", systemImage: "slider.horizontal.3")
          .tag(SidebarSelection.settings)
          .minimumHitArea()
      }
    }
    .listStyle(.sidebar)
    .searchable(
      text: $model.searchText,
      placement: .sidebar,
      prompt: Text("sidebar.search.prompt")
    )
    .navigationTitle("app.name")
  }
}

private struct BatchOptimizationSidebarRow: View {
  let run: BatchOptimizationRun?
  let select: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Label("sidebar.batch-optimization", systemImage: "rectangle.stack.badge.play")
      Spacer(minLength: 4)
      if let run, run.isRunning {
        ProgressView(value: run.progress)
          .progressViewStyle(.circular)
          .controlSize(.mini)
          .accessibilityHidden(true)
        Text(L10n.formatted("batch.format.position", run.currentPosition, run.items.count))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .minimumHitArea()
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("sidebar.batch-optimization")
  }

  private var accessibilityValue: String {
    guard let run else { return L10n.text("batch.status.ready") }
    if run.isRunning {
      return L10n.formatted(
        "batch.progress.accessibility",
        run.completedCount,
        run.items.count
      )
    }
    return L10n.formatted(
      "batch.summary.accessibility",
      run.succeededCount,
      run.failedCount
    )
  }
}

private struct SimulatorSidebarRow: View {
  let device: SimulatorDevice
  let operation: PresentedOperation?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: deviceSymbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(device.isAvailable ? .primary : .secondary)
        .frame(width: 22)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(device.name)
          .lineLimit(1)
        HStack(spacing: 5) {
          Image(systemName: device.state.symbolName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(stateTint)
          Text(device.state.localizedTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 4)

      if operation?.isRunning == true {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("accessibility.device-operation-running")
      }
    }
    .frame(minHeight: 40)
    .opacity(device.isAvailable ? 1 : 0.62)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(device.name)
    .accessibilityValue("\(device.runtimeName)，\(device.state.localizedTitle)")
  }

  private var deviceSymbol: String {
    device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
      ? "ipad"
      : "iphone"
  }

  private var stateTint: Color {
    switch device.state {
    case .booted: .mint
    case .creating, .shuttingDown: .orange
    case .unavailable: .red
    case .shutdown, .unknown: .secondary
    }
  }
}
