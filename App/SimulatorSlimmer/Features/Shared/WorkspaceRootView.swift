import AppKit
import SimulatorSlimmerCore
import SwiftUI

struct WorkspaceRootView: View {
  @Bindable var model: AppModel
  @AppStorage("automaticRefresh") private var automaticRefresh = true
  @AppStorage("automaticRefreshInterval") private var automaticRefreshInterval = 30.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var isRefreshHovered = false

  var body: some View {
    NavigationSplitView {
      SimulatorSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dismissWindowTextEditingOnTap()
        .overlay(alignment: .bottom) {
          if let toast = model.toast {
            InstrumentToast(message: toast.message)
              .padding(.bottom, 20)
              .transition(toastTransition)
              .allowsHitTesting(false)
          }
        }
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.18),
          value: model.toast?.id
        )
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          WindowFocus.endTextEditing()
          model.refreshOverview()
        } label: {
          RefreshToolbarIcon(isRefreshing: model.isLoadingOverview)
        }
        .buttonStyle(RefreshToolbarButtonStyle(isHovered: isRefreshHovered))
        .disabled(model.isLoadingOverview)
        .onHover { isRefreshHovered = $0 }
        .accessibilityLabel(
          model.isLoadingOverview
            ? L10n.text("accessibility.refreshing")
            : L10n.text("action.refresh")
        )
        .accessibilityIdentifier("toolbar.refresh")
        .help("action.refresh.help")
      }
    }
    .suppressInitialFocus()
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
        guard !model.hasRunningOperation, !model.isLoadingOverview else { continue }
        model.refreshOverview()
      }
    }
    .task(id: model.toast?.id) {
      guard let toastID = model.toast?.id else { return }
      #if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
      #endif
      do {
        try await Task.sleep(for: .seconds(3), clock: .continuous)
      } catch {
        return
      }
      guard model.toast?.id == toastID else { return }
      model.toast = nil
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
    .sheet(item: $model.workspaceModal) { modal in
      switch modal {
      case .batchOptimization:
        BatchOptimizationSheet(model: model)
      case .createSimulator:
        CreateSimulatorSheet(model: model)
      case .settings:
        SettingsSheet(model: model)
      }
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

  private var toastTransition: AnyTransition {
    guard !reduceMotion else { return .identity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 8)),
      removal: .opacity.combined(with: .offset(y: -6))
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
      case nil:
        NoSelectionView(model: model)
      }
    }
  }
}

private struct WorkspaceSheetHeader: View {
  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource
  let systemImage: String

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.mint)
        .frame(width: 44, height: 44)
        .background(
          Color.mint.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title3.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }
}

private struct BatchOptimizationSheet: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceSheetHeader(
        title: "sidebar.batch-optimization",
        subtitle: "batch.subtitle",
        systemImage: "rectangle.stack.badge.play"
      )
      Divider()
      BatchOptimizationView(model: model)
      Divider()
      HStack {
        if model.batchRun?.isRunning == true {
          Label("batch.status.running", systemImage: "progress.indicator")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("action.close") { model.dismissWorkspaceModal() }
          .keyboardShortcut(.cancelAction)
          .minimumHitArea()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }
    .frame(minWidth: 820, idealWidth: 900, minHeight: 640, idealHeight: 720)
    .background(Color.instrumentBackground)
    .accessibilityIdentifier("batch-optimization.sheet")
  }
}

private struct SettingsSheet: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceSheetHeader(
        title: "sidebar.settings",
        subtitle: "settings.subtitle",
        systemImage: "gearshape"
      )
      Divider()
      SettingsView()
      Divider()
      HStack {
        Spacer()
        Button("action.done") { model.dismissWorkspaceModal() }
          .keyboardShortcut(.defaultAction)
          .minimumHitArea()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }
    .frame(width: 760, height: 620)
    .background(Color.instrumentBackground)
    .accessibilityIdentifier("settings.sheet")
  }
}

private struct CreateSimulatorSheet: View {
  @Bindable var model: AppModel
  @State private var name = ""
  @State private var selectedRuntimeID = ""
  @State private var selectedDeviceTypeID = ""

  private var runtimes: [SimulatorRuntime] {
    model.simulatorCreationOptions?.runtimes ?? []
  }

  private var selectedRuntime: SimulatorRuntime? {
    runtimes.first { $0.id == selectedRuntimeID }
  }

  private var compatibleDeviceTypes: [SimulatorDeviceType] {
    guard let selectedRuntime else { return [] }
    return (model.simulatorCreationOptions?.deviceTypes ?? [])
      .filter { $0.supports(runtimeVersion: selectedRuntime.version) }
  }

