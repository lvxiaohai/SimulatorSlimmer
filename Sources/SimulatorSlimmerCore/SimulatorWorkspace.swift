import Foundation

public actor SimulatorWorkspace: SimulatorWorkspaceClient {
  private let simulator: any SimulatorControlling
  private let memoryInspector: any MemoryInspecting
  private let receiptStore: any ReceiptStoring
  private let storageManager: any StorageManaging
  private let applicationCatalog: SimulatorApplicationCatalog
  private let operationGate: OperationGate
  private let catalog: ServiceCatalog?
  private let catalogLoadError: String?
  private let memoryStabilizationDelay: Duration
  private let serviceMutationConfirmationLifetime: Duration
  private var serviceMutationConfirmations:
    [ServiceMutationConfirmationKey: ServiceMutationConfirmation] = [:]
  private var previewGenerationByDevice: [SimulatorID: UInt64] = [:]
  private var knownServiceLabelsByDevice: [SimulatorID: Set<String>] = [:]
  private var didRecoverInterruptedReceipts = false

  public init() {
    let runner = FoundationCommandRunner()
    self.simulator = SimctlAdapter(runner: runner)
    self.memoryInspector = LibprocMemoryInspector(runner: runner)
    self.receiptStore = ReceiptStore()
    self.storageManager = StorageManager()
    self.applicationCatalog = SimulatorApplicationCatalog(runner: runner)
    self.operationGate = OperationGate()
    self.memoryStabilizationDelay = .seconds(2)
    self.serviceMutationConfirmationLifetime = .seconds(300)
    do {
      self.catalog = try ServiceCatalog.bundled()
      self.catalogLoadError = nil
    } catch {
      self.catalog = nil
      self.catalogLoadError = error.localizedDescription
    }
  }

  init(
    simulator: any SimulatorControlling,
    memoryInspector: any MemoryInspecting,
    receiptStore: any ReceiptStoring,
    storageManager: any StorageManaging,
    applicationCatalog: SimulatorApplicationCatalog = SimulatorApplicationCatalog(),
    operationGate: OperationGate,
    catalog: ServiceCatalog,
    memoryStabilizationDelay: Duration = .zero,
    serviceMutationConfirmationLifetime: Duration = .seconds(300)
  ) {
    self.simulator = simulator
    self.memoryInspector = memoryInspector
    self.receiptStore = receiptStore
    self.storageManager = storageManager
    self.applicationCatalog = applicationCatalog
    self.operationGate = operationGate
    self.catalog = catalog
    self.catalogLoadError = nil
    self.memoryStabilizationDelay = memoryStabilizationDelay
    self.serviceMutationConfirmationLifetime = serviceMutationConfirmationLifetime
  }

  public func overview() async throws -> WorkspaceOverview {
    try await recoverInterruptedReceiptsIfNeeded()
    async let inventory = simulator.inventory()
    async let receipts = receiptStore.allReceipts()
    let (resolvedInventory, resolvedReceipts) = try await (inventory, receipts)
    let pending = resolvedReceipts.filter {
      guard $0.schemaVersion == 1 else { return false }
      if $0.pendingChange != nil { return true }
      if $0.pendingStorageCleanupPath != nil { return true }
      if $0.pendingDeviceAction != nil { return true }
      if $0.status == .prepared || $0.status == .running { return true }
      return $0.messages.contains { $0.contains(ReceiptStore.interruptionMarker) }
        && !$0.messages.contains { $0.contains(ReceiptStore.interruptionResolutionMarker) }
    }
    return WorkspaceOverview(
      inventory: resolvedInventory,
      recentReceipts: Array(resolvedReceipts.prefix(200)),
      pendingReceipts: pending
    )
  }

  public func menuBarSnapshot() async throws -> MenuBarSnapshot {
    try Task.checkCancellation()
    let inventory = try await simulator.inventory()
    let devices = inventory.devices
      .filter { $0.isAvailable && $0.state == .booted }
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }

    var snapshots: [MenuBarDeviceSnapshot] = []
    snapshots.reserveCapacity(devices.count)
    for device in devices {
      try Task.checkCancellation()
      do {
        let memory = try await memoryInspector.snapshot(for: device.id)
        snapshots.append(
          MenuBarDeviceSnapshot(device: device, memory: memory)
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        snapshots.append(
          MenuBarDeviceSnapshot(
            device: device,
            memory: nil,
            memoryError: error.localizedDescription
          )
        )
      }
    }
    return MenuBarSnapshot(devices: snapshots)
  }

  public func simulatorCreationOptions() async throws -> SimulatorCreationOptions {
    async let inventory = simulator.inventory()
    async let deviceTypes = simulator.availableDeviceTypes()
    let (resolvedInventory, resolvedDeviceTypes) = try await (inventory, deviceTypes)
    return SimulatorCreationOptions(
      runtimes: resolvedInventory.runtimes.filter(\.isAvailable),
      deviceTypes: resolvedDeviceTypes
    )
  }

  public func createSimulator(
    _ request: SimulatorCreationRequest
  ) async throws -> SimulatorID {
    let options = try await simulatorCreationOptions()
    guard
      let runtime = options.runtimes.first(where: { $0.id == request.runtimeID }),
      let deviceType = options.deviceTypes.first(where: { $0.id == request.deviceTypeID }),
      deviceType.supports(runtimeVersion: runtime.version)
    else {
      throw SimulatorWorkspaceError.invalidOperation("设备类型与系统运行时不兼容")
    }
    return try await simulator.create(request)
  }

  public func inspect(_ deviceID: SimulatorID) async throws -> DeviceSnapshot {
    try Task.checkCancellation()
    let context = try await deviceContext(deviceID)
    let latestStoragePlan = await storageManager.latestPlan(for: deviceID)

    guard context.device.isAvailable else {
      return DeviceSnapshot(
        device: context.device,
        memory: nil,
        services: [],
        categories: [],
        plans: [:],
        latestStoragePlan: latestStoragePlan,
        memoryError: context.device.availabilityError ?? "该系统运行时当前不可用",
        optimizationSupport: .unavailableRuntime
      )
    }

    let catalog = try requiredCatalog()
    let applicable = catalog.applicableServices(runtimeVersion: context.runtimeVersion)
    guard !applicable.isEmpty else {
      return DeviceSnapshot(
        device: context.device,
        memory: nil,
        services: [],
        categories: catalog.categories,
        plans: [:],
        latestStoragePlan: latestStoragePlan,
        memoryError: "尚未验证 \(context.runtimeVersion) 系统运行时的服务规则",
        optimizationSupport: .unsupportedRuntime
      )
    }

    let currentDisabled: Set<String>
    let presentLabels: Set<String>?
    var memory: MemorySnapshot?
    var memoryError: String?
    if context.device.state == .booted {
      currentDisabled = try await simulator.disabledLabels(for: deviceID)
      presentLabels = try await presentServiceLabels(
        context: context,
        catalog: catalog,
        knownDisabledLabels: currentDisabled
      )
      do {
        memory = try await memoryInspector.snapshot(for: deviceID)
      } catch {
        memoryError = error.localizedDescription
      }
    } else {
      currentDisabled = []
      presentLabels = nil
      memoryError = "启动模拟器后可读取实时物理内存；执行优化时会临时启动并恢复电源状态"
    }

    var plans: [OptimizationProfile: OptimizationPlan] = [:]
    for profile in OptimizationProfile.allCases where profile != .custom {
      plans[profile] = catalog.plan(
        deviceID: deviceID,
        runtimeVersion: context.runtimeVersion,
        profile: profile,
        currentDisabledLabels: currentDisabled,
        presentLabels: presentLabels
      )
    }
    plans[.custom] = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: context.runtimeVersion,
      profile: .custom,
      currentDisabledLabels: currentDisabled,
      customDisabledLabels: currentDisabled,
      presentLabels: presentLabels
    )

    return DeviceSnapshot(
      device: context.device,
      memory: memory,
      services: catalog.serviceStates(
        runtimeVersion: context.runtimeVersion,
        disabledLabels: currentDisabled,
        presentLabels: presentLabels
      ),
      categories: catalog.categories,
      plans: plans,
      latestStoragePlan: latestStoragePlan,
      memoryError: memoryError
    )
  }

  public func applications(for deviceID: SimulatorID) async throws
    -> SimulatorApplicationListSnapshot
  {
    try Task.checkCancellation()
    let applications = try await applicationCatalog.applications(for: deviceID)
    try Task.checkCancellation()

    do {
      let memoryByBundleIdentifier = try await memoryInspector.applicationMemorySnapshots(
        for: deviceID,
        applications: applications
      )
      try Task.checkCancellation()
      return SimulatorApplicationListSnapshot(
        applications: applications,
        memoryByBundleIdentifier: memoryByBundleIdentifier
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return SimulatorApplicationListSnapshot(
        applications: applications,
        memoryError: error.localizedDescription
      )
    }
  }

  public func dataContainer(
    for deviceID: SimulatorID,
    bundleIdentifier: String
  ) async throws -> URL? {
    try await applicationCatalog.dataContainer(
      for: deviceID,
      bundleIdentifier: bundleIdentifier
    )
  }

  public func showSimulator(_ deviceID: SimulatorID) async throws {
    try Task.checkCancellation()
    let device = try await simulator.validatedDevice(deviceID)
    guard device.state == .booted else {
      throw SimulatorWorkspaceError.deviceNotBooted(deviceID)
    }
    try await simulator.openSimulator(deviceID)
  }

  public func preview(_ operation: SimulatorOperation) async throws -> OperationPreview {
    try Task.checkCancellation()
    let previewGeneration = beginPreview(for: operation.deviceID)
    let context = try await deviceContext(operation.deviceID)
    guard context.device.isAvailable else {
      throw SimulatorWorkspaceError.deviceUnavailable(
        context.device.availabilityError ?? "该模拟器当前不可用"
      )
    }
    try requireStableDeviceState(context.device)

    switch operation {
    case .optimize(let deviceID, let profile, let customDisabledLabels):
      let catalog = try requiredCatalog()
      guard !catalog.applicableServices(runtimeVersion: context.runtimeVersion).isEmpty else {
        throw SimulatorWorkspaceError.invalidOperation(
          "尚未验证 \(context.runtimeVersion) 系统运行时，不能修改服务"
        )
      }
      let serviceState = try await serviceStateForPreview(context: context, catalog: catalog)
      let plan = catalog.plan(
        deviceID: deviceID,
        runtimeVersion: context.runtimeVersion,
        profile: profile,
        currentDisabledLabels: serviceState.disabledLabels,
        customDisabledLabels: customDisabledLabels,
        presentLabels: serviceState.presentLabels
      )
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: plan.changes,
        intendedOriginalDeviceState: context.device.state,
        previewGeneration: previewGeneration
      )
      var warnings = powerStateWarnings(context.device, action: "优化")
      if !plan.unknownDisabledLabels.isEmpty {
        warnings.append("发现 \(plan.unknownDisabledLabels.count) 个非本应用管理的禁用项，将保持原样")
      }
      if plan.changes.contains(where: { $0.risk == .high }) {
        warnings.append("该方案会停用高影响服务，请先确认相关能力不在本次测试范围内")
      }
      return OperationPreview(
        operation: operation,
        title: "优化 \(context.device.name)",
        summary: plan.changes.isEmpty
          ? "设备已经符合所选方案，不需要修改服务。"
          : "将按严格允许列表执行 \(plan.changes.count) 项差异，随后重启、验证并保存恢复基线。",
        serviceChanges: plan.changes,
        warnings: warnings,
        requiresConfirmation: true
      )

    case .verify(_, let receiptID):
      let source = try await receiptStore.receipt(id: receiptID)
      guard source.deviceID == operation.deviceID, source.kind == .optimize else {
        throw SimulatorWorkspaceError.invalidOperation("该恢复数据不能用于当前设备继续验证")
      }
      var changes = source.appliedChanges.filter(\.succeeded).map(\.change)
      if let pendingChange = source.pendingChange,
        !changes.contains(where: { $0.label == pendingChange.label })
      {
        changes.append(pendingChange)
      }
      return OperationPreview(
        operation: operation,
        title: "继续验证 \(context.device.name)",
        summary: changes.isEmpty
          ? "上次操作尚未记录服务变更；将确认设备可用性和当前状态。"
          : "将只读核对中断前已执行或结果未知的 \(changes.count) 项服务状态，并保存新的验证结果。",
        serviceChanges: changes,
        warnings: sourcePowerStateWarnings(
          source: source,
          currentDevice: context.device,
          action: "验证"
        ),
        requiresConfirmation: true
      )

    case .restore(_, let receiptID):
      let source = try await receiptStore.receipt(id: receiptID)
      guard source.deviceID == operation.deviceID, source.kind == .optimize else {
        throw SimulatorWorkspaceError.invalidOperation("该恢复数据不能用于当前设备恢复")
      }
      guard source.baselineCapturedAt != nil else {
        throw SimulatorWorkspaceError.invalidOperation("上次操作在中断前尚未取得服务基线，不能执行恢复")
      }
      let catalog = try requiredCatalog()
      let serviceState = try await serviceStateForPreview(context: context, catalog: catalog)
      let changes = try restoreChanges(
        source: source,
        runtimeVersion: context.runtimeVersion,
        currentDisabled: serviceState.disabledLabels,
        presentLabels: serviceState.presentLabels
      )
      var warnings = sourcePowerStateWarnings(
        source: source,
        currentDevice: context.device,
        action: "恢复"
      )
      let protectedBaselineLabels = try blockedRestoreLabels(
        source: source,
        runtimeVersion: context.runtimeVersion
      )
      if !protectedBaselineLabels.isEmpty {
        warnings.append(
          "恢复基线中的 \(protectedBaselineLabels.count) 个关键服务不会被重新停用"
        )
      }
      let touchedLabels = Set(
        source.appliedChanges.filter(\.succeeded).map { $0.change.label }
      ).union(source.pendingChange.map { [$0.label] } ?? [])
      let applicableLabels = Set(
        catalog.applicableServices(runtimeVersion: context.runtimeVersion).map(\.label)
      )
      let unavailableTouchedLabels = touchedLabels.subtracting(applicableLabels)
      if !unavailableTouchedLabels.isEmpty {
        warnings.append(
          "当前服务目录无法恢复：\(unavailableTouchedLabels.sorted().joined(separator: ", "))"
        )
      }
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: changes,
        intendedOriginalDeviceState: try await intendedOriginalDeviceState(
          for: operation,
          fallback: context.device.state
        ),
        previewGeneration: previewGeneration
      )
      return OperationPreview(
        operation: operation,
        title: "恢复 \(context.device.name)",
        summary: changes.isEmpty
          ? "当前服务状态已经与恢复基线一致。"
          : "只会恢复上次操作实际触及的允许列表服务，共 \(changes.count) 项。",
        serviceChanges: changes,
        warnings: warnings,
        requiresConfirmation: true
      )

    case .scanStorage:
      guard context.device.state == .shutdown else {
        throw SimulatorWorkspaceError.invalidOperation(
          "请先关闭模拟器，再重新扫描存储并确认清理范围"
        )
      }
      return OperationPreview(
        operation: operation,
        title: "扫描 \(context.device.name) 的存储",
        summary: "只读取结构化安全路径并汇总空间，不会删除任何文件。"
      )

    case .cleanStorage(_, let planID, let categoryIDs, _):
      guard context.device.state == .shutdown else {
        throw SimulatorWorkspaceError.invalidOperation(
          "请先关闭模拟器，再重新扫描存储并确认清理范围"
        )
      }
      guard let plan = await storageManager.latestPlan(for: operation.deviceID),
        plan.id == planID
      else {
        throw SimulatorWorkspaceError.staleStoragePlan
      }
      let selected = plan.categories.filter {
        categoryIDs.contains($0.id) && $0.canClean
      }
      guard selected.count == categoryIDs.count else {
        throw SimulatorWorkspaceError.invalidOperation("清理请求包含未知或受保护类别")
      }
      let selectedBytes = selected.reduce(Int64(0)) { $0 + $1.bytes }
      let selectedTargetCount = plan.items.filter {
        categoryIDs.contains($0.categoryID)
      }.count
      let warnings = ["删除后无法通过本应用撤销；缓存和临时文件由系统按需重建"]
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: [],
        intendedOriginalDeviceState: context.device.state,
        previewGeneration: previewGeneration
      )
      return OperationPreview(
        operation: operation,
        title: "清理 \(context.device.name) 的存储",
        summary:
          "将清理 \(selected.count) 个高置信类别中的 \(selectedTargetCount) 个路径，并在删除前再次验证路径与文件身份。",
        selectedBytes: selectedBytes,
        warnings: warnings,
        requiresConfirmation: true
      )

    case .boot:
      return .init(
        operation: operation,
        title: "启动 \(context.device.name)",
        summary: context.device.state == .booted ? "设备已经启动。" : "等待设备完成系统启动。"
      )
    case .shutdown:
      return .init(
        operation: operation,
        title: "关闭 \(context.device.name)",
        summary: context.device.state == .shutdown ? "设备已经关机。" : "安全关闭当前模拟器。"
      )
    case .openSimulator:
      return .init(
        operation: operation,
        title: "在 Apple 模拟器中打开",
        summary: "启动设备并在 Apple 模拟器中切换到 \(context.device.name)。"
      )
    case .erase:
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: [],
        intendedOriginalDeviceState: context.device.state,
        previewGeneration: previewGeneration
      )
      return .init(
        operation: operation,
        title: "抹掉 \(context.device.name)",
        summary: "删除该设备内的应用、账户、设置与测试数据，设备本身仍会保留。",
        warnings: ["此操作不可撤销"],
        requiresConfirmation: true,
        confirmationPhrase: context.device.name
      )
    case .delete:
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: [],
        intendedOriginalDeviceState: context.device.state,
        previewGeneration: previewGeneration
      )
      return .init(
        operation: operation,
        title: "删除 \(context.device.name)",
        summary: "永久删除该模拟器设备及其全部本地数据。",
        warnings: ["此操作不可撤销，删除后设备将从 Xcode 与 Apple 模拟器消失"],
        requiresConfirmation: true,
        confirmationPhrase: context.device.name
      )
    case .clone(_, let name):
      let trimmed = try SimctlAdapter.validatedCloneName(name)
      saveServiceMutationConfirmation(
        operation: operation,
        context: context,
        changes: [],
        intendedOriginalDeviceState: context.device.state,
        previewGeneration: previewGeneration
      )
      return .init(
        operation: operation,
        title: "克隆 \(context.device.name)",
        summary: "创建名为“\(trimmed)”的独立设备副本；源设备的数据保持不变。",
        warnings: powerStateWarnings(context.device, action: "克隆"),
        requiresConfirmation: true
      )
    }
  }

  public func perform(
    _ operation: SimulatorOperation
  ) async -> AsyncThrowingStream<OperationEvent, Error> {
    let operationID = ReceiptID()
    let pair = AsyncThrowingStream<OperationEvent, Error>.makeStream()
    let task = Task { [weak self] in
      guard let self else {
        pair.continuation.finish()
        return
      }
      await self.execute(
        operation,
        operationID: operationID,
        continuation: pair.continuation
      )
    }
    pair.continuation.onTermination = { @Sendable _ in task.cancel() }
    return pair.stream
  }

  public func exportDiagnostics(to destinationURL: URL) async throws -> URL {
    try await recoverInterruptedReceiptsIfNeeded()
    async let inventory = simulator.inventory()
    async let receipts = receiptStore.allReceipts()
    let exporter = DiagnosticsExporter()
    let result = try await exporter.export(
      inventory: inventory,
      receipts: receipts,
      to: destinationURL
    )
    await DiagnosticLogStore.shared.record(
      level: .info,
      event: "diagnostics-exported",
      detail: destinationURL.lastPathComponent
    )
    return result
  }

  private func deviceContext(_ deviceID: SimulatorID) async throws -> DeviceContext {
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    let inventory = try await simulator.inventory()
    guard let device = inventory.devices.first(where: { $0.id == deviceID }) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    let runtimeVersion =
      inventory.runtimes
      .first(where: { $0.id == device.runtimeIdentifier })?.version
      ?? device.runtimeName.split(separator: " ").last.map(String.init)
      ?? device.runtimeName
    return DeviceContext(device: device, runtimeVersion: runtimeVersion)
  }

  private func intendedOriginalDeviceState(
    for operation: SimulatorOperation,
    fallback: SimulatorState
  ) async throws -> SimulatorState {
    let sourceReceiptID: ReceiptID?
    switch operation {
    case .verify(_, let receiptID), .restore(_, let receiptID):
      sourceReceiptID = receiptID
    default:
      sourceReceiptID = nil
    }
    guard let sourceReceiptID else { return fallback }
    let source = try await receiptStore.receipt(id: sourceReceiptID)
    guard shouldRestoreInterruptedSourcePowerState(source) else { return fallback }
    switch source.originalDeviceState {
    case .booted, .shutdown:
      return source.originalDeviceState
    default:
      return fallback
    }
  }

  private func interruptionPowerRecoveryPolicy(
    for operation: SimulatorOperation
  ) -> Bool? {
    switch operation {
    case .cleanStorage(_, _, _, let preserveBootState): preserveBootState
    case .erase, .clone: true
    case .delete: false
    default: nil
    }
  }

  private func persistedInput(for operation: SimulatorOperation) -> OperationInput? {
    switch operation {
    case .optimize(_, let profile, let customDisabledLabels):
      return OperationInput(
        profile: profile,
        customDisabledLabels: profile == .custom ? customDisabledLabels : []
      )
    case .verify(_, let receiptID), .restore(_, let receiptID):
      return OperationInput(sourceReceiptID: receiptID)
    case .cleanStorage(_, let planID, let categoryIDs, let preserveBootState):
      return OperationInput(
        storagePlanID: planID,
        storageCategoryIDs: categoryIDs,
        preserveBootState: preserveBootState
      )
    case .clone(_, let name):
      return OperationInput(cloneName: name.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
    }
  }

  private func presentServiceLabels(
    context: DeviceContext,
    catalog: ServiceCatalog,
    knownDisabledLabels: Set<String> = []
  ) async throws -> Set<String> {
    let candidates = Set(
      catalog.applicableServices(runtimeVersion: context.runtimeVersion).map(\.label)
    )
    let configured: Set<String>
    if let cached = knownServiceLabelsByDevice[context.device.id] {
      configured = cached
    } else {
      configured = try await simulator.presentServiceLabels(candidates, for: context.device.id)
    }
    // 不同 Runtime 的 domain 输出对未加载 job 的覆盖并不完全一致；额外合并
    // print-disabled 中的目录标签，避免把已禁用但仍可恢复的服务误判为不存在。
    let confirmed = configured.union(knownDisabledLabels.intersection(candidates))
    knownServiceLabelsByDevice[context.device.id] = confirmed
    return confirmed
  }

  private func serviceStateForPreview(
    context: DeviceContext,
    catalog: ServiceCatalog
  ) async throws -> ServiceStateSnapshot {
    if context.device.state == .booted {
      let disabledLabels = try await simulator.disabledLabels(for: context.device.id)
      return ServiceStateSnapshot(
        disabledLabels: disabledLabels,
        presentLabels: try await presentServiceLabels(
          context: context,
          catalog: catalog,
          knownDisabledLabels: disabledLabels
        )
      )
    }

    var deviceLock: DeviceOperationLock?
    var receipt = OperationReceipt(
      kind: .preflight,
      deviceID: context.device.id,
      deviceName: context.device.name,
      status: .prepared,
      originalDeviceState: .shutdown,
      runtimeIdentifier: context.device.runtimeIdentifier,
      runtimeVersion: context.runtimeVersion,
      serviceCatalogVersion: catalog.schemaVersion,
      messages: ["为生成精确差异预览，将临时启动设备读取服务状态"]
    )
    var receiptWasPrepared = false

    do {
      deviceLock = try await operationGate.acquire(for: context.device.id)
      // 任何临时启动都必须晚于可恢复回执的原子保存。
      try await receiptStore.save(receipt)
      receiptWasPrepared = true
      receipt.status = .running
      try await receiptStore.save(receipt)

      try await simulator.boot(context.device.id)
      let disabledLabels = try await simulator.disabledLabels(for: context.device.id)
      let state = ServiceStateSnapshot(
        disabledLabels: disabledLabels,
        presentLabels: try await presentServiceLabels(
          context: context,
          catalog: catalog,
          knownDisabledLabels: disabledLabels
        )
      )
      try await shutdownShielded(context.device.id)
      receipt.status = .succeeded
      receipt.finishedAt = Date()
      receipt.finalDeviceState = .shutdown
      receipt.messages.append("已读取精确服务状态并恢复关机")
      try await receiptStore.save(receipt)
      await deviceLock?.release()
      return state
    } catch {
      let shutdownError: Error?
      do {
        try await shutdownShielded(context.device.id)
        shutdownError = nil
      } catch {
        shutdownError = error
      }
      if receiptWasPrepared {
        receipt.status = error is CancellationError ? .cancelled : .failed
        receipt.finishedAt = Date()
        receipt.finalDeviceState = await currentDeviceState(context.device.id)
        receipt.messages.append(
          error is CancellationError
            ? "预览已取消"
            : "生成精确预览失败：\(error.localizedDescription)"
        )
        if let shutdownError {
          receipt.messages.append("恢复关机状态失败：\(shutdownError.localizedDescription)")
          receipt.messages.append(
            "\(ReceiptStore.interruptionMarker)；预检电源状态仍待自动恢复"
          )
        } else {
          receipt.finalDeviceState = .shutdown
          receipt.messages.append("异常后已恢复关机状态")
        }
        try? await receiptStore.save(receipt)
      }
      await deviceLock?.release()
      throw error
    }
  }

  private func shutdownShielded(_ deviceID: SimulatorID) async throws {
    let simulator = self.simulator
    try await Task.detached(priority: .userInitiated) {
      try await simulator.shutdown(deviceID)
    }.value
  }

  private func bootShielded(_ deviceID: SimulatorID) async throws {
    let simulator = self.simulator
    try await Task.detached(priority: .userInitiated) {
      try await simulator.boot(deviceID)
    }.value
  }

  private func requiredCatalog() throws -> ServiceCatalog {
    guard let catalog else {
      throw SimulatorWorkspaceError.malformedOutput(
        catalogLoadError ?? "服务目录加载失败"
      )
    }
    return catalog
  }

  private func recoverInterruptedReceiptsIfNeeded() async throws {
    guard !didRecoverInterruptedReceipts else { return }
    let recovered = try await receiptStore.recoverInterruptedReceipts()
    let allReceipts = try await receiptStore.allReceipts()
    let unresolvedPreflights = allReceipts.filter {
      $0.schemaVersion == 1
        && $0.kind == .preflight
        && $0.originalDeviceState == .shutdown
        && $0.messages.contains { $0.contains(ReceiptStore.interruptionMarker) }
        && !$0.messages.contains { $0.contains(ReceiptStore.interruptionResolutionMarker) }
    }
    var candidatesByID: [ReceiptID: OperationReceipt] = [:]
    for receipt in recovered + unresolvedPreflights
    where receipt.kind == .preflight && receipt.originalDeviceState == .shutdown {
      candidatesByID[receipt.id] = receipt
    }
    for var receipt in candidatesByID.values {
      var deviceLock: DeviceOperationLock?
      do {
        deviceLock = try await operationGate.acquire(for: receipt.deviceID)
        try await shutdownShielded(receipt.deviceID)
        receipt.finalDeviceState = .shutdown
        receipt.messages.append(
          "\(ReceiptStore.interruptionResolutionMarker)：已自动恢复预检前的关机状态"
        )
      } catch {
        receipt.finalDeviceState = await currentDeviceState(receipt.deviceID)
        receipt.messages.append("自动恢复预检前关机状态失败：\(error.localizedDescription)")
      }
      try? await receiptStore.save(receipt)
      await deviceLock?.release()
    }
    let bootRecoveryKinds: Set<OperationKind> = [.cleanStorage, .erase, .clone]
    let unresolvedBootRecoveries = allReceipts.filter {
      $0.schemaVersion == 1
        && bootRecoveryKinds.contains($0.kind)
        && $0.shouldRestoreOriginalDeviceState == true
        && $0.originalDeviceState == .booted
        && $0.finalDeviceState != .booted
        && $0.messages.contains { $0.contains(ReceiptStore.interruptionMarker) }
        && !$0.messages.contains { $0.contains(ReceiptStore.interruptionResolutionMarker) }
    }
    for var receipt in unresolvedBootRecoveries {
      var deviceLock: DeviceOperationLock?
      do {
        deviceLock = try await operationGate.acquire(for: receipt.deviceID)
        try await bootShielded(receipt.deviceID)
        receipt.finalDeviceState = .booted
        receipt.messages.append(
          "\(ReceiptStore.interruptionResolutionMarker)：已自动恢复操作前的启动状态"
        )
      } catch {
        receipt.finalDeviceState = await currentDeviceState(receipt.deviceID)
        receipt.messages.append("自动恢复操作前启动状态失败：\(error.localizedDescription)")
      }
      try? await receiptStore.save(receipt)
      await deviceLock?.release()
    }
    didRecoverInterruptedReceipts = true
  }

  private func powerStateWarnings(
    _ device: SimulatorDevice,
    action: String
  ) -> [String] {
    device.state == .shutdown
      ? ["设备当前已关机；执行\(action)时会临时启动，完成后恢复关机状态"]
      : []
  }

  private func sourcePowerStateWarnings(
    source: OperationReceipt,
    currentDevice: SimulatorDevice,
    action: String
  ) -> [String] {
    guard shouldRestoreInterruptedSourcePowerState(source) else {
      return powerStateWarnings(currentDevice, action: action)
    }
    if source.originalDeviceState == .shutdown, currentDevice.state == .booted {
      return ["来源操作在设备关机时开始；完成\(action)后会恢复该关机状态"]
    }
    if source.originalDeviceState == .booted, currentDevice.state == .shutdown {
      return ["来源操作在设备启动时开始；完成\(action)后会恢复该启动状态"]
    }
    return powerStateWarnings(currentDevice, action: action)
  }

  private func shouldRestoreInterruptedSourcePowerState(
    _ source: OperationReceipt
  ) -> Bool {
    if source.pendingChange != nil || source.status == .prepared || source.status == .running {
      return true
    }
    return source.messages.contains { $0.contains(ReceiptStore.interruptionMarker) }
      && !source.messages.contains { $0.contains(ReceiptStore.interruptionResolutionMarker) }
  }

  private func requireStableDeviceState(_ device: SimulatorDevice) throws {
    guard device.state == .booted || device.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "设备当前处于\(localizedDeviceState(device.state))，请等待它稳定为已启动或已关机后重试"
      )
    }
  }

  private func localizedDeviceState(_ state: SimulatorState) -> String {
    switch state {
    case .booted: "已启动"
    case .shutdown: "已关机"
    case .creating: "创建中"
    case .shuttingDown: "正在关机"
    case .unavailable: "不可用"
    case .unknown: "未知状态"
    }
  }

  private func restoreChanges(
    source: OperationReceipt,
    runtimeVersion: String,
    currentDisabled: Set<String>,
    presentLabels _: Set<String>
  ) throws -> [ServiceChange] {
    let catalog = try requiredCatalog()
    // 来源回执已经证明这些目录标签在同一设备与 Runtime 上真实可操作。
    // 被 disable 的 job 重启后不会出现在 launchctl print 中，恢复不能因此跳过它。
    let applicable = catalog.applicableServices(runtimeVersion: runtimeVersion)
    let servicesByLabel = Dictionary(uniqueKeysWithValues: applicable.map { ($0.label, $0) })
    var touchedLabels = Set(
      source.appliedChanges.filter(\.succeeded).map { $0.change.label }
    )
    if let pendingChange = source.pendingChange {
      touchedLabels.insert(pendingChange.label)
    }
    var changes: [ServiceChange] = []

    for label in touchedLabels.sorted() {
      guard let service = servicesByLabel[label] else { continue }
      let shouldBeDisabled = source.baselineDisabledLabels.contains(label)
      if shouldBeDisabled && (service.alwaysEnabled || service.risk == .protected) {
        continue
      }
      if currentDisabled.contains(label) == shouldBeDisabled {
        continue
      }
      changes.append(
        ServiceChange(
          label: label,
          serviceName: service.name,
          categoryID: service.categoryID,
          risk: service.risk,
          transition: shouldBeDisabled ? .disable : .enable
        )
      )
    }
    return changes
  }

  private func blockedRestoreLabels(
    source: OperationReceipt,
    runtimeVersion: String
  ) throws -> [String] {
    let catalog = try requiredCatalog()
    let protectedLabels = Set(
      catalog.applicableServices(runtimeVersion: runtimeVersion)
        .filter { $0.alwaysEnabled || $0.risk == .protected }
        .map(\.label)
    )
    var touchedLabels = Set(
      source.appliedChanges.filter(\.succeeded).map { $0.change.label }
    )
    if let pendingChange = source.pendingChange {
      touchedLabels.insert(pendingChange.label)
    }
    return source.baselineDisabledLabels
      .intersection(touchedLabels)
      .intersection(protectedLabels)
      .sorted()
  }

  private struct DeviceContext: Sendable {
    let device: SimulatorDevice
    let runtimeVersion: String
  }

  private struct ServiceStateSnapshot: Sendable {
    let disabledLabels: Set<String>
    let presentLabels: Set<String>
  }

  private struct ServiceMutationConfirmationKey: Hashable, Sendable {
    let deviceID: SimulatorID
    let kind: OperationKind
    let inputIdentity: String
  }

  private struct ServiceMutationConfirmation: Sendable {
    let key: ServiceMutationConfirmationKey
    let runtimeIdentifier: String
    let previewDeviceState: SimulatorState
    let intendedOriginalDeviceState: SimulatorState
    let changes: Set<ServiceChange>
    let expiresAt: ContinuousClock.Instant
  }

  private func beginPreview(for deviceID: SimulatorID) -> UInt64 {
    serviceMutationConfirmations = serviceMutationConfirmations.filter {
      $0.key.deviceID != deviceID
    }
    let generation = (previewGenerationByDevice[deviceID] ?? 0) &+ 1
    previewGenerationByDevice[deviceID] = generation
    return generation
  }

  private func serviceMutationConfirmationKey(
    for operation: SimulatorOperation
  ) -> ServiceMutationConfirmationKey? {
    switch operation {
    case .optimize(let deviceID, let profile, let customDisabledLabels):
      let labels = profile == .custom ? customDisabledLabels.sorted() : []
      return ServiceMutationConfirmationKey(
        deviceID: deviceID,
        kind: .optimize,
        inputIdentity: "\(profile.rawValue):\(labels.joined(separator: "\u{1F}"))"
      )
    case .restore(let deviceID, let receiptID):
      return ServiceMutationConfirmationKey(
        deviceID: deviceID,
        kind: .restore,
        inputIdentity: receiptID.rawValue.uuidString.lowercased()
      )
    case .cleanStorage(let deviceID, let planID, let categoryIDs, let preserveBootState):
      return ServiceMutationConfirmationKey(
        deviceID: deviceID,
        kind: .cleanStorage,
        inputIdentity:
          "\(planID.uuidString.lowercased()):\(categoryIDs.sorted().joined(separator: "\u{1F}")):\(preserveBootState)"
      )
    case .erase(let deviceID):
      return ServiceMutationConfirmationKey(deviceID: deviceID, kind: .erase, inputIdentity: "")
    case .delete(let deviceID):
      return ServiceMutationConfirmationKey(deviceID: deviceID, kind: .delete, inputIdentity: "")
    case .clone(let deviceID, let name):
      return ServiceMutationConfirmationKey(
        deviceID: deviceID,
        kind: .clone,
        inputIdentity: name.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    default:
      return nil
    }
  }

  private func saveServiceMutationConfirmation(
    operation: SimulatorOperation,
    context: DeviceContext,
    changes: [ServiceChange],
    intendedOriginalDeviceState: SimulatorState,
    previewGeneration: UInt64
  ) {
    guard previewGenerationByDevice[context.device.id] == previewGeneration else { return }
    guard let key = serviceMutationConfirmationKey(for: operation) else { return }
    serviceMutationConfirmations[key] = ServiceMutationConfirmation(
      key: key,
      runtimeIdentifier: context.device.runtimeIdentifier,
      previewDeviceState: context.device.state,
      intendedOriginalDeviceState: intendedOriginalDeviceState,
      changes: Set(changes),
      expiresAt: ContinuousClock.now.advanced(by: serviceMutationConfirmationLifetime)
    )
  }

  private func consumeServiceMutationConfirmation(
    for operation: SimulatorOperation,
    context: DeviceContext
  ) async throws -> ServiceMutationConfirmation? {
    guard let key = serviceMutationConfirmationKey(for: operation) else { return nil }
    guard let confirmation = serviceMutationConfirmations.removeValue(forKey: key) else {
      throw SimulatorWorkspaceError.invalidOperation("缺少有效确认，请重新预览并确认服务差异")
    }
    guard ContinuousClock.now <= confirmation.expiresAt else {
      throw SimulatorWorkspaceError.invalidOperation("确认已过期，请重新预览并确认服务差异")
    }
    let intendedOriginalState = try await intendedOriginalDeviceState(
      for: operation,
      fallback: context.device.state
    )
    guard confirmation.key == key,
      confirmation.runtimeIdentifier == context.device.runtimeIdentifier,
      confirmation.previewDeviceState == context.device.state,
      confirmation.intendedOriginalDeviceState == intendedOriginalState
    else {
      throw SimulatorWorkspaceError.invalidOperation("设备或电源状态已变化，请重新预览并确认服务差异")
    }
    if case .cleanStorage(_, let planID, _, _) = operation {
      guard await storageManager.latestPlan(for: operation.deviceID)?.id == planID else {
        throw SimulatorWorkspaceError.staleStoragePlan
      }
    }
    return confirmation
  }
}

