import AppKit
import Foundation
import Observation
import SimulatorSlimmerCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
  private let workspace: any SimulatorWorkspaceClient

  var overview: WorkspaceOverview?
  var sidebarSelection: SidebarSelection?
  var selectedSection: DeviceSection = .optimization
  var searchText = ""
  var snapshot: DeviceSnapshot?
  var selectedProfile: OptimizationProfile = .balanced
  var customDisabledLabels: Set<String> = []
  var selectedStorageCategoryIDs: Set<String> = []
  var batchSelectedDeviceIDs: Set<SimulatorID> = []
  var batchProfile: OptimizationProfile = .balanced
  var batchRun: BatchOptimizationRun?
  var batchPreviewPresentation: BatchPreviewPresentation?
  var isPreparingBatchPreview = false
  var batchPreviewCompletedCount = 0
  var batchPreviewTotalCount = 0
  var isLoadingOverview = false
  var isLoadingSnapshot = false
  var isExportingDiagnostics = false
  var loadError: String?
  var notice: AppNotice?
  var previewPresentation: PreviewPresentation?
  var dangerPresentation: DangerPresentation?
  var receiptPresentation: OperationReceipt?
  var operations: [SimulatorID: PresentedOperation] = [:]

  @ObservationIgnored private var overviewTask: Task<Void, Never>?
  @ObservationIgnored private var inspectionTask: Task<Void, Never>?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
  @ObservationIgnored private var batchPreviewTask: Task<Void, Never>?
  @ObservationIgnored private var batchTask: Task<Void, Never>?
  @ObservationIgnored private var operationTasks: [SimulatorID: Task<Void, Never>] = [:]
  @ObservationIgnored private var batchPreviewReservedDeviceIDs: Set<SimulatorID> = []
  @ObservationIgnored private var didInitializeBatchSelection = false

  init(workspace: any SimulatorWorkspaceClient) {
    self.workspace = workspace
    if let storedProfile = UserDefaults.standard.string(forKey: "defaultProfile"),
      let profile = OptimizationProfile(rawValue: storedProfile)
    {
      selectedProfile = profile
    }
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
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return overview.inventory.runtimes.compactMap { runtime in
      let devices = overview.inventory.devices
        .filter { $0.runtimeIdentifier == runtime.id }
        .filter {
          query.isEmpty
            || $0.name.localizedCaseInsensitiveContains(query)
            || $0.id.rawValue.localizedCaseInsensitiveContains(query)
            || runtime.name.localizedCaseInsensitiveContains(query)
        }
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
    isPreparingBatchPreview
      || batchRun?.isRunning == true
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

  func refreshOverview() {
    overviewTask?.cancel()
    isLoadingOverview = true
    loadError = nil

    overviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await workspace.overview()
        guard !Task.isCancelled else { return }
        overview = result
        isLoadingOverview = false
        synchronizeBatchSelection(with: result.inventory.devices)
        reconcileSelection(with: result.inventory.devices)
        if selectedDeviceID != nil {
          inspectSelectedDevice()
        }
      } catch is CancellationError {
        isLoadingOverview = false
      } catch {
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
    guard selectedDeviceID != nil else {
      inspectionTask?.cancel()
      snapshot = nil
      return
    }
    if let rawValue = UserDefaults.standard.string(forKey: "defaultProfile"),
      let profile = OptimizationProfile(rawValue: rawValue)
    {
      selectedProfile = profile
    }
    customDisabledLabels.removeAll()
    selectedStorageCategoryIDs.removeAll()
    inspectSelectedDevice()
  }

  func inspectSelectedDevice() {
    guard let id = selectedDeviceID else { return }
    inspectionTask?.cancel()
    isLoadingSnapshot = true

    inspectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await workspace.inspect(id)
        guard !Task.isCancelled, selectedDeviceID == id else { return }
        snapshot = result
        isLoadingSnapshot = false
        synchronizeSelections(with: result)
      } catch is CancellationError {
        if selectedDeviceID == id { isLoadingSnapshot = false }
      } catch {
        guard selectedDeviceID == id else { return }
        isLoadingSnapshot = false
        notice = AppNotice(
          title: L10n.text("error.inspect.title"),
          message: error.localizedDescription
        )
      }
    }
  }

  func selectDevice(_ deviceID: SimulatorID) {
    sidebarSelection = .device(deviceID)
  }

  func showHistory() {
    sidebarSelection = .history
  }

  func showBatchOptimization() {
    sidebarSelection = .batchOptimization
  }

  func showSettings() {
    sidebarSelection = .settings
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
    isPreparingBatchPreview = true
    batchPreviewCompletedCount = 0
    batchPreviewTotalCount = devices.count
    batchPreviewReservedDeviceIDs = Set(devices.map(\.id))
    batchPreviewTask = Task { [weak self] in
      await self?.prepareBatchPreview(devices: devices, profile: profile)
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
    if operations[deviceID]?.isRunning == true || operationTasks[deviceID] != nil {
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
    case .openSimulator: operation = .openSimulator(deviceID: deviceID)
    default: return
    }
    perform(operation)
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

  func showReceipt(_ receipt: OperationReceipt) {
    receiptPresentation = receipt
  }

  func canContinueVerification(from receipt: OperationReceipt) -> Bool {
    let pendingReceiptIDs = Set(overview?.pendingReceipts.map(\.id) ?? [])
    return receipt.schemaVersion == 1
      && receipt.kind == .optimize
      && receipt.opaquePayload == nil
      && optimizationSupport(for: receipt.deviceID) == .supported
      && !isDeviceBusy(receipt.deviceID)
      && (pendingReceiptIDs.contains(receipt.id) || receipt.pendingChange != nil)
  }

  func canRestore(from receipt: OperationReceipt) -> Bool {
    receipt.schemaVersion == 1
      && receipt.kind == .optimize
      && receipt.opaquePayload == nil
      && optimizationSupport(for: receipt.deviceID) == .supported
      && receipt.baselineCapturedAt != nil
      && !isDeviceBusy(receipt.deviceID)
      && (receipt.pendingChange != nil || receipt.appliedChanges.contains(where: \.succeeded))
  }

  func continueVerification(from receipt: OperationReceipt) {
    guard canContinueVerification(from: receipt) else { return }
    sidebarSelection = .device(receipt.deviceID)
    selectedSection = .optimization
    preparePreview(
      .verify(deviceID: receipt.deviceID, receiptID: receipt.id),
      confirmsExecution: true
    )
  }

  func restore(from receipt: OperationReceipt) {
    guard canRestore(from: receipt) else { return }
    sidebarSelection = .device(receipt.deviceID)
    selectedSection = .optimization
    preparePreview(
      .restore(deviceID: receipt.deviceID, receiptID: receipt.id),
      confirmsExecution: true
    )
  }

  private func prepareBatchPreview(
    devices: [SimulatorDevice],
    profile: OptimizationProfile
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
        customDisabledLabels: []
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

      operationTasks[deviceID] = nil
      await refreshAfterOperation(deviceID)
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
    if event.state == .failed {
      presentation.failureMessage = event.message
    }
    operations[event.deviceID] = presentation
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
  }

  private func refreshAfterOperation(_ deviceID: SimulatorID) async {
    do {
      let result = try await workspace.overview()
      overview = result
      synchronizeBatchSelection(with: result.inventory.devices)
      if selectedDeviceID == deviceID,
        result.inventory.devices.contains(where: { $0.id == deviceID })
      {
        let updatedSnapshot = try await workspace.inspect(deviceID)
        snapshot = updatedSnapshot
        synchronizeSelections(with: updatedSnapshot)
      } else if selectedDeviceID == deviceID {
        snapshot = nil
        reconcileSelection(with: result.inventory.devices)
      }
    } catch {
      notice = AppNotice(
        title: L10n.text("error.verify-refresh.title"),
        message: error.localizedDescription
      )
    }
  }

  private func reconcileSelection(with devices: [SimulatorDevice]) {
    if let sidebarSelection {
      switch sidebarSelection {
      case .batchOptimization, .history, .settings:
        return
      case .device:
        break
      }
    }

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
    let selectableLabels = Set(
      snapshot.services
        .filter { $0.isPresent && !$0.service.alwaysEnabled && $0.service.risk != .protected }
        .filter(\.isDisabled)
        .map(\.service.label)
    )
    if customDisabledLabels.isEmpty {
      customDisabledLabels = selectableLabels
    } else {
      let validLabels = Set(snapshot.services.map(\.service.label))
      customDisabledLabels.formIntersection(validLabels)
    }

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