  private var deviceTypeFamilies: [String] {
    ["iPhone", "iPad"].filter { family in
      compatibleDeviceTypes.contains { $0.productFamily == family }
    }
  }

  private var selectedDeviceType: SimulatorDeviceType? {
    compatibleDeviceTypes.first { $0.id == selectedDeviceTypeID }
  }

  private var effectiveName: String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? selectedDeviceType?.name ?? "" : trimmedName
  }

  private var namePlaceholder: String {
    selectedDeviceType?.name ?? L10n.text("create-simulator.name.placeholder")
  }

  private var canCreate: Bool {
    !effectiveName.isEmpty
      && !selectedRuntimeID.isEmpty
      && !selectedDeviceTypeID.isEmpty
      && !model.isCreatingSimulator
  }

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceSheetHeader(
        title: "create-simulator.title",
        subtitle: "create-simulator.subtitle",
        systemImage: "plus.rectangle.on.rectangle"
      )
      Divider()

      Group {
        if model.isLoadingSimulatorCreationOptions,
          model.simulatorCreationOptions == nil
        {
          VStack(spacing: 12) {
            ProgressView()
            Text("create-simulator.loading")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.simulatorCreationOptions == nil {
          ContentUnavailableView {
            Label("create-simulator.unavailable.title", systemImage: "exclamationmark.triangle")
          } description: {
            Text(model.simulatorCreationError ?? L10n.text("create-simulator.unavailable.message"))
          } actions: {
            Button("action.retry") { model.loadSimulatorCreationOptions(force: true) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          creationForm
        }
      }
      .padding(24)

      Divider()
      HStack(spacing: 12) {
        Spacer()
        Button("action.cancel") { model.dismissWorkspaceModal() }
          .keyboardShortcut(.cancelAction)
          .disabled(model.isCreatingSimulator)
          .minimumHitArea()
        Button {
          model.createSimulator(
            name: effectiveName,
            runtimeID: selectedRuntimeID,
            deviceTypeID: selectedDeviceTypeID
          )
        } label: {
          if model.isCreatingSimulator {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("create-simulator.creating")
          } else {
            Label("create-simulator.action.create", systemImage: "plus")
          }
        }
        .buttonStyle(PressablePrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }
    .frame(width: 560, height: 470)
    .background(Color.instrumentBackground)
    .interactiveDismissDisabled(model.isCreatingSimulator)
    .onAppear(perform: configureDefaults)
    .onChange(of: model.isLoadingSimulatorCreationOptions) { _, isLoading in
      if !isLoading { configureDefaults() }
    }
    .onChange(of: selectedRuntimeID) { _, _ in
      reconcileDeviceType()
    }
    .accessibilityIdentifier("create-simulator.sheet")
  }

  private var creationForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      InstrumentCard {
        VStack(spacing: 0) {
          formRow(title: "create-simulator.runtime") {
            Picker("create-simulator.runtime", selection: $selectedRuntimeID) {
              ForEach(runtimes) { runtime in
                Text(runtime.name).tag(runtime.id)
              }
            }
            .labelsHidden()
            .frame(width: 220)
          }
          Divider()
          formRow(title: "create-simulator.device-type") {
            Picker("create-simulator.device-type", selection: $selectedDeviceTypeID) {
              ForEach(deviceTypeFamilies, id: \.self) { family in
                Section {
                  ForEach(
                    compatibleDeviceTypes.filter { $0.productFamily == family }
                  ) { deviceType in
                    Text(deviceType.name).tag(deviceType.id)
                  }
                } header: {
                  Text(family)
                }
              }
            }
            .labelsHidden()
            .frame(width: 220)
          }
          Divider()
          formRow(title: "create-simulator.name") {
            TextField(
              "create-simulator.name",
              text: $name,
              prompt: Text(namePlaceholder)
            )
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }
        }
      }

      if let error = model.simulatorCreationError {
        NoticeStrip(
          tone: .warning,
          title: L10n.text("create-simulator.failed.title"),
          message: error
        )
      }
      Spacer(minLength: 0)
    }
  }

  private func formRow<Control: View>(
    title: LocalizedStringResource,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 20) {
      Text(title)
        .font(.body.weight(.medium))
      Spacer()
      control()
    }
    .frame(minHeight: 54)
  }

  private func configureDefaults() {
    guard !runtimes.isEmpty else { return }
    if !runtimes.contains(where: { $0.id == selectedRuntimeID }) {
      selectedRuntimeID = runtimes[0].id
    }
    reconcileDeviceType()
  }

  private func reconcileDeviceType() {
    guard !compatibleDeviceTypes.isEmpty else {
      selectedDeviceTypeID = ""
      return
    }
    if compatibleDeviceTypes.contains(where: { $0.id == selectedDeviceTypeID }) {
      return
    }

    let preferredID = model.selectedDevice?.deviceTypeIdentifier
    let preferred =
      preferredID.flatMap { id in compatibleDeviceTypes.first { $0.id == id } }
      ?? compatibleDeviceTypes.first {
        $0.name.localizedCaseInsensitiveContains("iPhone 17 Pro")
      }
      ?? compatibleDeviceTypes[0]
    selectedDeviceTypeID = preferred.id
  }
}