extension SimulatorWorkspace {
  private func execute(
    _ operation: SimulatorOperation,
    operationID: ReceiptID,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async {
    var deviceLock: DeviceOperationLock?
    var receipt = OperationReceipt(
      id: operationID,
      kind: operation.kind,
      deviceID: operation.deviceID,
      deviceName: "",
      status: .prepared,
      originalDeviceState: .unknown
    )
    var receiptWasPrepared = false
    var mutationWasAuthorized = false

    do {
      deviceLock = try await operationGate.acquire(for: operation.deviceID)
      let context = try await deviceContext(operation.deviceID)
      guard context.device.isAvailable else {
        throw SimulatorWorkspaceError.deviceUnavailable(
          context.device.availabilityError ?? "该模拟器当前不可用"
        )
      }
      try requireStableDeviceState(context.device)
      if case .clone(_, let name) = operation {
        _ = try SimctlAdapter.validatedCloneName(name)
      }
      if case .scanStorage = operation, context.device.state != .shutdown {
        throw SimulatorWorkspaceError.invalidOperation(
          "请先关闭模拟器，再重新扫描存储并确认清理范围"
        )
      }
      let serviceMutationConfirmation = try await consumeServiceMutationConfirmation(
        for: operation,
        context: context
      )

      emit(
        continuation,
        operationID: operationID,
        deviceID: operation.deviceID,
        phase: .preflight,
        message: "已验证设备标识、可用性与操作互斥锁"
      )

      receipt = OperationReceipt(
        id: operationID,
        kind: operation.kind,
        deviceID: operation.deviceID,
        deviceName: context.device.name,
        status: .prepared,
        originalDeviceState: try await intendedOriginalDeviceState(
          for: operation,
          fallback: context.device.state
        ),
        shouldRestoreOriginalDeviceState: interruptionPowerRecoveryPolicy(for: operation),
        input: persistedInput(for: operation),
        runtimeIdentifier: context.device.runtimeIdentifier,
        runtimeVersion: context.runtimeVersion,
        serviceCatalogVersion: catalog?.schemaVersion
      )
      receiptWasPrepared = true

      // 任何可能修改模拟器的命令都必须晚于这次原子保存。
      try await receiptStore.save(receipt)
      mutationWasAuthorized = true
      receipt.status = .running
      try await receiptStore.save(receipt)
      await DiagnosticLogStore.shared.record(
        level: .info,
        event: "operation-started:\(operation.kind.rawValue)",
        operationID: operationID,
        deviceID: operation.deviceID
      )

      switch operation {
      case .optimize(_, let profile, let customDisabledLabels):
        guard let serviceMutationConfirmation else {
          throw SimulatorWorkspaceError.invalidOperation("缺少优化确认签名")
        }
        try await executeOptimization(
          profile: profile,
          customDisabledLabels: customDisabledLabels,
          confirmation: serviceMutationConfirmation,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .verify(_, let sourceReceiptID):
        try await executeVerification(
          sourceReceiptID: sourceReceiptID,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .restore(_, let sourceReceiptID):
        guard let serviceMutationConfirmation else {
          throw SimulatorWorkspaceError.invalidOperation("缺少恢复确认签名")
        }
        try await executeRestore(
          sourceReceiptID: sourceReceiptID,
          confirmation: serviceMutationConfirmation,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .scanStorage:
        try await executeStorageScan(
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .cleanStorage(_, let planID, let categoryIDs, let preserveBootState):
        guard serviceMutationConfirmation != nil else {
          throw SimulatorWorkspaceError.invalidOperation("缺少存储清理确认签名")
        }
        try await executeStorageCleanup(
          planID: planID,
          categoryIDs: categoryIDs,
          preserveBootState: preserveBootState,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .erase, .delete, .clone:
        guard serviceMutationConfirmation != nil else {
          throw SimulatorWorkspaceError.invalidOperation("缺少设备管理确认签名")
        }
        try await executeDeviceAction(
          operation,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .boot, .shutdown, .openSimulator:
        try await executeDeviceAction(
          operation,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      }

      if receipt.status == .running || receipt.status == .prepared {
        receipt.status = .succeeded
      }
      receipt.finishedAt = Date()
      if receipt.finalDeviceState == nil {
        receipt.finalDeviceState = await currentDeviceState(operation.deviceID)
      }
      try await receiptStore.save(receipt)
      await DiagnosticLogStore.shared.record(
        level: receipt.status == .succeeded ? .info : .warning,
        event: "operation-finished:\(operation.kind.rawValue):\(receipt.status.rawValue)",
        operationID: operationID,
        deviceID: operation.deviceID
      )

      emit(
        continuation,
        operationID: operationID,
        deviceID: operation.deviceID,
        phase: .completed,
        state: receipt.status == .succeeded ? .succeeded : .warning,
        message: completionMessage(for: receipt),
        receipt: receipt
      )
      continuation.finish()
    } catch {
      if receiptWasPrepared {
        let cancelled = error is CancellationError
        if cancelled {
          receipt.status = .cancelled
          receipt.messages.append("用户取消了操作；已完成的步骤不会被伪装成回滚")
        } else if receipt.pendingChange != nil
          || !receipt.appliedChanges.isEmpty
          || operation.kind == .cleanStorage
          || operation.kind == .erase
          || operation.kind == .delete
          || operation.kind == .clone
        {
          receipt.status = .partial
          receipt.messages.append("操作中断：\(error.localizedDescription)")
        } else {
          receipt.status = .failed
          receipt.messages.append(error.localizedDescription)
        }

        if mutationWasAuthorized {
          await restoreOriginalPowerStateIfPossible(receipt: &receipt)
        }
        receipt.finishedAt = Date()
        receipt.finalDeviceState = await currentDeviceState(operation.deviceID)
        try? await receiptStore.save(receipt)
        await DiagnosticLogStore.shared.record(
          level: cancelled ? .warning : .error,
          event: cancelled
            ? "operation-cancelled:\(operation.kind.rawValue)"
            : "operation-failed:\(operation.kind.rawValue)",
          operationID: operationID,
          deviceID: operation.deviceID,
          detail: error.localizedDescription
        )

        emit(
          continuation,
          operationID: operationID,
          deviceID: operation.deviceID,
          phase: .completed,
          state: cancelled ? .warning : .failed,
          message: cancelled ? "操作已取消" : error.localizedDescription,
          receipt: receipt
        )
        continuation.finish()
      } else {
        continuation.finish(throwing: error)
      }
    }

    await deviceLock?.release()
  }

  private func executeOptimization(
    profile: OptimizationProfile,
    customDisabledLabels: Set<String>,
    confirmation: ServiceMutationConfirmation,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    let catalog = try requiredCatalog()
    guard !catalog.applicableServices(runtimeVersion: context.runtimeVersion).isEmpty else {
      throw SimulatorWorkspaceError.invalidOperation(
        "尚未验证 \(context.runtimeVersion) 系统运行时，不能修改服务"
      )
    }

    try await ensureBooted(
      context: context,
      receipt: receipt,
      continuation: continuation,
      reason: "读取服务基线"
    )
    let baseline = try await simulator.disabledLabels(for: context.device.id)
    let presentLabels = try await presentServiceLabels(
      context: context,
      catalog: catalog,
      knownDisabledLabels: baseline
    )
    receipt.baselineCapturedAt = Date()
    receipt.baselineDisabledLabels = baseline
    try await receiptStore.save(receipt)

    try await measureMemory(
      timing: .before,
      receipt: &receipt,
      continuation: continuation
    )
    let plan = catalog.plan(
      deviceID: context.device.id,
      runtimeVersion: context.runtimeVersion,
      profile: profile,
      currentDisabledLabels: baseline,
      customDisabledLabels: customDisabledLabels,
      presentLabels: presentLabels
    )
    guard confirmation.changes == Set(plan.changes) else {
      receipt.messages.append("设备服务状态在预览确认后发生变化，未执行任何服务修改")
      try await receiptStore.save(receipt)
      throw SimulatorWorkspaceError.invalidOperation("设备状态已变化，请重新预览并确认优化差异")
    }
    if !plan.unknownDisabledLabels.isEmpty {
      receipt.messages.append(
        "保留 \(plan.unknownDisabledLabels.count) 个非本应用管理的禁用服务"
      )
    }

    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .preparing,
      message: plan.changes.isEmpty
        ? "当前状态已经符合所选方案"
        : "已生成 \(plan.changes.count) 项允许列表差异",
      totalCount: plan.changes.count
    )
    let succeeded = try await applyServiceChanges(
      plan.changes,
      receipt: &receipt,
      continuation: continuation
    )
    try await restartAndVerify(
      succeeded,
      expectedDisabledLabels: plan.desiredDisabledLabels,
      verificationLabels: plan.managedLabels,
      receipt: &receipt,
      continuation: continuation
    )
    try await measureMemory(
      timing: .after,
      receipt: &receipt,
      continuation: continuation
    )
    try await recordMemoryComparison(receipt: &receipt)
    try await returnToOriginalPowerState(
      context: context,
      receipt: &receipt,
      continuation: continuation
    )
  }

  private func executeRestore(
    sourceReceiptID: ReceiptID,
    confirmation: ServiceMutationConfirmation,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    var source = try await receiptStore.receipt(id: sourceReceiptID)
    guard source.deviceID == context.device.id, source.kind == .optimize else {
      throw SimulatorWorkspaceError.invalidOperation("该恢复数据不能用于当前设备恢复")
    }
    if let runtimeIdentifier = source.runtimeIdentifier,
      runtimeIdentifier != context.device.runtimeIdentifier
    {
      throw SimulatorWorkspaceError.invalidOperation("恢复数据与当前设备的系统运行时不一致")
    }
    guard source.baselineCapturedAt != nil else {
      throw SimulatorWorkspaceError.invalidOperation("上次操作在中断前尚未取得服务基线，不能执行恢复")
    }

    try await ensureBooted(
      context: context,
      receipt: receipt,
      continuation: continuation,
      reason: "读取当前服务状态"
    )
    let currentDisabled = try await simulator.disabledLabels(for: context.device.id)
    let catalog = try requiredCatalog()
    if let sourceCatalogVersion = source.serviceCatalogVersion,
      sourceCatalogVersion != catalog.schemaVersion
    {
      receipt.messages.append(
        "恢复数据使用服务目录版本 \(sourceCatalogVersion)，当前版本为 \(catalog.schemaVersion)"
      )
    }
    let presentLabels = try await presentServiceLabels(
      context: context,
      catalog: catalog,
      knownDisabledLabels: currentDisabled
    )
    try await resolvePendingChangeState(in: &source, disabledLabels: currentDisabled)
    receipt.baselineCapturedAt = Date()
    receipt.baselineDisabledLabels = currentDisabled
    try await receiptStore.save(receipt)
    try await measureMemory(timing: .before, receipt: &receipt, continuation: continuation)

    let changes = try restoreChanges(
      source: source,
      runtimeVersion: context.runtimeVersion,
      currentDisabled: currentDisabled,
      presentLabels: presentLabels
    )
    guard confirmation.changes == Set(changes) else {
      receipt.messages.append("恢复差异在预览确认后发生变化，未执行任何服务修改")
      try await receiptStore.save(receipt)
      throw SimulatorWorkspaceError.invalidOperation("恢复项已变化，请重新预览并确认恢复差异")
    }
    let touchedLabels = Set(
      source.appliedChanges.filter(\.succeeded).map { $0.change.label }
    )
    let applicableLabels = Set(
      catalog.applicableServices(runtimeVersion: context.runtimeVersion).map(\.label)
    )
    let unavailableTouchedLabels = touchedLabels.subtracting(applicableLabels)
    if !unavailableTouchedLabels.isEmpty {
      receipt.status = .partial
      receipt.messages.append(
        "当前服务目录无法恢复以下来源标签：\(unavailableTouchedLabels.sorted().joined(separator: ", "))"
      )
      try await receiptStore.save(receipt)
    }
    let protectedBaselineLabels = try blockedRestoreLabels(
      source: source,
      runtimeVersion: context.runtimeVersion
    )
    if !protectedBaselineLabels.isEmpty {
      receipt.status = .partial
      receipt.messages.append(
        "为保护系统可用性，未重新停用关键服务：\(protectedBaselineLabels.joined(separator: ", "))"
      )
      try await receiptStore.save(receipt)
    }
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .preparing,
      message: changes.isEmpty
        ? "当前状态已经与恢复基线一致"
        : "将恢复上次操作实际触及的 \(changes.count) 项服务",
      totalCount: changes.count
    )
    let succeeded = try await applyServiceChanges(
      changes,
      receipt: &receipt,
      continuation: continuation
    )
    try await restartAndVerify(
      succeeded,
      expectedDisabledLabels: source.baselineDisabledLabels,
      verificationLabels: touchedLabels.intersection(applicableLabels),
      receipt: &receipt,
      continuation: continuation
    )
    try await measureMemory(timing: .after, receipt: &receipt, continuation: continuation)
    try await recordMemoryComparison(receipt: &receipt)
    try await returnToOriginalPowerState(
      context: context,
      receipt: &receipt,
      continuation: continuation
    )
    if receipt.status != .partial && unavailableTouchedLabels.isEmpty {
      try await resolveInterruptedReceipt(&source, resolutionReceiptID: receipt.id)
    }
  }

  private func executeVerification(
    sourceReceiptID: ReceiptID,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    var source = try await receiptStore.receipt(id: sourceReceiptID)
    guard source.deviceID == context.device.id, source.kind == .optimize else {
      throw SimulatorWorkspaceError.invalidOperation("该恢复数据不能用于当前设备继续验证")
    }

    try await ensureBooted(
      context: context,
      receipt: receipt,
      continuation: continuation,
      reason: "继续验证服务状态"
    )
    receipt.baselineDisabledLabels = source.baselineDisabledLabels
    receipt.messages.append("验证来源数据：\(source.id.rawValue.uuidString.lowercased())")
    try await receiptStore.save(receipt)

    let provisionalCount =
      source.appliedChanges.filter(\.succeeded).count
      + (source.pendingChange == nil ? 0 : 1)
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .verifying,
      message: provisionalCount == 0
        ? "上次操作未记录已执行变更，正在确认设备状态"
        : "正在只读核对中断前的 \(provisionalCount) 项服务状态",
      totalCount: provisionalCount
    )

    let actualDisabled = try await simulator.disabledLabels(for: context.device.id)
    try await resolvePendingChangeState(in: &source, disabledLabels: actualDisabled)
    let expectedChanges = source.appliedChanges.filter(\.succeeded).map(\.change)
    let mismatches = expectedChanges.filter { change in
      let isDisabled = actualDisabled.contains(change.label)
      return change.transition == .disable ? !isDisabled : isDisabled
    }
    if mismatches.isEmpty {
      receipt.messages.append(
        expectedChanges.isEmpty
          ? "设备可用；中断前没有已记录的服务变更"
          : "中断前已执行的服务状态全部验证一致"
      )
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .succeeded,
        message: "继续验证完成，状态一致",
        completedCount: expectedChanges.count,
        totalCount: expectedChanges.count
      )
    } else {
      receipt.status = .partial
      receipt.messages.append(
        "继续验证不一致：\(mismatches.map(\.label).joined(separator: ", "))"
      )
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .warning,
        message: "有 \(mismatches.count) 项状态与中断前记录不一致",
        completedCount: expectedChanges.count,
        totalCount: expectedChanges.count
      )
    }
    try await receiptStore.save(receipt)
    try await measureMemory(timing: .after, receipt: &receipt, continuation: continuation)
    try await returnToOriginalPowerState(
      context: context,
      receipt: &receipt,
      continuation: continuation
    )
    try await resolveInterruptedReceipt(&source, resolutionReceiptID: receipt.id)
  }

  private func resolveInterruptedReceipt(
    _ source: inout OperationReceipt,
    resolutionReceiptID: ReceiptID
  ) async throws {
    guard source.messages.contains(where: { $0.contains(ReceiptStore.interruptionMarker) })
    else { return }
    source.messages.append(
      "\(ReceiptStore.interruptionResolutionMarker)：\(resolutionReceiptID.rawValue.uuidString.lowercased())"
    )
    try await receiptStore.save(source)
  }

  private func resolvePendingChangeState(
    in source: inout OperationReceipt,
    disabledLabels: Set<String>
  ) async throws {
    guard let pendingChange = source.pendingChange else { return }
    let isDisabled = disabledLabels.contains(pendingChange.label)
    let reachedTarget = pendingChange.transition == .disable ? isDisabled : !isDisabled
    source.appliedChanges.append(
      AppliedChange(
        change: pendingChange,
        succeeded: reachedTarget,
        errorMessage: reachedTarget ? "中断后只读复核确认已生效" : "中断后只读复核确认未生效"
      )
    )
    source.pendingChange = nil
    try await receiptStore.save(source)
  }

  private func executeStorageScan(
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    guard context.device.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "请先关闭模拟器，再重新扫描存储并确认清理范围"
      )
    }
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .scanningStorage,
      message: "正在扫描结构化安全路径"
    )
    let plan = try await storageManager.scan(device: context.device)
    receipt.messages.append(
      "扫描完成：总占用 \(plan.totalBytes) 字节，可安全清理 \(plan.cleanableBytes) 字节"
    )
    receipt.finalDeviceState = context.device.state
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .scanningStorage,
      state: .succeeded,
      message: "已找到 \(plan.categories.filter(\.canClean).count) 个可清理类别"
    )
  }

  private func executeStorageCleanup(
    planID: UUID,
    categoryIDs: Set<String>,
    preserveBootState: Bool,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    guard !categoryIDs.isEmpty else {
      throw SimulatorWorkspaceError.invalidOperation("至少选择一个可清理类别")
    }
    guard context.device.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "请先关闭模拟器，再重新扫描存储并确认清理范围"
      )
    }

    let shutdownDevice = try await simulator.validatedDevice(context.device.id)
    guard shutdownDevice.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "请先关闭模拟器，再重新扫描存储并确认清理范围"
      )
    }
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .cleaningStorage,
      message: "正在复核扫描计划、路径边界和文件身份"
    )
    let cleanupProgress = try await storageManager.clean(
      device: shutdownDevice,
      planID: planID,
      categoryIDs: categoryIDs
    )
    var reclaimed: Int64 = 0
    for try await progress in cleanupProgress {
      switch progress.stage {
      case .pending:
        receipt.pendingStorageCleanupPath = progress.relativePath
        receipt.messages.append("待清理子项：\(progress.relativePath)；删除结果尚未确认")
        try await receiptStore.save(receipt)
        progress.acknowledgePersistence()
      case .completed:
        reclaimed = progress.reclaimedBytes
        receipt.reclaimedBytes = reclaimed
        receipt.completedStorageCleanupItems =
          (receipt.completedStorageCleanupItems ?? [])
          + [
            StorageCleanupEvidence(
              relativePath: progress.relativePath,
              targetRelativePath: progress.targetRelativePath,
              reclaimedBytes: progress.targetReclaimedBytes
            )
          ]
        if receipt.pendingStorageCleanupPath == progress.relativePath {
          receipt.pendingStorageCleanupPath = nil
        }
        receipt.messages.append(
          "已清理子项 \(progress.relativePath)：释放 \(progress.targetReclaimedBytes) 字节"
        )
        try await receiptStore.save(receipt)
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .cleaningStorage,
          message: "已完成 \(progress.completedTargetCount) / \(progress.totalTargetCount) 个清理子项",
          completedCount: progress.completedTargetCount,
          totalCount: progress.totalTargetCount
        )
        progress.acknowledgePersistence()
      }
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    receipt.reclaimedBytes = reclaimed
    try await receiptStore.save(receipt)

    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .verifying,
      message: "正在重新扫描以验证清理结果"
    )
    let verificationDevice = try await simulator.validatedDevice(context.device.id)
    let verificationPlan = try await storageManager.scan(device: verificationDevice)
    receipt.messages.append(
      "实际释放 \(reclaimed) 字节；复扫后仍有 \(verificationPlan.cleanableBytes) 字节可清理"
    )

    if context.device.state == .booted, preserveBootState {
      try await simulator.boot(context.device.id)
      receipt.finalDeviceState = .booted
    } else {
      receipt.finalDeviceState = .shutdown
    }
  }

  private func executeDeviceAction(
    _ operation: SimulatorOperation,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .deviceAction,
      message: deviceActionMessage(operation)
    )

    switch operation {
    case .boot:
      try await simulator.boot(context.device.id)
      receipt.finalDeviceState = .booted
    case .shutdown:
      try await simulator.shutdown(context.device.id)
      receipt.finalDeviceState = .shutdown
    case .openSimulator:
      try await simulator.openSimulator(context.device.id)
      receipt.finalDeviceState = .booted
    case .erase:
      if context.device.state == .booted {
        try await simulator.shutdown(context.device.id)
      }
      receipt.pendingDeviceAction = PendingDeviceAction(kind: .erase)
      try await receiptStore.save(receipt)
      try await simulator.erase(context.device.id)
      receipt.pendingDeviceAction = nil
      try await receiptStore.save(receipt)
      if context.device.state == .booted {
        try await simulator.boot(context.device.id)
        receipt.finalDeviceState = .booted
      } else {
        receipt.finalDeviceState = .shutdown
      }
    case .delete:
      if context.device.state == .booted {
        try await simulator.shutdown(context.device.id)
      }
      receipt.pendingDeviceAction = PendingDeviceAction(kind: .delete)
      try await receiptStore.save(receipt)
      try await simulator.delete(context.device.id)
      receipt.pendingDeviceAction = nil
      try await receiptStore.save(receipt)
      receipt.finalDeviceState = .unavailable
    case .clone(_, let name):
      if context.device.state == .booted {
        try await simulator.shutdown(context.device.id)
      }
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      receipt.pendingDeviceAction = PendingDeviceAction(kind: .clone, cloneName: trimmedName)
      try await receiptStore.save(receipt)
      receipt.clonedDeviceID = try await simulator.clone(context.device.id, name: trimmedName)
      receipt.pendingDeviceAction = nil
      try await receiptStore.save(receipt)
      if context.device.state == .booted {
        try await simulator.boot(context.device.id)
        receipt.finalDeviceState = .booted
      } else {
        receipt.finalDeviceState = .shutdown
      }
    default:
      throw SimulatorWorkspaceError.invalidOperation("不是设备管理操作")
    }
  }

  private func ensureBooted(
    context: DeviceContext,
    receipt: OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation,
    reason: String
  ) async throws {
    guard context.device.state != .booted else { return }
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .preparing,
      message: "临时启动模拟器以\(reason)"
    )
    try await simulator.boot(context.device.id)
  }

  private func applyServiceChanges(
    _ changes: [ServiceChange],
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws -> [ServiceChange] {
    var succeeded: [ServiceChange] = []
    for (index, change) in changes.enumerated() {
      try Task.checkCancellation()
      let stillPresent: Bool
      if change.transition == .enable {
        // 禁用后的 job 通常不再加载；目录与回执共同约束了标签，enable 是幂等恢复。
        stillPresent = true
      } else {
        stillPresent = try await simulator.presentServiceLabels(
          [change.label],
          for: receipt.deviceID
        ).contains(change.label)
      }
      guard stillPresent else {
        receipt.status = .partial
        receipt.appliedChanges.append(
          AppliedChange(
            change: change,
            succeeded: false,
            errorMessage: "服务在执行前已不存在，未修改"
          )
        )
        try await receiptStore.save(receipt)
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .applying,
          state: .warning,
          message: "\(change.serviceName) 在当前系统运行时中已不存在，已跳过",
          completedCount: index + 1,
          totalCount: changes.count
        )
        continue
      }

      receipt.pendingChange = change
      try await receiptStore.save(receipt)

      let simulator = self.simulator
      let deviceID = receipt.deviceID
      let result = await Task.detached(priority: .userInitiated) {
        var commandError: String?
        do {
          try await simulator.setService(
            change.label,
            transition: change.transition,
            deviceID: deviceID
          )
        } catch {
          commandError = error.localizedDescription
        }
        do {
          let disabled = try await simulator.disabledLabels(for: deviceID)
          return AtomicServiceChangeResult(
            commandError: commandError,
            observedDisabled: disabled.contains(change.label),
            observationError: nil
          )
        } catch {
          return AtomicServiceChangeResult(
            commandError: commandError,
            observedDisabled: nil,
            observationError: error.localizedDescription
          )
        }
      }.value

      let targetIsDisabled = change.transition == .disable
      let reachedTarget = result.observedDisabled == targetIsDisabled
      let commandSucceededWithoutObservation =
        result.commandError == nil && result.observedDisabled == nil

      if reachedTarget || commandSucceededWithoutObservation {
        let verificationWarning = result.observationError.map {
          "命令已完成，但即时状态复核失败：\($0)；稍后会在重启后再次验证"
        }
        receipt.appliedChanges.append(
          AppliedChange(
            change: change,
            succeeded: true,
            errorMessage: result.commandError ?? verificationWarning
          )
        )
        receipt.pendingChange = nil
        succeeded.append(change)
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .applying,
          state: result.commandError == nil ? .succeeded : .warning,
          message: result.commandError == nil
            ? "已\(change.transition == .disable ? "停用" : "启用") \(change.serviceName)"
            : "\(change.serviceName) 命令报错，但状态复核确认已生效",
          completedCount: index + 1,
          totalCount: changes.count
        )
      } else if let observedDisabled = result.observedDisabled {
        let observedState = observedDisabled ? "停用" : "启用"
        let errorMessage =
          result.commandError
          ?? "状态复核不一致，当前仍为\(observedState)"
        receipt.status = .partial
        receipt.appliedChanges.append(
          AppliedChange(
            change: change,
            succeeded: false,
            errorMessage: errorMessage
          )
        )
        receipt.pendingChange = nil
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .applying,
          state: .failed,
          message: "\(change.serviceName) 修改失败：\(errorMessage)",
          completedCount: index + 1,
          totalCount: changes.count
        )
      } else {
        receipt.messages.append(
          "服务变更结果未知：\(change.label)；命令错误：\(result.commandError ?? "无")；复核错误：\(result.observationError ?? "无")"
        )
        try await receiptStore.save(receipt)
        throw SimulatorWorkspaceError.invalidOperation(
          "\(change.serviceName) 的命令和状态复核均失败；已保留待确认步骤"
        )
      }
      // 每项结果都立即原子写回，避免崩溃后丢失部分状态。
      try await receiptStore.save(receipt)
      // 用户取消只在当前 launchctl 原子步骤和回执写入完成后生效。
      try Task.checkCancellation()
    }
    return succeeded
  }

  private func restartAndVerify(
    _ changes: [ServiceChange],
    expectedDisabledLabels: Set<String>,
    verificationLabels: Set<String>,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    try Task.checkCancellation()
    if !changes.isEmpty {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .restarting,
        message: "正在重启模拟器以应用服务状态"
      )
      try await simulator.shutdown(receipt.deviceID)
      try await simulator.boot(receipt.deviceID)
    }

    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .verifying,
      message: "正在逐项验证服务状态"
    )
    let actualDisabled = try await simulator.disabledLabels(for: receipt.deviceID)
    let mismatches = verificationLabels.filter { label in
      actualDisabled.contains(label) != expectedDisabledLabels.contains(label)
    }
    if mismatches.isEmpty {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .succeeded,
        message: "全部 \(verificationLabels.count) 项受管服务状态验证一致"
      )
    } else {
      receipt.status = .partial
      receipt.messages.append(
        "验证不一致：\(mismatches.sorted().joined(separator: ", "))"
      )
      try await receiptStore.save(receipt)
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .warning,
        message: "有 \(mismatches.count) 项状态与计划不一致，请重新检查当前状态"
      )
    }
  }

  private enum MemoryTiming {
    case before
    case after
  }

  private func measureMemory(
    timing: MemoryTiming,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    let phase: OperationPhase = timing == .before ? .measuringBefore : .measuringAfter
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: phase,
      message: timing == .before ? "正在记录优化前物理内存" : "正在记录优化后物理内存"
    )
    do {
      try await Task.sleep(for: memoryStabilizationDelay)
      let snapshot = try await memoryInspector.snapshot(for: receipt.deviceID)
      if timing == .before {
        receipt.memoryBefore = snapshot
      } else {
        receipt.memoryAfter = snapshot
      }
      try await receiptStore.save(receipt)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      receipt.messages.append("内存测量不可用：\(error.localizedDescription)")
      try? await receiptStore.save(receipt)
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: phase,
        state: .warning,
        message: "内存测量不可用，但不会阻止服务操作"
      )
    }
  }

  private func recordMemoryComparison(
    receipt: inout OperationReceipt
  ) async throws {
    guard let before = receipt.memoryBefore, let after = receipt.memoryAfter else { return }
    guard before.method == after.method, after.collectedAt >= before.collectedAt else {
      receipt.reclaimedBytes = nil
      receipt.messages.append("内存采样条件不一致，未计算差值")
      try await receiptStore.save(receipt)
      return
    }

    let (difference, overflowed) = before.bytes.subtractingReportingOverflow(after.bytes)
    receipt.reclaimedBytes = overflowed ? nil : difference
    receipt.messages.append(
      "内存对比条件：同一设备处于已启动状态，前后采用 \(before.method) 并等待相同稳定时间"
    )
    try await receiptStore.save(receipt)
  }

  private func returnToOriginalPowerState(
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    if receipt.originalDeviceState == .shutdown {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .finalizing,
        message: "正在恢复操作前的关机状态"
      )
      try await simulator.shutdown(context.device.id)
      receipt.finalDeviceState = .shutdown
    } else if receipt.originalDeviceState == .booted {
      receipt.finalDeviceState = .booted
    } else {
      throw SimulatorWorkspaceError.invalidOperation("恢复数据缺少稳定的原始电源状态")
    }
  }

  private func restoreOriginalPowerStateIfPossible(
    receipt: inout OperationReceipt
  ) async {
    guard receipt.kind != .delete, receipt.shouldRestoreOriginalDeviceState != false else {
      return
    }
    do {
      if receipt.originalDeviceState == .shutdown {
        try await shutdownShielded(receipt.deviceID)
        receipt.messages.append("异常后已恢复操作前的关机状态")
      } else if receipt.originalDeviceState == .booted {
        try await bootShielded(receipt.deviceID)
        receipt.messages.append("异常后已恢复操作前的启动状态")
      }
    } catch {
      receipt.messages.append("恢复原电源状态失败：\(error.localizedDescription)")
    }
  }

  private func currentDeviceState(_ deviceID: SimulatorID) async -> SimulatorState? {
    guard let inventory = try? await simulator.inventory() else { return nil }
    return inventory.devices.first(where: { $0.id == deviceID })?.state ?? .unavailable
  }

  private func completionMessage(for receipt: OperationReceipt) -> String {
    switch receipt.status {
    case .succeeded: "操作完成并已验证"
    case .partial: "操作部分完成，请确认当前状态"
    case .failed: "操作失败，请查看详细信息"
    case .cancelled: "操作已取消，已保留完成步骤"
    case .prepared, .running: "操作状态已保存"
    }
  }

  private func deviceActionMessage(_ operation: SimulatorOperation) -> String {
    switch operation {
    case .boot: "正在启动模拟器"
    case .shutdown: "正在关闭模拟器"
    case .openSimulator: "正在打开 Apple 模拟器"
    case .erase: "正在抹掉内容与设置"
    case .delete: "正在永久删除设备"
    case .clone: "正在克隆设备"
    default: "正在执行设备操作"
    }
  }

  private func emit(
    _ continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation,
    operationID: ReceiptID,
    deviceID: SimulatorID,
    phase: OperationPhase,
    state: OperationEventState = .running,
    message: String,
    completedCount: Int? = nil,
    totalCount: Int? = nil,
    receipt: OperationReceipt? = nil
  ) {
    continuation.yield(
      OperationEvent(
        operationID: operationID,
        deviceID: deviceID,
        phase: phase,
        state: state,
        message: message,
        completedCount: completedCount,
        totalCount: totalCount,
        receipt: receipt
      )
    )
  }
}

private struct AtomicServiceChangeResult: Sendable {
  let commandError: String?
  let observedDisabled: Bool?
  let observationError: String?
}
