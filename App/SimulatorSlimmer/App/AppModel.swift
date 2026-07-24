import AppKit
import Foundation
import Observation
import SimulatorSlimmerCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
  private static let customDisabledLabelsDefaultsKey = "customDisabledLabels"

  private let workspace: any SimulatorWorkspaceClient

  var overview: WorkspaceOverview?
  var sidebarSelection: SidebarSelection?
  var workspaceModal: WorkspaceModal?
  var selectedSection: DeviceSection = .optimization
  var snapshot: DeviceSnapshot?
  var selectedProfile: OptimizationProfile = .balanced
  var customDisabledLabels: Set<String> = []
  var customServiceSnapshot: DeviceSnapshot?
  var isLoadingCustomServiceSnapshot = false
  var selectedStorageCategoryIDs: Set<String> = []
  var batchSelectedDeviceIDs: Set<SimulatorID> = []
  var batchProfile: OptimizationProfile = .balanced
  var batchRun: BatchOptimizationRun?
  var batchPreviewPresentation: BatchPreviewPresentation?
  var isPreparingBatchPreview = false
  var batchPreviewCompletedCount = 0
  var batchPreviewTotalCount = 0
  var isLoadingOverview = false
  var simulatorCreationOptions: SimulatorCreationOptions?
  var isLoadingSimulatorCreationOptions = false
  var simulatorCreationError: String?
  var isCreatingSimulator = false
  var isLoadingSnapshot = false
  var snapshotLoadError: String?
  var applicationListState: ApplicationListState = .idle
  var openingApplicationBundleID: String?
  var isExportingDiagnostics = false
  var loadError: String?
  var notice: AppNotice?
  var toast: AppToast?
  var previewPresentation: PreviewPresentation?
  var dangerPresentation: DangerPresentation?
  var operations: [SimulatorID: PresentedOperation] = [:]
  var activeOperationDeviceIDs: Set<SimulatorID> = []

  @ObservationIgnored private var overviewTask: Task<Void, Never>?
  @ObservationIgnored private var simulatorCreationOptionsTask: Task<Void, Never>?
  @ObservationIgnored private var simulatorCreationTask: Task<Void, Never>?
  @ObservationIgnored private var preferredDeviceIDAfterRefresh: SimulatorID?
  @ObservationIgnored private var overviewRequestGeneration: UInt64 = 0
  @ObservationIgnored private var inspectionTask: Task<Void, Never>?
  @ObservationIgnored private var customServiceSnapshotTask: Task<Void, Never>?
  @ObservationIgnored private var inspectionRequestGeneration: UInt64 = 0
  @ObservationIgnored private var inspectingDeviceID: SimulatorID?
  @ObservationIgnored private var applicationListTask: Task<Void, Never>?
  @ObservationIgnored private var applicationListRequestGeneration: UInt64 = 0
  @ObservationIgnored private var applicationFolderTask: Task<Void, Never>?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
  @ObservationIgnored private var batchPreviewTask: Task<Void, Never>?
  @ObservationIgnored private var batchTask: Task<Void, Never>?
  @ObservationIgnored private var operationTasks: [SimulatorID: Task<Void, Never>] = [:]
  @ObservationIgnored private var showSimulatorTasks: [SimulatorID: Task<Void, Never>] = [:]
  @ObservationIgnored private var optimizationDrafts: [SimulatorID: OptimizationDraft] = [:]
  @ObservationIgnored private var editingOptimizationDeviceID: SimulatorID?
  @ObservationIgnored private var batchPreviewReservedDeviceIDs: Set<SimulatorID> = []
  @ObservationIgnored private var didInitializeBatchSelection = false
  @ObservationIgnored private var didInitializeCustomSelection = false

  init(workspace: any SimulatorWorkspaceClient) {
    self.workspace = workspace
    selectedProfile = Self.storedDefaultProfile()
    let storedCustomSelection = Self.storedCustomSelection()
    customDisabledLabels = storedCustomSelection.labels
    didInitializeCustomSelection = storedCustomSelection.isInitialized
  }

  var selectedDeviceID: SimulatorID? {
    guard case .device(let id) = sidebarSelection else { return nil }
    return id
  }

  var selectedDevice: SimulatorDevice? {
    guard let selectedDeviceID else { return nil }
    return overview?.inventory.devices.first { $0.id == selectedDeviceID }
  }

  var runtimeGroups: [RuntimeDeviceGroup] {
    guard let overview else { return [] }
    return overview.inventory.runtimes.compactMap { runtime in
      let devices = overview.inventory.devices
        .filter { $0.runtimeIdentifier == runtime.id }
        .sorted { lhs, rhs in
          if lhs.state == .booted, rhs.state != .booted { return true }
          if lhs.state != .booted, rhs.state == .booted { return false }
          return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
      guard !devices.isEmpty else { return nil }
      return RuntimeDeviceGroup(runtime: runtime, devices: devices)
    }
  }

  var recentReceipts: [OperationReceipt] {
    overview?.recentReceipts.sorted { $0.startedAt > $1.startedAt } ?? []
  }

  var availableBatchDevices: [SimulatorDevice] {
    let verifiedRuntimeIDs = Set(
      (overview?.inventory.runtimes ?? [])
        .filter { $0.optimizationSupport == .supported }
        .map(\.id)
    )
    return (overview?.inventory.devices ?? [])
      .filter { $0.isAvailable && verifiedRuntimeIDs.contains($0.runtimeIdentifier) }
      .sorted { lhs, rhs in
        let runtimeOrder = lhs.runtimeName.localizedStandardCompare(rhs.runtimeName)
        if runtimeOrder != .orderedSame { return runtimeOrder == .orderedAscending }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  var selectedOperation: PresentedOperation? {
    guard let selectedDeviceID else { return nil }
    return operations[selectedDeviceID]
  }

  var hasRunningOperation: Bool {
    isCreatingSimulator
      || isPreparingBatchPreview
      || isExportingDiagnostics
      || batchRun?.isRunning == true
      || !activeOperationDeviceIDs.isEmpty
      || operations.values.contains(where: \.isRunning)
  }

  var latestRestorableReceipt: OperationReceipt? {
    guard let selectedDeviceID else { return nil }
    return recentReceipts.first {
      $0.deviceID == selectedDeviceID
        && $0.kind == .optimize
        && $0.schemaVersion == 1
        && $0.opaquePayload == nil
        && $0.baselineCapturedAt != nil
        && ($0.pendingChange != nil || $0.appliedChanges.contains(where: \.succeeded))
    }
  }

  var latestVerifiableReceipt: OperationReceipt? {
    guard let selectedDeviceID else { return nil }
    let pendingReceiptIDs = Set(overview?.pendingReceipts.map(\.id) ?? [])
    return recentReceipts.first {
      $0.deviceID == selectedDeviceID
        && $0.kind == .optimize
        && $0.schemaVersion == 1
        && $0.opaquePayload == nil
        && (pendingReceiptIDs.contains($0.id) || $0.pendingChange != nil)
    }
  }

  func load() {
    guard overview == nil, !isLoadingOverview else { return }
    refreshOverview()
  }

  func releaseMainWindowResourcesIfIdle() {
    guard !hasRunningOperation else { return }

    overviewRequestGeneration &+= 1
    inspectionRequestGeneration &+= 1
    applicationListRequestGeneration &+= 1
    overviewTask?.cancel()
    inspectionTask?.cancel()
    customServiceSnapshotTask?.cancel()
    applicationListTask?.cancel()
    applicationFolderTask?.cancel()
    simulatorCreationOptionsTask?.cancel()
    previewTask?.cancel()
    batchPreviewTask?.cancel()

    overviewTask = nil
    inspectionTask = nil
    customServiceSnapshotTask = nil
    applicationListTask = nil
    applicationFolderTask = nil
    simulatorCreationOptionsTask = nil
    previewTask = nil
    batchPreviewTask = nil

    overview = nil
    snapshot = nil
    customServiceSnapshot = nil
    applicationListState = .idle
    simulatorCreationOptions = nil
    previewPresentation = nil
    batchPreviewPresentation = nil
    workspaceModal = nil
    notice = nil
    toast = nil
    loadError = nil
    snapshotLoadError = nil
    simulatorCreationError = nil
    isLoadingOverview = false
    isLoadingSnapshot = false
    isLoadingCustomServiceSnapshot = false
    isLoadingSimulatorCreationOptions = false
    isPreparingBatchPreview = false
    openingApplicationBundleID = nil
  }

  func refreshOverview() {
    overviewRequestGeneration &+= 1
    let requestGeneration = overviewRequestGeneration
    overviewTask?.cancel()
    isLoadingOverview = true
    loadError = nil

    overviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await workspace.overview()
        guard
          !Task.isCancelled,
          requestGeneration == overviewRequestGeneration
        else { return }
        overview = result
        isLoadingOverview = false
        synchronizeBatchSelection(with: result.inventory.devices)
        if let preferredDeviceIDAfterRefresh,
          result.inventory.devices.contains(where: { $0.id == preferredDeviceIDAfterRefresh })
        {
          sidebarSelection = .device(preferredDeviceIDAfterRefresh)
          self.preferredDeviceIDAfterRefresh = nil
        }
        reconcileSelection(with: result.inventory.devices)
        if selectedDeviceID != nil {
          inspectSelectedDevice()
        }
        if selectedSection == .applications, let selectedDeviceID {
          loadApplications(for: selectedDeviceID, force: true)
        }
      } catch is CancellationError {
        guard requestGeneration == overviewRequestGeneration else { return }
        isLoadingOverview = false
      } catch {
        guard requestGeneration == overviewRequestGeneration else { return }
        isLoadingOverview = false
        if overview == nil {
          loadError = error.localizedDescription
        } else {
          notice = AppNotice(
            title: L10n.text("error.refresh.title"),
            message: error.localizedDescription
          )
        }
      }
    }
  }

  func selectionChanged() {
    saveOptimizationDraft()

    guard let selectedDeviceID else {
      editingOptimizationDeviceID = nil
      inspectionRequestGeneration &+= 1
      inspectionTask?.cancel()
      inspectingDeviceID = nil
      isLoadingSnapshot = false
      snapshotLoadError = nil
      snapshot = nil
      cancelApplicationLoading()
      customServiceSnapshotTask?.cancel()
      customServiceSnapshotTask = nil
      return
    }
    restoreOptimizationDraft(for: selectedDeviceID)
    if applicationListState.deviceID != selectedDeviceID {
      cancelApplicationLoading()
    }
    selectedStorageCategoryIDs.removeAll()
    inspectSelectedDevice()
  }

  private func saveOptimizationDraft() {
    guard let editingOptimizationDeviceID else { return }
    optimizationDrafts[editingOptimizationDeviceID] = OptimizationDraft(
      profile: selectedProfile
    )
  }

  private func restoreOptimizationDraft(for deviceID: SimulatorID) {
    let draft =
      optimizationDrafts[deviceID]
      ?? OptimizationDraft(
        profile: Self.storedDefaultProfile()
      )
    selectedProfile = draft.profile
    editingOptimizationDeviceID = deviceID
  }

  private static func storedDefaultProfile() -> OptimizationProfile {
    guard
      let rawValue = UserDefaults.standard.string(forKey: "defaultProfile"),
      let profile = OptimizationProfile(rawValue: rawValue)
    else {
      return .balanced
    }
    return profile
  }

  private static func storedCustomSelection() -> (
    labels: Set<String>,
    isInitialized: Bool
  ) {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: customDisabledLabelsDefaultsKey) != nil else {
      return ([], false)
    }
    return (
      Set(defaults.stringArray(forKey: customDisabledLabelsDefaultsKey) ?? []),
      true
    )
  }

  private func persistCustomSelection() {
    UserDefaults.standard.set(
      customDisabledLabels.sorted(),
      forKey: Self.customDisabledLabelsDefaultsKey
    )
    didInitializeCustomSelection = true
  }

  private func loadCustomServiceSnapshotForBatch() {
    guard customServiceSnapshot == nil, customServiceSnapshotTask == nil else { return }
    guard
      let device = availableBatchDevices.first(where: {
        batchSelectedDeviceIDs.contains($0.id)
      }) ?? availableBatchDevices.first
    else { return }

    isLoadingCustomServiceSnapshot = true
    customServiceSnapshotTask = Task { [weak self] in
      guard let self else { return }
      defer {
        customServiceSnapshotTask = nil
        isLoadingCustomServiceSnapshot = false
      }
      do {
        let result = try await workspace.inspect(device.id)
        guard !Task.isCancelled else { return }
        cacheCustomServiceSnapshot(result)
        initializeCustomSelectionIfNeeded(with: result)
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  private func cacheCustomServiceSnapshot(_ snapshot: DeviceSnapshot) {
    guard snapshot.services.contains(where: \.isOptimizationCandidate) else { return }
    customServiceSnapshot = snapshot
  }

  private func initializeCustomSelectionIfNeeded(with snapshot: DeviceSnapshot) {
    guard !didInitializeCustomSelection else { return }
    customDisabledLabels = Set(
      snapshot.services
        .filter(\.isOptimizationCandidate)
        .filter(\.isDisabled)
        .map(\.service.label)
    )
    persistCustomSelection()
  }

  func inspectSelectedDevice(force: Bool = false) {
    guard let id = selectedDeviceID else { return }
    if !force, isLoadingSnapshot, inspectingDeviceID == id {
      return
    }

    inspectionRequestGeneration &+= 1
    let requestGeneration = inspectionRequestGeneration
    inspectionTask?.cancel()
    inspectingDeviceID = id
    isLoadingSnapshot = true
    snapshotLoadError = nil

    inspectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await workspace.inspect(id)
        guard
          !Task.isCancelled,
          requestGeneration == inspectionRequestGeneration,
          selectedDeviceID == id
        else { return }
        snapshot = result
        cacheCustomServiceSnapshot(result)
        isLoadingSnapshot = false
        inspectingDeviceID = nil
        synchronizeSelections(with: result)
      } catch is CancellationError {
        guard
          requestGeneration == inspectionRequestGeneration,
          selectedDeviceID == id
        else { return }
        isLoadingSnapshot = false
        inspectingDeviceID = nil
      } catch {
        guard
          requestGeneration == inspectionRequestGeneration,
          selectedDeviceID == id
        else { return }
        isLoadingSnapshot = false
        inspectingDeviceID = nil
        snapshotLoadError = error.localizedDescription
        notice = AppNotice(
          title: L10n.text("error.inspect.title"),
          message: error.localizedDescription
        )
      }
    }
  }

  func loadApplications(for deviceID: SimulatorID, force: Bool = false) {
    guard
      selectedDeviceID == deviceID,
      selectedDevice?.state == .booted
    else {
      if applicationListState.deviceID == deviceID {
        cancelApplicationLoading()
      }
      return
    }

    if !force, applicationListState.deviceID == deviceID {
      switch applicationListState {
      case .loading, .loaded, .failed:
        return
      case .idle:
        break
      }
    }

    applicationListRequestGeneration &+= 1
    let requestGeneration = applicationListRequestGeneration
    applicationListTask?.cancel()
    applicationListState = .loading(deviceID: deviceID)

    applicationListTask = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await workspace.applications(for: deviceID)
        guard
          !Task.isCancelled,
          requestGeneration == applicationListRequestGeneration,
          selectedDeviceID == deviceID
        else { return }
        applicationListState = .loaded(
          deviceID: deviceID,
          snapshot: snapshot
        )
        applicationListTask = nil
      } catch is CancellationError {
        guard
          requestGeneration == applicationListRequestGeneration,
          selectedDeviceID == deviceID
        else { return }
        applicationListState = .idle
        applicationListTask = nil
      } catch {
        guard
          requestGeneration == applicationListRequestGeneration,
          selectedDeviceID == deviceID
        else { return }
        applicationListState = .failed(
          deviceID: deviceID,
          message: error.localizedDescription
        )
        applicationListTask = nil
      }
    }
  }

  func openApplicationDataContainer(
    _ application: SimulatorApplication,
    deviceID: SimulatorID
  ) {
    guard
      selectedDeviceID == deviceID,
      selectedDevice?.state == .booted,
      openingApplicationBundleID == nil
    else { return }

    applicationFolderTask?.cancel()
    openingApplicationBundleID = application.bundleIdentifier
    applicationFolderTask = Task { [weak self] in
      guard let self else { return }
      do {
        let folderURL = try await workspace.dataContainer(
          for: deviceID,
          bundleIdentifier: application.bundleIdentifier
        )
        guard
          !Task.isCancelled,
          selectedDeviceID == deviceID,
          openingApplicationBundleID == application.bundleIdentifier
        else { return }
        openingApplicationBundleID = nil
        applicationFolderTask = nil
        guard let folderURL else {
          notice = AppNotice(
            title: L10n.text("applications.folder-unavailable.title"),
            message: L10n.text("applications.folder-unavailable.message")
          )
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
      } catch is CancellationError {
        guard openingApplicationBundleID == application.bundleIdentifier else { return }
        openingApplicationBundleID = nil
        applicationFolderTask = nil
      } catch {
        guard
          selectedDeviceID == deviceID,
          openingApplicationBundleID == application.bundleIdentifier
        else { return }
        openingApplicationBundleID = nil
        applicationFolderTask = nil
        notice = AppNotice(
          title: L10n.text("applications.folder-unavailable.title"),
          message: error.localizedDescription
        )
      }
    }
  }

  private func cancelApplicationLoading() {
    applicationListRequestGeneration &+= 1
    applicationListTask?.cancel()
    applicationListTask = nil
    applicationFolderTask?.cancel()
    applicationFolderTask = nil
    openingApplicationBundleID = nil
    applicationListState = .idle
  }

  func selectDevice(_ deviceID: SimulatorID) {
    sidebarSelection = .device(deviceID)
  }

  func showBatchOptimization() {
    presentWorkspaceModal(.batchOptimization)
  }

  func showSettings() {
    presentWorkspaceModal(.settings)
  }

  func showCreateSimulator() {
    presentWorkspaceModal(.createSimulator)
  }

  func presentWorkspaceModal(_ modal: WorkspaceModal) {
    WindowFocus.endTextEditing()
    workspaceModal = modal
    switch modal {
    case .batchOptimization:
      loadCustomServiceSnapshotForBatch()
    case .createSimulator:
      loadSimulatorCreationOptions()
    case .settings:
      break
    }
  }

  func dismissWorkspaceModal() {
    guard !isCreatingSimulator else { return }
    WindowFocus.endTextEditing()
    workspaceModal = nil
  }

  func loadSimulatorCreationOptions(force: Bool = false) {
    guard !isLoadingSimulatorCreationOptions else { return }
    if simulatorCreationOptions != nil, !force { return }

    simulatorCreationOptionsTask?.cancel()
    isLoadingSimulatorCreationOptions = true
    simulatorCreationError = nil
    simulatorCreationOptionsTask = Task { [weak self] in
      guard let self else { return }
      do {
        let options = try await workspace.simulatorCreationOptions()
        guard !Task.isCancelled else { return }
        simulatorCreationOptions = options
        isLoadingSimulatorCreationOptions = false
        simulatorCreationOptionsTask = nil
      } catch is CancellationError {
        isLoadingSimulatorCreationOptions = false
        simulatorCreationOptionsTask = nil
      } catch {
        guard !Task.isCancelled else { return }
        simulatorCreationError = error.localizedDescription
        isLoadingSimulatorCreationOptions = false
        simulatorCreationOptionsTask = nil
      }
    }
  }

  func createSimulator(
    name: String,
    runtimeID: String,
    deviceTypeID: String
  ) {
    guard !isCreatingSimulator else { return }
    isCreatingSimulator = true
    simulatorCreationError = nil
    simulatorCreationTask?.cancel()
    simulatorCreationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let deviceID = try await workspace.createSimulator(
          SimulatorCreationRequest(
            name: name,
            deviceTypeID: deviceTypeID,
            runtimeID: runtimeID
          )
        )
        guard !Task.isCancelled else { return }
        preferredDeviceIDAfterRefresh = deviceID
        isCreatingSimulator = false
        simulatorCreationTask = nil
        workspaceModal = nil
        toast = AppToast(message: L10n.formatted("create-simulator.success", name))
        refreshOverview()
      } catch is CancellationError {
        isCreatingSimulator = false
        simulatorCreationTask = nil
      } catch {
        guard !Task.isCancelled else { return }
        simulatorCreationError = error.localizedDescription
        isCreatingSimulator = false
        simulatorCreationTask = nil
      }
    }
  }

  func toggleBatchDevice(_ deviceID: SimulatorID, selected: Bool) {
    guard
      batchRun?.isRunning != true,
      !isPreparingBatchPreview,
      batchPreviewPresentation == nil
    else { return }
    if selected {
      guard availableBatchDevices.contains(where: { $0.id == deviceID }) else { return }
      batchSelectedDeviceIDs.insert(deviceID)
    } else {
      batchSelectedDeviceIDs.remove(deviceID)
    }
  }

  func selectAllBatchDevices() {
    guard
      batchRun?.isRunning != true,
      !isPreparingBatchPreview,
      batchPreviewPresentation == nil
    else { return }
    batchSelectedDeviceIDs = Set(availableBatchDevices.map(\.id))
  }

  func clearBatchDevices() {
    guard
      batchRun?.isRunning != true,
      !isPreparingBatchPreview,
      batchPreviewPresentation == nil
    else { return }
    batchSelectedDeviceIDs.removeAll()
  }

  func startBatchOptimization() {
    guard
      batchRun?.isRunning != true,
      batchTask == nil,
      batchPreviewTask == nil,
      batchPreviewPresentation == nil,
      !isPreparingBatchPreview
    else { return }
    let devices = availableBatchDevices.filter { batchSelectedDeviceIDs.contains($0.id) }
    guard !devices.isEmpty else { return }

    let profile = batchProfile
    let customLabels = profile == .custom ? customDisabledLabels : []
    isPreparingBatchPreview = true
    batchPreviewCompletedCount = 0
    batchPreviewTotalCount = devices.count
    batchPreviewReservedDeviceIDs = Set(devices.map(\.id))
    batchPreviewTask = Task { [weak self] in
      await self?.prepareBatchPreview(
        devices: devices,
        profile: profile,
        customDisabledLabels: customLabels
      )
    }
  }

  func cancelBatchPreviewPreparation() {
    batchPreviewTask?.cancel()
    batchPreviewTask = nil
    batchPreviewReservedDeviceIDs.removeAll()
    isPreparingBatchPreview = false
    batchPreviewCompletedCount = 0
    batchPreviewTotalCount = 0
  }

  func dismissBatchPreview() {
    batchPreviewPresentation = nil
  }

  func confirmBatchPreview() {
    guard
      batchRun?.isRunning != true,
      batchTask == nil,
      let presentation = batchPreviewPresentation,
      presentation.executableCount > 0
    else { return }

    let items = presentation.items.map { item in
      var queueItem = BatchQueueItem(
        device: item.device,
        initialPreview: item.preview
      )
      if let failureMessage = item.failureMessage {
        queueItem.status = .skipped
        queueItem.detail = L10n.formatted("batch.preview.failure.detail", failureMessage)
      } else if let preview = item.preview {
        queueItem.detail = L10n.formatted(
          "batch.preview.changes",
          preview.serviceChanges.count
        )
      } else {
        queueItem.status = .skipped
        queueItem.detail = L10n.text("batch.preview.failure.unknown")
      }
      return queueItem
    }
    let run = BatchOptimizationRun(profile: presentation.profile, items: items)
    batchPreviewPresentation = nil
    batchRun = run

    let runID = run.id
    batchTask = Task { [weak self] in
      await self?.executeBatchOptimization(runID: runID)
    }
  }

  func cancelBatchOptimization() {
    guard var run = batchRun, run.isRunning else { return }
    run.cancellationRequested = true
    if let deviceID = run.currentItem?.id, var presentation = operations[deviceID] {
      presentation.stopRequested = true
      operations[deviceID] = presentation
    }
    batchRun = run
    batchTask?.cancel()
  }

  func resetBatchOptimization() {
    guard batchRun?.isRunning != true, !isPreparingBatchPreview else { return }
    batchRun = nil
    batchPreviewPresentation = nil
  }

  func isDeviceBusy(_ deviceID: SimulatorID) -> Bool {
    if operations[deviceID]?.isRunning == true || activeOperationDeviceIDs.contains(deviceID) {
      return true
    }
    return isDeviceReservedByBatch(deviceID)
  }

  func optimizationSupport(for deviceID: SimulatorID) -> OptimizationSupportStatus {
    guard
      let inventory = overview?.inventory,
      let device = inventory.devices.first(where: { $0.id == deviceID })
    else { return .unsupportedRuntime }
    guard device.isAvailable else { return .unavailableRuntime }
    return inventory.runtimes
      .first(where: { $0.id == device.runtimeIdentifier })?
      .optimizationSupport ?? .unsupportedRuntime
  }

  func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  func copyUDID(_ udid: String) {
    copy(udid)
    toast = AppToast(message: L10n.text("toast.udid-copied"))
  }

  func openXcode() {
    let workspace = NSWorkspace.shared
    let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
    guard let url, workspace.open(url) else {
      notice = AppNotice(
        title: L10n.text("error.open-xcode.title"),
        message: L10n.text("error.open-xcode.message")
      )
      return
    }
  }

  func exportDiagnostics() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    let panel = NSSavePanel()
    panel.title = L10n.text("diagnostics.export.title")
    panel.nameFieldStringValue =
      "SimulatorSlimmer-Diagnostics-\(formatter.string(from: Date())).zip"
    panel.allowedContentTypes = [.zip]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

    diagnosticsTask?.cancel()
    isExportingDiagnostics = true
    diagnosticsTask = Task { [weak self] in
      guard let self else { return }
      do {
        let exportedURL = try await workspace.exportDiagnostics(to: destinationURL)
        guard !Task.isCancelled else { return }
        isExportingDiagnostics = false
        notice = AppNotice(
          title: L10n.text("diagnostics.export.succeeded.title"),
          message: L10n.formatted(
            "diagnostics.export.succeeded.message",
            exportedURL.lastPathComponent
          )
        )
      } catch is CancellationError {
        isExportingDiagnostics = false
      } catch {
        isExportingDiagnostics = false
        notice = AppNotice(
          title: L10n.text("diagnostics.export.failed.title"),
          message: error.localizedDescription
        )
      }
    }
  }

  func optimizationOperation() -> SimulatorOperation? {
    guard
      let deviceID = selectedDeviceID,
      snapshot?.device.id == deviceID,
      snapshot?.optimizationSupport == .supported
    else { return nil }
    return .optimize(
      deviceID: deviceID,
      profile: selectedProfile,
      customDisabledLabels: selectedProfile == .custom ? customDisabledLabels : []
    )
  }

  func requestOptimizationPreview(confirmsExecution: Bool = false) {
    guard let operation = optimizationOperation() else { return }
    preparePreview(operation, confirmsExecution: confirmsExecution)
  }

  func runOptimization() {
    requestOptimizationPreview(confirmsExecution: true)
  }

  func restoreLatest() {
    guard let deviceID = selectedDeviceID, let receipt = latestRestorableReceipt else { return }
    preparePreview(
      .restore(deviceID: deviceID, receiptID: receipt.id),
      confirmsExecution: true
    )
  }

  func continueLatestVerification() {
    guard let deviceID = selectedDeviceID, let receipt = latestVerifiableReceipt else {
      return
    }
    preparePreview(
      .verify(deviceID: deviceID, receiptID: receipt.id),
      confirmsExecution: true
    )
  }

  func scanStorage() {
    guard
      let deviceID = selectedDeviceID,
      snapshot?.device.id == deviceID,
      snapshot?.optimizationSupport == .supported,
      snapshot?.device.isAvailable == true,
      snapshot?.device.state == .shutdown
    else { return }
    perform(.scanStorage(deviceID: deviceID))
  }

  func requestStorageCleanup() {
    guard
      let deviceID = selectedDeviceID,
      let plan = snapshot?.latestStoragePlan,
      snapshot?.optimizationSupport == .supported,
      snapshot?.device.isAvailable == true,
      snapshot?.device.state == .shutdown,
      !selectedStorageCategoryIDs.isEmpty
    else { return }

    preparePreview(
      .cleanStorage(
        deviceID: deviceID,
        planID: plan.id,
        categoryIDs: selectedStorageCategoryIDs,
        preserveBootState: true
      ),
      confirmsExecution: true
    )
  }

  func runDeviceOperation(_ kind: OperationKind) {
    guard
      let deviceID = selectedDeviceID,
      selectedDevice?.isAvailable == true,
      !isDeviceBusy(deviceID)
    else { return }
    let operation: SimulatorOperation
    switch kind {
    case .boot: operation = .boot(deviceID: deviceID)
    case .shutdown: operation = .shutdown(deviceID: deviceID)
    case .preflight, .optimize, .verify, .restore, .scanStorage, .cleanStorage,
      .erase, .delete, .clone, .openSimulator:
      return
    }
    perform(operation)
  }

  func showSelectedSimulator() {
    guard
      let deviceID = selectedDeviceID,
      selectedDevice?.state == .booted,
      selectedDevice?.isAvailable == true,
      !isDeviceBusy(deviceID),
      showSimulatorTasks[deviceID] == nil
    else { return }

    activeOperationDeviceIDs.insert(deviceID)
    showSimulatorTasks[deviceID] = Task { [weak self] in
      guard let self else { return }
      do {
        try await workspace.showSimulator(deviceID)
        guard !Task.isCancelled else {
          activeOperationDeviceIDs.remove(deviceID)
          showSimulatorTasks[deviceID] = nil
          return
        }
        toast = AppToast(message: L10n.text("toast.device-opened"))
      } catch is CancellationError {
        // 显示窗口属于瞬时操作，取消时无需额外提示。
      } catch {
        notice = AppNotice(
          title: L10n.text("device.action-failed.title"),
          message: error.localizedDescription
        )
      }
      activeOperationDeviceIDs.remove(deviceID)
      showSimulatorTasks[deviceID] = nil
    }
  }

  func requestDanger(_ kind: DangerPresentation.Kind) {
    guard let selectedDevice, selectedDevice.isAvailable,
      optimizationSupport(for: selectedDevice.id) == .supported,
      !isDeviceBusy(selectedDevice.id)
    else { return }
    dangerPresentation = DangerPresentation(kind: kind, device: selectedDevice)
  }

  func confirmDanger(_ presentation: DangerPresentation, cloneName: String?) {
    let deviceID = presentation.device.id
    let operation: SimulatorOperation
    switch presentation.kind {
    case .erase:
      operation = .erase(deviceID: deviceID)
    case .delete:
      operation = .delete(deviceID: deviceID)
    case .clone:
      let name = cloneName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty else { return }
      operation = .clone(deviceID: deviceID, name: name)
    }
    dangerPresentation = nil
    preparePreview(operation, confirmsExecution: true)
  }

  func runPreviewedOperation() {
    guard let operation = previewPresentation?.preview.operation else { return }
    previewPresentation = nil
    perform(operation)
  }

  func toggleCustomService(_ label: String, disabled: Bool) {
    if disabled {
      customDisabledLabels.insert(label)
    } else {
      customDisabledLabels.remove(label)
    }
    persistCustomSelection()
  }

  func setCustomServices(_ labels: Set<String>, disabled: Bool) {
    guard !labels.isEmpty else { return }
    if disabled {
      customDisabledLabels.formUnion(labels)
    } else {
      customDisabledLabels.subtract(labels)
    }
    persistCustomSelection()
  }

  func toggleStorageCategory(_ id: String, selected: Bool) {
    if selected {
      selectedStorageCategoryIDs.insert(id)
    } else {
      selectedStorageCategoryIDs.remove(id)
    }
  }

  func requestStop() {
    guard let deviceID = selectedDeviceID, var presentation = operations[deviceID] else {
      return
    }
    presentation.stopRequested = true
    operations[deviceID] = presentation
    if batchRun?.currentItem?.id == deviceID {
      cancelBatchOptimization()
      return
    }
    operationTasks[deviceID]?.cancel()
  }

  private func prepareBatchPreview(
    devices: [SimulatorDevice],
    profile: OptimizationProfile,
    customDisabledLabels: Set<String>
  ) async {
    var items: [BatchPreviewItem] = []
    items.reserveCapacity(devices.count)

    for device in devices {
      if Task.isCancelled {
        batchPreviewReservedDeviceIDs.removeAll()
        isPreparingBatchPreview = false
        batchPreviewTask = nil
        return
      }

      let operation = SimulatorOperation.optimize(
        deviceID: device.id,
        profile: profile,
        customDisabledLabels: customDisabledLabels
      )
      if operations[device.id]?.isRunning == true || operationTasks[device.id] != nil {
        items.append(
          BatchPreviewItem(
            device: device,
            operation: operation,
            preview: nil,
            failureMessage: L10n.text("batch.preview.failure.busy")
          )
        )
      } else {
        do {
          let preview = try await workspace.preview(operation)
          try Task.checkCancellation()
          items.append(
            BatchPreviewItem(
              device: device,
              operation: operation,
              preview: preview,
              failureMessage: nil
            )
          )
        } catch is CancellationError {
          batchPreviewReservedDeviceIDs.removeAll()
          isPreparingBatchPreview = false
          batchPreviewTask = nil
          return
        } catch {
          items.append(
            BatchPreviewItem(
              device: device,
              operation: operation,
              preview: nil,
              failureMessage: error.localizedDescription
            )
          )
        }
      }
      batchPreviewCompletedCount = items.count
    }

    guard !Task.isCancelled else {
      batchPreviewReservedDeviceIDs.removeAll()
      isPreparingBatchPreview = false
      batchPreviewTask = nil
      return
    }
    isPreparingBatchPreview = false
    batchPreviewCompletedCount = devices.count
    batchPreviewPresentation = BatchPreviewPresentation(profile: profile, items: items)
    batchPreviewReservedDeviceIDs.removeAll()
    batchPreviewTask = nil
  }

  private func executeBatchOptimization(runID: UUID) async {
    guard let run = batchRun, run.id == runID else { return }
    let devices = run.items.map(\.device)

    for device in devices {
      guard let activeRun = batchRun, activeRun.id == runID else { break }
      if Task.isCancelled || activeRun.cancellationRequested {
        cancelUnfinishedBatchItems(runID: runID)
        break
      }
      guard
        activeRun.items.first(where: { $0.id == device.id })?.status == .pending
      else { continue }

      guard availableBatchDevices.contains(where: { $0.id == device.id }) else {
        updateBatchItem(runID: runID, deviceID: device.id) { item in
          item.status = .skipped
          item.detail = L10n.text("batch.skip.unavailable")
        }
        continue
      }

      if operations[device.id]?.isRunning == true || operationTasks[device.id] != nil {
        updateBatchItem(runID: runID, deviceID: device.id) { item in
          item.status = .skipped
          item.detail = L10n.text("batch.skip.existing-operation")
        }
        continue
      }

      guard
        let initialPreview = activeRun.items.first(where: { $0.id == device.id })?.initialPreview
      else {
        updateBatchItem(runID: runID, deviceID: device.id) { item in
          item.status = .skipped
          item.detail = L10n.text("batch.preview.failure.unknown")
        }
        continue
      }
      let operation = initialPreview.operation
      operations[device.id] = PresentedOperation(operation: operation)
      updateBatchItem(runID: runID, deviceID: device.id) { item in
        item.status = .running
        item.detail = L10n.formatted(
          "batch.preview.changes",
          initialPreview.serviceChanges.count
        )
      }

      var shouldStop = false
      do {
        let stream = await workspace.perform(operation)
        for try await event in stream {
          try Task.checkCancellation()
          receive(event)
          updateBatchItem(runID: runID, deviceID: device.id) { item in
            item.detail = event.message
          }
        }
        try Task.checkCancellation()
        completeBatchItem(runID: runID, deviceID: device.id)
      } catch is CancellationError {
        markCancelled(device.id)
        let receipt = operations[device.id]?.receipt
        updateBatchItem(runID: runID, deviceID: device.id) { item in
          item.receipt = receipt
        }
        cancelUnfinishedBatchItems(runID: runID)
        shouldStop = true
      } catch {
        markFailed(device.id, message: error.localizedDescription)
        let receipt = operations[device.id]?.receipt
        updateBatchItem(runID: runID, deviceID: device.id) { item in
          item.status = .failed
          item.detail = error.localizedDescription
          item.receipt = receipt
        }
        if error.localizedDescription.contains("重新预览") {
          notice = AppNotice(
            title: L10n.text("batch.preview.stale.title"),
            message: L10n.text("batch.preview.stale.message")
          )
        }
      }

      if shouldStop { break }
      await refreshAfterOperation(device.id)
    }

    guard var finishedRun = batchRun, finishedRun.id == runID else {
      batchTask = nil
      return
    }
    if finishedRun.items.contains(where: { !$0.status.isTerminal }) {
      for index in finishedRun.items.indices
      where !finishedRun.items[index].status.isTerminal {
        finishedRun.items[index].status = .cancelled
        finishedRun.items[index].detail = L10n.text("batch.cancelled.detail")
      }
    }
    finishedRun.finishedAt = Date()
    batchRun = finishedRun
    batchTask = nil
    refreshOverview()
  }

  private func completeBatchItem(runID: UUID, deviceID: SimulatorID) {
    let presentation = operations[deviceID]
    guard let receipt = presentation?.receipt else {
      updateBatchItem(runID: runID, deviceID: deviceID) { item in
        item.status = .failed
        item.detail =
          presentation?.failureMessage ?? L10n.text("batch.failure.no-receipt")
      }
      return
    }

    updateBatchItem(runID: runID, deviceID: deviceID) { item in
      item.receipt = receipt
      switch receipt.status {
      case .succeeded:
        item.status = .succeeded
        item.detail = L10n.text("batch.success.verified")
      case .partial:
        item.status = .failed
        item.detail = L10n.text("batch.failure.partial")
      case .failed:
        item.status = .failed
        item.detail = receipt.messages.last ?? L10n.text("batch.failure.failed")
      case .cancelled:
        item.status = .cancelled
        item.detail = L10n.text("batch.cancelled.detail")
      case .prepared, .running:
        item.status = .failed
        item.detail = L10n.text("batch.failure.incomplete")
      }
    }
  }

  private func cancelUnfinishedBatchItems(runID: UUID) {
    guard var run = batchRun, run.id == runID else { return }
    run.cancellationRequested = true
    for index in run.items.indices
    where !run.items[index].status.isTerminal {
      run.items[index].status = .cancelled
      run.items[index].detail = L10n.text("batch.cancelled.detail")
    }
    batchRun = run
  }

  private func updateBatchItem(
    runID: UUID,
    deviceID: SimulatorID,
    update: (inout BatchQueueItem) -> Void
  ) {
    guard
      var run = batchRun,
      run.id == runID,
      let index = run.items.firstIndex(where: { $0.id == deviceID })
    else { return }
    update(&run.items[index])
    batchRun = run
  }

  private func preparePreview(
    _ operation: SimulatorOperation,
    confirmsExecution: Bool
  ) {
    guard !isDeviceReservedByBatch(operation.deviceID) else {
      notice = AppNotice(
        title: L10n.text("batch.reservation.title"),
        message: L10n.text("batch.reservation.message")
      )
      return
    }
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let preview = try await workspace.preview(operation)
        guard !Task.isCancelled else { return }
        previewPresentation = PreviewPresentation(
          preview: preview,
          confirmsExecution: confirmsExecution
        )
      } catch is CancellationError {
        return
      } catch {
        notice = AppNotice(
          title: L10n.text("error.preview.title"),
          message: error.localizedDescription
        )
      }
    }
  }

  private func perform(_ operation: SimulatorOperation) {
    let deviceID = operation.deviceID
    guard
      !isDeviceReservedByBatch(deviceID),
      operationTasks[deviceID] == nil,
      operations[deviceID]?.isRunning != true
    else {
      return
    }

    operations[deviceID] = PresentedOperation(operation: operation)
    activeOperationDeviceIDs.insert(deviceID)
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let stream = await workspace.perform(operation)
        for try await event in stream {
          receive(event)
        }
      } catch is CancellationError {
        markCancelled(deviceID)
      } catch {
        markFailed(deviceID, message: error.localizedDescription)
      }

      await refreshAfterOperation(deviceID)
      operationTasks[deviceID] = nil
      activeOperationDeviceIDs.remove(deviceID)

      if let receipt = operations[deviceID]?.receipt,
        receipt.status == .succeeded,
        let message = deviceSuccessToastMessage(for: receipt.kind)
      {
        toast = AppToast(message: message)
      }
    }
    operationTasks[deviceID] = task
  }

  private func receive(_ event: OperationEvent) {
    var presentation =
      operations[event.deviceID]
      ?? PresentedOperation(operation: .scanStorage(deviceID: event.deviceID))
    presentation.events.append(event)
    if let receipt = event.receipt {
      presentation.receipt = receipt
    }
    if event.isTerminal && event.state == .failed {
      presentation.failureMessage = event.message
    }
    operations[event.deviceID] = presentation
  }

  private func deviceSuccessToastMessage(for kind: OperationKind) -> String? {
    switch kind {
    case .boot:
      L10n.text("toast.device-booted")
    case .shutdown:
      L10n.text("toast.device-shutdown")
    case .openSimulator:
      L10n.text("toast.device-opened")
    case .delete:
      L10n.text("toast.device-deleted")
    case .preflight, .optimize, .verify, .restore, .scanStorage, .cleanStorage,
      .erase, .clone:
      nil
    }
  }

  private func markCancelled(_ deviceID: SimulatorID) {
    guard var presentation = operations[deviceID], presentation.receipt == nil else { return }
    presentation.failureMessage = L10n.text("operation.cancelled.message")
    operations[deviceID] = presentation
  }

  private func markFailed(_ deviceID: SimulatorID, message: String) {
    guard var presentation = operations[deviceID] else { return }
    presentation.failureMessage = message
    operations[deviceID] = presentation
    switch presentation.operation.kind {
    case .boot, .shutdown, .openSimulator:
      notice = AppNotice(
        title: L10n.text("device.action-failed.title"),
        message: message
      )
    case .preflight, .optimize, .verify, .restore, .scanStorage, .cleanStorage,
      .erase, .delete, .clone:
      break
    }
  }

  private func refreshAfterOperation(_ deviceID: SimulatorID) async {
    overviewRequestGeneration &+= 1
    let requestGeneration = overviewRequestGeneration
    overviewTask?.cancel()
    isLoadingOverview = true

    do {
      let result = try await workspace.overview()
      guard requestGeneration == overviewRequestGeneration else { return }
      overview = result
      isLoadingOverview = false
      synchronizeBatchSelection(with: result.inventory.devices)
      if selectedDeviceID == deviceID,
        result.inventory.devices.contains(where: { $0.id == deviceID })
      {
        inspectSelectedDevice(force: true)
        let currentInspection = inspectionTask
        await currentInspection?.value
      } else if selectedDeviceID == deviceID {
        snapshot = nil
        reconcileSelection(with: result.inventory.devices)
        if selectedDeviceID != nil {
          inspectSelectedDevice(force: true)
        }
      }
    } catch {
      guard requestGeneration == overviewRequestGeneration else { return }
      isLoadingOverview = false
      notice = AppNotice(
        title: L10n.text("error.verify-refresh.title"),
        message: error.localizedDescription
      )
    }
  }

  private func reconcileSelection(with devices: [SimulatorDevice]) {
    if let selectedDeviceID,
      devices.contains(where: { $0.id == selectedDeviceID && $0.isAvailable })
    {
      return
    }

    let persisted = UserDefaults.standard.string(forKey: "selectedDeviceID")
      .map(SimulatorID.init(rawValue:))
    let candidate =
      persisted.flatMap { id in devices.first { $0.id == id && $0.isAvailable } }
      ?? devices.first { $0.state == .booted && $0.isAvailable }
      ?? devices.first { $0.isAvailable }

    if let candidate {
      sidebarSelection = .device(candidate.id)
      UserDefaults.standard.set(candidate.id.rawValue, forKey: "selectedDeviceID")
    } else {
      sidebarSelection = nil
      snapshot = nil
    }
  }

  private func isDeviceReservedByBatch(_ deviceID: SimulatorID) -> Bool {
    if batchPreviewReservedDeviceIDs.contains(deviceID) {
      return true
    }
    if batchPreviewPresentation?.items.contains(where: { $0.id == deviceID }) == true {
      return true
    }
    return batchRun?.isRunning == true
      && batchRun?.items.contains(where: {
        $0.id == deviceID && ($0.status == .pending || $0.status == .running)
      }) == true
  }

  private func synchronizeBatchSelection(with devices: [SimulatorDevice]) {
    let deviceIDs = Set(devices.map(\.id))
    let availableIDs = Set(
      availableBatchDevices.map(\.id).filter { deviceIDs.contains($0) }
    )
    if !didInitializeBatchSelection, !availableIDs.isEmpty {
      batchSelectedDeviceIDs = availableIDs
      didInitializeBatchSelection = true
    } else if didInitializeBatchSelection {
      batchSelectedDeviceIDs.formIntersection(availableIDs)
    }
  }

  private func synchronizeSelections(with snapshot: DeviceSnapshot) {
    initializeCustomSelectionIfNeeded(with: snapshot)

    if let plan = snapshot.latestStoragePlan {
      let valid = Set(plan.categories.filter(\.canClean).map(\.id))
      if selectedStorageCategoryIDs.isEmpty {
        selectedStorageCategoryIDs = Set(
          plan.categories
            .filter { $0.canClean && $0.isDefaultSelected }
            .map(\.id)
        )
      } else {
        selectedStorageCategoryIDs.formIntersection(valid)
      }
    } else {
      selectedStorageCategoryIDs.removeAll()
    }
  }
}

