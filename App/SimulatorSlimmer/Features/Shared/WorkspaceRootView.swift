import AppKit
import SimulatorSlimmerCore
import SwiftUI

struct WorkspaceRootView: View {
  @Bindable var model: AppModel
  @AppStorage("automaticRefresh") private var automaticRefresh = true
  @AppStorage("automaticRefreshInterval") private var automaticRefreshInterval = 30.0
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationSplitView {
      SimulatorSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if model.isLoadingOverview {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("accessibility.refreshing")
        }

        Button {
          model.refreshOverview()
        } label: {
          Label("action.refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isLoadingOverview)
        .minimumHitArea()
        .help("action.refresh.help")
      }
    }
    .onAppear {
      model.load()
      positionWindowOnBuiltInDisplayIfRequested()
    }
    .task(id: refreshConfiguration) {
      guard refreshConfiguration.isEnabled else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(
            for: .seconds(refreshConfiguration.interval),
            clock: .continuous
          )
        } catch {
          return
        }
        guard !model.hasRunningOperation else { continue }
        model.refreshOverview()
      }
    }
    .onChange(of: model.sidebarSelection) { _, selection in
      if case .device(let id) = selection {
        UserDefaults.standard.set(id.rawValue, forKey: "selectedDeviceID")
      }
      model.selectionChanged()
    }
    .sheet(item: $model.previewPresentation) { presentation in
      OperationPreviewSheet(
        presentation: presentation,
        cancel: { model.previewPresentation = nil },
        confirm: { model.runPreviewedOperation() }
      )
    }
    .sheet(item: $model.batchPreviewPresentation) { presentation in
      BatchPreviewSheet(
        presentation: presentation,
        cancel: { model.dismissBatchPreview() },
        confirm: { model.confirmBatchPreview() }
      )
    }
    .sheet(item: $model.dangerPresentation) { presentation in
      DangerConfirmationSheet(
        presentation: presentation,
        cancel: { model.dangerPresentation = nil },
        confirm: { cloneName in
          model.confirmDanger(presentation, cloneName: cloneName)
        }
      )
    }
    .sheet(item: $model.receiptPresentation) { receipt in
      ReceiptDetailSheet(
        receipt: receipt,
        canContinueVerification: model.canContinueVerification(from: receipt),
        canRestore: model.canRestore(from: receipt),
        dismiss: { model.receiptPresentation = nil },
        continueVerification: {
          model.receiptPresentation = nil
          model.continueVerification(from: receipt)
        },
        restore: {
          model.receiptPresentation = nil
          model.restore(from: receipt)
        }
      )
    }
    .alert(item: $model.notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("action.ok"))
      )
    }
  }

  private var refreshConfiguration: RefreshConfiguration {
    RefreshConfiguration(
      isEnabled: automaticRefresh && scenePhase == .active,
      interval: automaticRefreshInterval
    )
  }

  private func positionWindowOnBuiltInDisplayIfRequested() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard
        arguments.contains("--ui-testing") || arguments.contains("--built-in-display")
      else { return }
      DispatchQueue.main.async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeKey }) else { return }
        let targetScreen =
          NSScreen.screens.first { screen in
            guard
              let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID
            else {
              return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
          } ?? NSScreen.main

        if let targetScreen {
          let visibleFrame = targetScreen.visibleFrame
          let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
          )
          window.setFrameOrigin(origin)
        } else {
          window.center()
        }
      }
    #endif
  }

  @ViewBuilder
  private var detail: some View {
    if let loadError = model.loadError, model.overview == nil {
      EnvironmentFailureView(message: loadError, model: model)
    } else if model.isLoadingOverview, model.overview == nil {
      LoadingDetailView()
    } else {
      switch model.sidebarSelection {
      case .device(let deviceID):
        DeviceWorkspaceView(deviceID: deviceID, model: model)
      case .batchOptimization:
        BatchOptimizationView(model: model)
      case .history:
        HistoryView(model: model)
      case .settings:
        SettingsView(model: model)
      case nil:
        NoSelectionView(model: model)
      }
    }
  }
}

private struct BatchOptimizationView: View {
  @Bindable var model: AppModel