private struct RefreshToolbarIcon: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isRefreshing: Bool

  var body: some View {
    ZStack {
      Image(systemName: "arrow.clockwise")
        .opacity(isRefreshing ? 0 : 1)
        .scaleEffect(isRefreshing && !reduceMotion ? 0.25 : 1)
        .blur(radius: isRefreshing && !reduceMotion ? 4 : 0)

      ProgressView()
        .controlSize(.small)
        .opacity(isRefreshing ? 1 : 0)
        .scaleEffect(isRefreshing || reduceMotion ? 1 : 0.25)
        .blur(radius: isRefreshing || reduceMotion ? 0 : 4)
    }
    .frame(
      width: InstrumentTheme.minimumHitSize,
      height: InstrumentTheme.minimumHitSize
    )
    .contentShape(Circle())
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.3),
      value: isRefreshing
    )
  }
}

private struct RefreshToolbarButtonStyle: ButtonStyle {
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
      .background {
        Circle()
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(isEnabled ? 1 : 0.72)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.1),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.12),
        value: isHovered
      )
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    guard isEnabled else { return .clear }
    if isPressed {
      return Color.primary.opacity(0.10)
    }
    return isHovered ? Color.primary.opacity(0.055) : .clear
  }
}

private struct BatchOptimizationView: View {
  @Bindable var model: AppModel

  private let profiles: [OptimizationProfile] = [
    .conservative, .balanced, .efficient, .custom,
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
    Group {
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
          LazyVStack(alignment: .leading, spacing: 16) {
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
    .sheet(item: $model.batchPreviewPresentation) { presentation in
      BatchPreviewSheet(
        presentation: presentation,
        cancel: { model.dismissBatchPreview() },
        confirm: { model.confirmBatchPreview() }
      )
    }
    .accessibilityIdentifier("batch-optimization.page")
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
          Image(systemName: profileSummarySymbol)
            .foregroundStyle(profileSummaryColor)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(model.batchProfile.localizedSummary)
            if model.batchProfile == .custom {
              Text(
                L10n.formatted(
                  "batch.custom-selection.summary",
                  model.customDisabledLabels.count
                )
              )
              .font(.caption)
            }
          }
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        if model.batchProfile == .custom {
          Divider()
          if let snapshot = model.customServiceSnapshot {
            CustomServicePicker(snapshot: snapshot, model: model)
              .disabled(configurationLocked)
          } else if model.isLoadingCustomServiceSnapshot {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
              Text("batch.custom-selection.loading")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: InstrumentTheme.minimumHitSize)
          } else {
            Label("batch.custom-selection.unavailable", systemImage: "exclamationmark.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
            .frame(minHeight: InstrumentTheme.minimumHitSize)
          }
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

  private var profileSummarySymbol: String {
    switch model.batchProfile {
    case .efficient:
      "bolt.fill"
    case .custom:
      "slider.horizontal.3"
    default:
      "info.circle.fill"
    }
  }

  private var profileSummaryColor: Color {
    model.batchProfile == .efficient ? .orange : .mint
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
            BatchQueueRow(item: item)
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
    HStack(alignment: .center, spacing: 10) {
      Toggle("", isOn: $isSelected)
        .labelsHidden()
        .toggleStyle(.checkbox)
        .minimumHitArea()

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
    .frame(minHeight: 48)
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

  var body: some View {
    rowContent
      .accessibilityElement(children: .combine)
      .accessibilityLabel(item.device.name)
      .accessibilityValue(accessibilityValue)
      .accessibilityIdentifier("batch.queue.item.\(item.id.rawValue)")
  }

  private var rowContent: some View {
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
      Spacer(minLength: 8)
      if item.status == .running {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("accessibility.device-operation-running")
      }
    }
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
  }

  private var accessibilityValue: String {
    "\(item.status.localizedTitle)，\(item.detail ?? item.device.runtimeName)"
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