struct MenuBarApplicationItem: Identifiable {
  let application: SimulatorApplication
  let memory: ApplicationMemorySnapshot?
  let icon: NSImage?

  var id: String { application.bundleIdentifier }
}

struct MenuBarDeviceItem: Identifiable {
  let snapshot: MenuBarDeviceSnapshot
  let applications: [MenuBarApplicationItem]
  let applicationError: String?

  var id: SimulatorID { snapshot.device.id }
}

@MainActor
@Observable
final class MenuBarModel {
  private let workspace: any SimulatorWorkspaceClient

  var devices: [MenuBarDeviceItem] = []
  var isRefreshing = false
  var refreshError: String?

  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var folderTask: Task<Void, Never>?

  init(workspace: any SimulatorWorkspaceClient) {
    self.workspace = workspace
  }

  func refresh() {
    refreshTask?.cancel()
    isRefreshing = true
    refreshError = nil

    refreshTask = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await workspace.menuBarSnapshot()
        var resolvedDevices: [MenuBarDeviceItem] = []
        resolvedDevices.reserveCapacity(snapshot.devices.count)

        for deviceSnapshot in snapshot.devices {
          try Task.checkCancellation()
          do {
            let applicationSnapshot = try await workspace.applications(
              for: deviceSnapshot.device.id
            )
            let applications = applicationSnapshot.applications
              .filter { $0.kind == .user }
              .map { application in
                MenuBarApplicationItem(
                  application: application,
                  memory: applicationSnapshot.memoryByBundleIdentifier[
                    application.bundleIdentifier
                  ],
                  icon: Self.applicationIcon(for: application)
                )
              }
            resolvedDevices.append(
              MenuBarDeviceItem(
                snapshot: deviceSnapshot,
                applications: applications,
                applicationError: applicationSnapshot.memoryError
              )
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            resolvedDevices.append(
              MenuBarDeviceItem(
                snapshot: deviceSnapshot,
                applications: [],
                applicationError: error.localizedDescription
              )
            )
          }
        }

        guard !Task.isCancelled else { return }
        devices = resolvedDevices
        isRefreshing = false
        refreshTask = nil
      } catch is CancellationError {
        guard !Task.isCancelled else { return }
        isRefreshing = false
        refreshTask = nil
      } catch {
        guard !Task.isCancelled else { return }
        devices = []
        refreshError = error.localizedDescription
        isRefreshing = false
        refreshTask = nil
      }
    }
  }

  func cancelRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
    isRefreshing = false
    devices = []
    refreshError = nil
  }

  func openDataContainer(
    for application: SimulatorApplication,
    deviceID: SimulatorID
  ) {
    folderTask?.cancel()
    folderTask = Task { [weak self] in
      guard let self else { return }
      do {
        let folderURL = try await workspace.dataContainer(
          for: deviceID,
          bundleIdentifier: application.bundleIdentifier
        )
        guard !Task.isCancelled else { return }
        guard let folderURL else {
          NSSound.beep()
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
      } catch is CancellationError {
        return
      } catch {
        NSSound.beep()
      }
    }
  }

  private static func applicationIcon(for application: SimulatorApplication) -> NSImage? {
    guard let bundleURL = application.bundleURL else { return nil }
    let source = NSWorkspace.shared.icon(forFile: bundleURL.path)
    guard source.isValid, let icon = source.copy() as? NSImage else { return nil }
    icon.size = NSSize(width: 18, height: 18)
    return icon
  }
}