  private let profiles: [OptimizationProfile] = [
    .conservative, .balanced, .efficient,
  ]

  private var runIsActive: Bool { model.batchRun?.isRunning == true }
  private var configurationLocked: Bool {
    runIsActive || model.isPreparingBatchPreview || model.batchPreviewPresentation != nil
  }
  private var selectedCount: Int { model.batchSelectedDeviceIDs.count }
  private var hasBusySelection: Bool {
    model.availableBatchDevices.contains {
      model.batchSelectedDeviceIDs.contains($0.id) && model.isDeviceBusy($0.id)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider()

      if model.availableBatchDevices.isEmpty, model.batchRun == nil {
        ContentUnavailableView {
          Label("batch.empty.title", systemImage: "rectangle.stack.badge.minus")
        } description: {
          Text("batch.empty.message")
        } actions: {
          Button("action.refresh") { model.refreshOverview() }
            .buttonStyle(PressablePrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("batch-optimization.empty")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            configurationPanel
            if model.isPreparingBatchPreview {
              batchPreviewProgressPanel
            }
            if let run = model.batchRun {
              queuePanel(run)
            }
          }
          .frame(maxWidth: 820)
          .padding(InstrumentTheme.pagePadding)
          .frame(maxWidth: .infinity, alignment: .top)
        }
      }
    }
    .background(Color.instrumentBackground)
    .navigationTitle("sidebar.batch-optimization")
    .accessibilityIdentifier("batch-optimization.page")
  }

