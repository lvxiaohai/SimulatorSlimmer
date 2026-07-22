import Foundation

public actor SimulatorWorkspace: SimulatorWorkspaceClient {
  private let simulator: any SimulatorControlling
  private let memoryInspector: any MemoryInspecting
  private let receiptStore: any ReceiptStoring
  private let storageManager: any StorageManaging
  private let operationGate: OperationGate
  private let catalog: ServiceCatalog?
  private let catalogLoadError: String?
  private var didRecoverInterruptedReceipts = false

  public init() {
    let runner = FoundationCommandRunner()
    self.simulator = SimctlAdapter(runner: runner)
    self.memoryInspector = LibprocMemoryInspector(runner: runner)
    self.receiptStore = ReceiptStore()
    self.storageManager = StorageManager()
    self.operationGate = OperationGate()
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
    operationGate: OperationGate,
    catalog: ServiceCatalog
  ) {
    self.simulator = simulator
    self.memoryInspector = memoryInspector
    self.receiptStore = receiptStore
    self.storageManager = storageManager
    self.operationGate = operationGate
    self.catalog = catalog
    self.catalogLoadError = nil
  }

  public func overview() async throws -> WorkspaceOverview {
    try await recoverInterruptedReceiptsIfNeeded()
    async let inventory = simulator.inventory()
    async let receipts = receiptStore.allReceipts()
    let (resolvedInventory, resolvedReceipts) = try await (inventory, receipts)
    let pending = resolvedReceipts.filter {
      $0.status == .prepared || $0.status == .running
    }
    return WorkspaceOverview(
      inventory: resolvedInventory,
      recentReceipts: Array(resolvedReceipts.prefix(200)),
      pendingReceipts: pending
    )
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
        memoryError: context.device.availabilityError ?? "该 Runtime 当前不可用"
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
        memoryError: "尚未验证 \(context.runtimeVersion) Runtime 的服务规则"
      )
    }

    let currentDisabled: Set<String>
    var memory: MemorySnapshot?
    var memoryError: String?
    if context.device.state == .booted {
      currentDisabled = try await simulator.disabledLabels(for: deviceID)
      do {
        memory = try await memoryInspector.snapshot(for: deviceID)
      } catch {
        memoryError = error.localizedDescription
      }
    } else {
      currentDisabled = []
      memoryError = "启动模拟器后可读取实时物理内存；执行优化时会临时启动并恢复电源状态"
    }

    var plans: [OptimizationProfile: OptimizationPlan] = [:]
    for profile in OptimizationProfile.allCases where profile != .custom {
      plans[profile] = catalog.plan(
        deviceID: deviceID,
        runtimeVersion: context.runtimeVersion,
        profile: profile,
        currentDisabledLabels: currentDisabled
      )
    }
    plans[.custom] = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: context.runtimeVersion,
      profile: .custom,
      currentDisabledLabels: currentDisabled,
      customDisabledLabels: currentDisabled
    )

    return DeviceSnapshot(
      device: context.device,
      memory: memory,
      services: catalog.serviceStates(
        runtimeVersion: context.runtimeVersion,
        disabledLabels: currentDisabled
      ),
      categories: catalog.categories,
      plans: plans,
      latestStoragePlan: latestStoragePlan,
      memoryError: memoryError
    )
  }

  public func preview(_ operation: SimulatorOperation) async throws -> OperationPreview {
    try Task.checkCancellation()
    let context = try await deviceContext(operation.deviceID)
    guard context.device.isAvailable else {
      throw SimulatorWorkspaceError.deviceUnavailable(
        context.device.availabilityError ?? "该模拟器当前不可用"
      )
    }

    switch operation {
    case .optimize(let deviceID, let profile, let customDisabledLabels):
      let catalog = try requiredCatalog()
      guard !catalog.applicableServices(runtimeVersion: context.runtimeVersion).isEmpty else {
        throw SimulatorWorkspaceError.invalidOperation(
          "尚未验证 \(context.runtimeVersion) Runtime，不能修改服务"
        )
      }
      let disabled = try await knownDisabledLabels(for: context.device)
      let plan = catalog.plan(
        deviceID: deviceID,
        runtimeVersion: context.runtimeVersion,
        profile: profile,
        currentDisabledLabels: disabled ?? [],
        customDisabledLabels: customDisabledLabels
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
          : "将按严格允许列表执行 \(plan.changes.count) 项差异，随后重启、验证并保存可恢复回执。",
        serviceChanges: plan.changes,
        warnings: warnings,
        requiresConfirmation: true
      )

    case .restore(_, let receiptID):
      let source = try await receiptStore.receipt(id: receiptID)
      guard source.deviceID == operation.deviceID, source.kind == .optimize else {
        throw SimulatorWorkspaceError.invalidOperation("该回执不能用于当前设备恢复")
      }
      let disabled = try await knownDisabledLabels(for: context.device)
      let changes = try restoreChanges(
        source: source,
        runtimeVersion: context.runtimeVersion,
        currentDisabled: disabled
      )
      var warnings = powerStateWarnings(context.device, action: "恢复")
      let protectedBaselineLabels = try blockedRestoreLabels(
        source: source,
        runtimeVersion: context.runtimeVersion
      )
      if !protectedBaselineLabels.isEmpty {
        warnings.append(
          "回执基线中的 \(protectedBaselineLabels.count) 个关键服务不会被重新停用"
        )
      }
      return OperationPreview(
        operation: operation,
        title: "恢复 \(context.device.name)",
        summary: changes.isEmpty
          ? "当前服务状态已经与该回执基线一致。"
          : "只会恢复该回执实际触及的允许列表服务，共 \(changes.count) 项。",
        serviceChanges: changes,
        warnings: warnings,
        requiresConfirmation: true
      )

    case .scanStorage:
      return OperationPreview(
        operation: operation,
        title: "扫描 \(context.device.name) 的存储",
        summary: "只读取结构化安全路径并汇总空间，不会删除任何文件。"
      )

    case .cleanStorage(_, let planID, let categoryIDs, let preserveBootState):
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
      var warnings = ["删除后无法通过本应用撤销；缓存和临时文件由系统按需重建"]
      if context.device.state == .booted {
        warnings.append(
          preserveBootState
            ? "清理时会暂时关机，完成后重新启动"
            : "清理时会关闭模拟器并保持关机"
        )
      }
      return OperationPreview(
        operation: operation,
        title: "清理 \(context.device.name) 的存储",
        summary: "将清理 \(selected.count) 个高置信类别，并在删除前再次验证路径与文件身份。",
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
        title: "在 Simulator 中打开",
        summary: "启动设备并在 Apple Simulator 中切换到 \(context.device.name)。"
      )
    case .erase:
      return .init(
        operation: operation,
        title: "抹掉 \(context.device.name)",
        summary: "删除该设备内的 App、账户、设置与测试数据，设备本身仍会保留。",
        warnings: ["此操作不可撤销"],
        requiresConfirmation: true,
        confirmationPhrase: context.device.name
      )
    case .delete:
      return .init(
        operation: operation,
        title: "删除 \(context.device.name)",
        summary: "永久删除该模拟器设备及其全部本地数据。",
        warnings: ["此操作不可撤销，删除后设备将从 Xcode 与 Simulator 消失"],
        requiresConfirmation: true,
        confirmationPhrase: context.device.name
      )
    case .clone(_, let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw SimulatorWorkspaceError.invalidOperation("请输入克隆设备名称")
      }
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

  private func knownDisabledLabels(for device: SimulatorDevice) async throws -> Set<String>? {
    guard device.state == .booted else { return nil }
    return try await simulator.disabledLabels(for: device.id)
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
    _ = try await receiptStore.recoverInterruptedReceipts()
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

  private func restoreChanges(
    source: OperationReceipt,
    runtimeVersion: String,
    currentDisabled: Set<String>?
  ) throws -> [ServiceChange] {
    let catalog = try requiredCatalog()
    let applicable = catalog.applicableServices(runtimeVersion: runtimeVersion)
    let servicesByLabel = Dictionary(uniqueKeysWithValues: applicable.map { ($0.label, $0) })
    let touchedLabels = Set(
      source.appliedChanges.filter(\.succeeded).map { $0.change.label }
    )
    var changes: [ServiceChange] = []

    for label in touchedLabels.sorted() {
      guard let service = servicesByLabel[label] else { continue }
      let shouldBeDisabled = source.baselineDisabledLabels.contains(label)
      if shouldBeDisabled && (service.alwaysEnabled || service.risk == .protected) {
        continue
      }
      if let currentDisabled,
        currentDisabled.contains(label) == shouldBeDisabled
      {
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
    let touchedLabels = Set(
      source.appliedChanges.filter(\.succeeded).map { $0.change.label }
    )
    return source.baselineDisabledLabels
      .intersection(touchedLabels)
      .intersection(protectedLabels)
      .sorted()
  }

  private struct DeviceContext: Sendable {
    let device: SimulatorDevice
    let runtimeVersion: String
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

    do {
      deviceLock = try await operationGate.acquire(for: operation.deviceID)
      let context = try await deviceContext(operation.deviceID)
      guard context.device.isAvailable else {
        throw SimulatorWorkspaceError.deviceUnavailable(
          context.device.availabilityError ?? "该模拟器当前不可用"
        )
      }

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
        originalDeviceState: context.device.state
      )
      receiptWasPrepared = true

      // 任何可能修改模拟器的命令都必须晚于这次原子保存。
      try await receiptStore.save(receipt)
      receipt.status = .running
      try await receiptStore.save(receipt)

      switch operation {
      case .optimize(_, let profile, let customDisabledLabels):
        try await executeOptimization(
          profile: profile,
          customDisabledLabels: customDisabledLabels,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .restore(_, let sourceReceiptID):
        try await executeRestore(
          sourceReceiptID: sourceReceiptID,
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
        try await executeStorageCleanup(
          planID: planID,
          categoryIDs: categoryIDs,
          preserveBootState: preserveBootState,
          context: context,
          receipt: &receipt,
          continuation: continuation
        )
      case .boot, .shutdown, .erase, .delete, .clone, .openSimulator:
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
        } else if !receipt.appliedChanges.isEmpty
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

        await restoreOriginalPowerStateIfPossible(receipt: &receipt)
        receipt.finishedAt = Date()
        receipt.finalDeviceState = await currentDeviceState(operation.deviceID)
        try? await receiptStore.save(receipt)

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
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    let catalog = try requiredCatalog()
    guard !catalog.applicableServices(runtimeVersion: context.runtimeVersion).isEmpty else {
      throw SimulatorWorkspaceError.invalidOperation(
        "尚未验证 \(context.runtimeVersion) Runtime，不能修改服务"
      )
    }

    try await ensureBooted(
      context: context,
      receipt: receipt,
      continuation: continuation,
      reason: "读取服务基线"
    )
    let baseline = try await simulator.disabledLabels(for: context.device.id)
    receipt.baselineDisabledLabels = baseline
    try await receiptStore.save(receipt)

    await measureMemory(
      timing: .before,
      receipt: &receipt,
      continuation: continuation
    )
    let plan = catalog.plan(
      deviceID: context.device.id,
      runtimeVersion: context.runtimeVersion,
      profile: profile,
      currentDisabledLabels: baseline,
      customDisabledLabels: customDisabledLabels
    )
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
      receipt: &receipt,
      continuation: continuation
    )
    await measureMemory(
      timing: .after,
      receipt: &receipt,
      continuation: continuation
    )
    try await returnToOriginalPowerState(
      context: context,
      receipt: &receipt,
      continuation: continuation
    )
  }

  private func executeRestore(
    sourceReceiptID: ReceiptID,
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    let source = try await receiptStore.receipt(id: sourceReceiptID)
    guard source.deviceID == context.device.id, source.kind == .optimize else {
      throw SimulatorWorkspaceError.invalidOperation("该回执不能用于当前设备恢复")
    }

    try await ensureBooted(
      context: context,
      receipt: receipt,
      continuation: continuation,
      reason: "读取当前服务状态"
    )
    let currentDisabled = try await simulator.disabledLabels(for: context.device.id)
    receipt.baselineDisabledLabels = currentDisabled
    try await receiptStore.save(receipt)
    await measureMemory(timing: .before, receipt: &receipt, continuation: continuation)

    let changes = try restoreChanges(
      source: source,
      runtimeVersion: context.runtimeVersion,
      currentDisabled: currentDisabled
    )
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
        ? "当前状态已经与回执基线一致"
        : "将恢复回执实际触及的 \(changes.count) 项服务",
      totalCount: changes.count
    )
    let succeeded = try await applyServiceChanges(
      changes,
      receipt: &receipt,
      continuation: continuation
    )
    try await restartAndVerify(
      succeeded,
      receipt: &receipt,
      continuation: continuation
    )
    await measureMemory(timing: .after, receipt: &receipt, continuation: continuation)
    try await returnToOriginalPowerState(
      context: context,
      receipt: &receipt,
      continuation: continuation
    )
  }

  private func executeStorageScan(
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
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

    if context.device.state == .booted {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .preparing,
        message: "正在关闭模拟器以安全清理文件"
      )
      try await simulator.shutdown(context.device.id)
    }

    let shutdownDevice = try await simulator.validatedDevice(context.device.id)
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .cleaningStorage,
      message: "正在复核扫描计划、路径边界和文件身份"
    )
    let reclaimed = try await storageManager.clean(
      device: shutdownDevice,
      planID: planID,
      categoryIDs: categoryIDs
    )
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
      try await simulator.erase(context.device.id)
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
      try await simulator.delete(context.device.id)
      receipt.finalDeviceState = .unavailable
    case .clone(_, let name):
      if context.device.state == .booted {
        try await simulator.shutdown(context.device.id)
      }
      receipt.clonedDeviceID = try await simulator.clone(context.device.id, name: name)
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
      do {
        try await simulator.setService(
          change.label,
          transition: change.transition,
          deviceID: receipt.deviceID
        )
        receipt.appliedChanges.append(AppliedChange(change: change, succeeded: true))
        succeeded.append(change)
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .applying,
          state: .succeeded,
          message: "已\(change.transition == .disable ? "停用" : "启用") \(change.serviceName)",
          completedCount: index + 1,
          totalCount: changes.count
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        receipt.status = .partial
        receipt.appliedChanges.append(
          AppliedChange(
            change: change,
            succeeded: false,
            errorMessage: error.localizedDescription
          )
        )
        emit(
          continuation,
          operationID: receipt.id,
          deviceID: receipt.deviceID,
          phase: .applying,
          state: .failed,
          message: "\(change.serviceName) 修改失败：\(error.localizedDescription)",
          completedCount: index + 1,
          totalCount: changes.count
        )
      }
      // 每项结果都立即原子写回，避免崩溃后丢失部分状态。
      try await receiptStore.save(receipt)
    }
    return succeeded
  }

  private func restartAndVerify(
    _ changes: [ServiceChange],
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    guard !changes.isEmpty else { return }
    try Task.checkCancellation()
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .restarting,
      message: "正在重启模拟器以应用服务状态"
    )
    try await simulator.shutdown(receipt.deviceID)
    try await simulator.boot(receipt.deviceID)

    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: .verifying,
      message: "正在逐项验证服务状态"
    )
    let actualDisabled = try await simulator.disabledLabels(for: receipt.deviceID)
    let mismatches = changes.filter { change in
      let isDisabled = actualDisabled.contains(change.label)
      return change.transition == .disable ? !isDisabled : isDisabled
    }
    if mismatches.isEmpty {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .succeeded,
        message: "全部 \(changes.count) 项服务状态验证一致"
      )
    } else {
      receipt.status = .partial
      receipt.messages.append(
        "验证不一致：\(mismatches.map(\.label).joined(separator: ", "))"
      )
      try await receiptStore.save(receipt)
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .verifying,
        state: .warning,
        message: "有 \(mismatches.count) 项状态与计划不一致，请查看回执"
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
  ) async {
    let phase: OperationPhase = timing == .before ? .measuringBefore : .measuringAfter
    emit(
      continuation,
      operationID: receipt.id,
      deviceID: receipt.deviceID,
      phase: phase,
      message: timing == .before ? "正在记录优化前物理内存" : "正在记录优化后物理内存"
    )
    do {
      let snapshot = try await memoryInspector.snapshot(for: receipt.deviceID)
      if timing == .before {
        receipt.memoryBefore = snapshot
      } else {
        receipt.memoryAfter = snapshot
      }
      try await receiptStore.save(receipt)
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

  private func returnToOriginalPowerState(
    context: DeviceContext,
    receipt: inout OperationReceipt,
    continuation: AsyncThrowingStream<OperationEvent, Error>.Continuation
  ) async throws {
    if context.device.state == .shutdown {
      emit(
        continuation,
        operationID: receipt.id,
        deviceID: receipt.deviceID,
        phase: .finalizing,
        message: "正在恢复操作前的关机状态"
      )
      try await simulator.shutdown(context.device.id)
      receipt.finalDeviceState = .shutdown
    } else {
      receipt.finalDeviceState = .booted
    }
  }

  private func restoreOriginalPowerStateIfPossible(
    receipt: inout OperationReceipt
  ) async {
    guard receipt.kind != .delete else { return }
    do {
      let current = await currentDeviceState(receipt.deviceID)
      if receipt.originalDeviceState == .shutdown, current == .booted {
        try await simulator.shutdown(receipt.deviceID)
        receipt.messages.append("异常后已恢复操作前的关机状态")
      } else if receipt.originalDeviceState == .booted, current == .shutdown {
        try await simulator.boot(receipt.deviceID)
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
    case .partial: "操作部分完成，请查看回执"
    case .failed: "操作失败，请查看详细信息"
    case .cancelled: "操作已取消，已保留完成步骤"
    case .prepared, .running: "操作状态已保存"
    }
  }

  private func deviceActionMessage(_ operation: SimulatorOperation) -> String {
    switch operation {
    case .boot: "正在启动模拟器"
    case .shutdown: "正在关闭模拟器"
    case .openSimulator: "正在打开 Apple Simulator"
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