  private var pageHeader: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text("batch.title")
          .font(.title2.weight(.semibold))
        Text("batch.subtitle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let run = model.batchRun {
        Label(
          run.isRunning
            ? L10n.text("batch.status.running")
            : L10n.text("batch.status.finished"),
          systemImage: run.isRunning ? "progress.indicator" : "checkmark.circle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(run.isRunning ? Color.mint : Color.secondary)
      }
    }
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 16)
    .background(.bar)
  }

  private var configurationPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(
          title: "batch.configuration.title",
          detail: L10n.formatted("batch.format.selected", selectedCount)
        )

        Picker("batch.profile.title", selection: $model.batchProfile) {
          ForEach(profiles) { profile in
            Text(profile.localizedTitle).tag(profile)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minHeight: InstrumentTheme.minimumHitSize)
        .disabled(configurationLocked)
        .accessibilityLabel("batch.profile.title")

        HStack(alignment: .top, spacing: 10) {
          Image(systemName: model.batchProfile == .efficient ? "bolt.fill" : "info.circle.fill")
            .foregroundStyle(model.batchProfile == .efficient ? .orange : .mint)
            .accessibilityHidden(true)
          Text(model.batchProfile.localizedSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        HStack(spacing: 8) {
          Text("batch.devices.title")
            .font(.headline)
          Spacer()
          Button("batch.action.select-all") { model.selectAllBatchDevices() }
            .buttonStyle(.borderless)
            .minimumHitArea()
            .disabled(configurationLocked || selectedCount == model.availableBatchDevices.count)
          Button("batch.action.select-none") { model.clearBatchDevices() }
            .buttonStyle(.borderless)
            .minimumHitArea()
            .disabled(configurationLocked || selectedCount == 0)
        }

        VStack(spacing: 0) {
          ForEach(model.availableBatchDevices) { device in
            BatchDeviceSelectionRow(
              device: device,
              isSelected: Binding(
                get: { model.batchSelectedDeviceIDs.contains(device.id) },
                set: { model.toggleBatchDevice(device.id, selected: $0) }
              ),
              isBusy: model.isDeviceBusy(device.id)
            )
            .disabled(configurationLocked)
            if device.id != model.availableBatchDevices.last?.id { Divider() }
          }
        }
        .padding(.horizontal, 12)
        .background(
          Color.instrumentRaised,
          in: RoundedRectangle(cornerRadius: InstrumentTheme.innerRadius, style: .continuous)
        )

        if hasBusySelection, !configurationLocked {
          NoticeStrip(
            tone: .warning,
            title: L10n.text("batch.busy.title"),
            message: L10n.text("batch.busy.message")
          )
        }

        Divider()

        HStack(spacing: 12) {
          Label("batch.serial-note", systemImage: "arrow.down.to.line.compact")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if model.batchRun?.isRunning == false {
            Button("batch.action.clear-results") { model.resetBatchOptimization() }
              .buttonStyle(.borderless)
              .minimumHitArea()
              .disabled(configurationLocked)
          }
          if model.isPreparingBatchPreview {
            Button("batch.preview.cancel") {
              model.cancelBatchPreviewPreparation()
            }
            .minimumHitArea()
          } else {
            Button {
              model.startBatchOptimization()
            } label: {
              Label(
                model.batchRun == nil
                  ? L10n.text("batch.action.start")
                  : L10n.text("batch.action.run-again"),
                systemImage: "checkmark.shield"
              )
            }
            .buttonStyle(PressablePrimaryButtonStyle())
            .disabled(configurationLocked || selectedCount == 0)
            .accessibilityHint("batch.action.start.hint")
          }
        }
      }
    }
  }

  private var batchPreviewProgressPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        InstrumentSectionLabel(
          title: "batch.preview.preparing.title",
          detail: L10n.formatted(
            "batch.format.position",
            model.batchPreviewCompletedCount,
            model.batchPreviewTotalCount
          )
        )
        Text("batch.preview.preparing.message")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ProgressView(
          value: Double(model.batchPreviewCompletedCount),
          total: Double(max(model.batchPreviewTotalCount, 1))
        )
        .accessibilityLabel("batch.preview.preparing.title")
        .accessibilityValue(
          L10n.formatted(
            "batch.progress.accessibility",
            model.batchPreviewCompletedCount,
            model.batchPreviewTotalCount
          )
        )
      }
    }
    .accessibilityIdentifier("batch-preview.progress")
  }

  private func queuePanel(_ run: BatchOptimizationRun) -> some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(
          title: "batch.queue.title",
          detail: L10n.formatted("batch.format.position", run.currentPosition, run.items.count)
        )

        if run.isRunning {
          if run.cancellationRequested {
            NoticeStrip(
              tone: .warning,
              title: L10n.text("batch.cancelling.title"),
              message: L10n.text("batch.cancelling.message")
            )
          } else if let current = run.currentItem {
            HStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 3) {
                Text("batch.current-device")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(current.device.name)
                  .font(.headline)
              }
              Spacer()
              Text(current.detail ?? L10n.text("batch.operation.preparing"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            }
            .padding(12)
            .background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
          }

          ProgressView(value: run.progress) {
            Text("batch.overall-progress")
          } currentValueLabel: {
            Text(L10n.formatted("batch.progress.completed", run.completedCount, run.items.count))
              .monospacedDigit()
          }
          .accessibilityLabel("batch.overall-progress")
          .accessibilityValue(
            L10n.formatted("batch.progress.accessibility", run.completedCount, run.items.count)
          )
        } else {
          BatchSummaryView(run: run)
        }

        Divider()

        VStack(spacing: 0) {
          ForEach(run.items) { item in
            BatchQueueRow(item: item, showReceipt: model.showReceipt)
            if item.id != run.items.last?.id { Divider() }
          }
        }

        if run.isRunning {
          Divider()
          HStack {
            Text("batch.cancel.explanation")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
              model.cancelBatchOptimization()
            } label: {
              Label("batch.action.cancel", systemImage: "stop.circle")
            }
            .disabled(run.cancellationRequested)
            .minimumHitArea()
          }
        }
      }
    }
  }
}

private struct BatchDeviceSelectionRow: View {
  let device: SimulatorDevice
  @Binding var isSelected: Bool
  let isBusy: Bool

  var body: some View {
    Toggle(isOn: $isSelected) {
      HStack(spacing: 10) {
        Image(
          systemName: device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
            ? "ipad" : "iphone"
        )
        .frame(width: 22)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(device.name)
            .font(.subheadline.weight(.medium))
          Text(device.runtimeName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isBusy {
          Label("batch.device.busy", systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          SimulatorStateChip(state: device.state)
        }
      }
    }
    .toggleStyle(.checkbox)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(device.name)
    .accessibilityValue(
      isBusy
        ? L10n.text("batch.device.busy.accessibility")
        : L10n.formatted(
          "batch.device.selection.accessibility",
          isSelected
            ? L10n.text("batch.selection.selected") : L10n.text("batch.selection.unselected"),
          device.runtimeName,
          device.state.localizedTitle
        )
    )
  }
}

private struct BatchSummaryView: View {
  let run: BatchOptimizationRun

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      NoticeStrip(
        tone: run.failedCount == 0 && run.cancelledCount == 0 ? .success : .warning,
        title: L10n.text("batch.finished.title"),
        message: L10n.formatted(
          "batch.finished.message",
          run.succeededCount,
          run.failedCount,
          run.skippedCount,
          run.cancelledCount
        )
      )
      HStack(spacing: 0) {
        summaryValue("batch.summary.succeeded", run.succeededCount, .mint)
        Divider().frame(height: 34)
        summaryValue("batch.summary.failed", run.failedCount, .red)
        Divider().frame(height: 34)
        summaryValue("batch.summary.skipped", run.skippedCount, .orange)
        Divider().frame(height: 34)
        summaryValue("batch.summary.cancelled", run.cancelledCount, .secondary)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func summaryValue(
    _ title: LocalizedStringResource,
    _ value: Int,
    _ tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value.formatted())
        .font(.title3.weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BatchQueueRow: View {
  let item: BatchQueueItem
  let showReceipt: (OperationReceipt) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: item.status.symbolName)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(item.status.tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(item.device.name)
            .font(.subheadline.weight(.medium))
          Text(item.status.localizedTitle)
            .font(.caption.weight(.medium))
            .foregroundStyle(item.status.tint)
        }
        Text(item.detail ?? item.device.runtimeName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(item.device.name)
      .accessibilityValue(
        "\(item.status.localizedTitle)，\(item.detail ?? item.device.runtimeName)"
      )
      .accessibilityIdentifier("batch.queue.item.\(item.id.rawValue)")
      Spacer(minLength: 8)
      if item.status == .running {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("accessibility.device-operation-running")
      }
      if let receipt = item.receipt {
        Button {
          showReceipt(receipt)
        } label: {
          Image(systemName: "doc.text.magnifyingglass")
        }
        .buttonStyle(.borderless)
        .minimumHitArea()
        .help("receipt.view")
        .accessibilityLabel("receipt.view")
      }
    }
    .frame(minHeight: 52)
  }
}

extension BatchQueueItemStatus {
  fileprivate var symbolName: String {
    switch self {
    case .pending: "circle"
    case .running: "progress.indicator"
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .skipped: "arrow.right.circle.fill"
    case .cancelled: "minus.circle.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .pending, .cancelled: .secondary
    case .running, .succeeded: .mint
    case .failed: .red
    case .skipped: .orange
    }
  }
}

private struct RefreshConfiguration: Hashable {
  let isEnabled: Bool
  let interval: Double
}

private struct EnvironmentFailureView: View {
  let message: String
  let model: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("empty.xcode-tools.title", systemImage: "hammer.fill")
    } description: {
      VStack(spacing: 8) {
        Text("empty.xcode-tools.message")
        Text(message)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
    } actions: {
      HStack {
        Button("action.copy-check-command") {
          model.copy("xcrun simctl list devices -j")
        }
        Button("action.retry") {
          model.refreshOverview()
        }
        .buttonStyle(PressablePrimaryButtonStyle())
      }
    }
  }
}

private struct NoSelectionView: View {
  let model: AppModel

  var body: some View {
    if model.overview?.inventory.devices.isEmpty == false {
      ContentUnavailableView(
        "empty.selection.title",
        systemImage: "iphone.gen3",
        description: Text("empty.selection.message")
      )
    } else {
      ContentUnavailableView {
        Label("empty.devices.title", systemImage: "rectangle.stack.badge.plus")
      } description: {
        Text("empty.devices.message")
      } actions: {
        HStack {
          Button("action.open-xcode") { model.openXcode() }
          Button("action.refresh") { model.refreshOverview() }
            .buttonStyle(PressablePrimaryButtonStyle())
        }
      }
    }
  }
}
