import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("工作区事务行为")
struct SimulatorWorkspaceBehaviorTests {
  @Test("菜单栏快照只返回已启动设备并采集内存")
  func menuBarSnapshotOnlyIncludesBootedDevices() async throws {
    let booted = makeWorkspaceDevice(
      id: "01010101-0202-4303-8404-050505050505",
      state: .booted
    )
    let shutdown = makeWorkspaceDevice(
      id: "11111111-1212-4313-8414-151515151515",
      state: .shutdown
    )
    let workspace = makeWorkspace(
      simulator: BatchWorkspaceSimulatorSpy(devices: [shutdown, booted]),
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: []
    )

    let snapshot = try await workspace.menuBarSnapshot()
    let memory = try #require(snapshot.devices.first?.memory)

    #expect(snapshot.devices.map(\.device.id) == [booted.id])
    #expect(memory.bytes == Int64(128 * 1_024 * 1_024))
    #expect(snapshot.devices.first?.memoryError == nil)
  }

  @Test("菜单栏内存采集失败时仍保留已启动设备")
  func menuBarSnapshotKeepsDeviceWhenMemoryFails() async throws {
    let device = makeWorkspaceDevice(
      id: "21212121-2222-4323-8424-252525252525",
      state: .booted
    )
    let workspace = makeWorkspace(
      simulator: WorkspaceSimulatorSpy(device: device),
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [],
      memoryInspector: WorkspaceFailingMemoryInspector()
    )

    let snapshot = try await workspace.menuBarSnapshot()

    #expect(snapshot.devices.map(\.device.id) == [device.id])
    #expect(snapshot.devices.first?.memory == nil)
    #expect(snapshot.devices.first?.memoryError == "模拟失败")
  }

  @Test("显示模拟器直接执行且不创建操作回执")
  func showingSimulatorSkipsOperationTransaction() async throws {
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "10101010-2020-4030-8040-505050505050",
        state: .booted
      )
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )

    try await workspace.showSimulator(await simulator.deviceID)

    #expect(await simulator.mutatingCommands() == ["open"])
    #expect(try await receiptStore.allReceipts().isEmpty)
    #expect(await simulator.servicePresenceProbeCount() == 0)
  }

  @Test("显示模拟器拒绝在轻量路径中启动关机设备")
  func showingSimulatorRequiresBootedDevice() async throws {
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "11111111-3030-4040-8050-606060606060",
        state: .shutdown
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: []
    )

    await #expect(throws: SimulatorWorkspaceError.self) {
      try await workspace.showSimulator(await simulator.deviceID)
    }
    #expect(await simulator.mutatingCommands().isEmpty)
  }

  @Test("首次保存回执失败时不执行任何设备变更")
  func receiptFailurePreventsMutation() async throws {
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "11111111-2222-4333-8444-555555555555",
        state: .shutdown
      )
    )
    let receiptStore = WorkspaceReceiptStoreSpy(failAllSaves: true)
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )

    let events = try await collect(
      await workspace.perform(.boot(deviceID: await simulator.deviceID))
    )

    #expect(await simulator.mutatingCommands().isEmpty)
    let finalReceipt = try #require(events.last?.receipt)
    #expect(finalReceipt.status == .failed)
    #expect(events.last?.state == .failed)
  }

  @Test("单项服务失败时记录并跳过，其他变更继续完成")
  func serviceFailureIsSkippedWithoutFailingOperation() async throws {
    let alpha = makeWorkspaceService(id: "alpha", label: "com.test.alpha")
    let beta = makeWorkspaceService(id: "beta", label: "com.test.beta")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "22222222-3333-4444-8555-666666666666",
        state: .booted
      ),
      failingServiceLabels: [beta.label]
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [alpha, beta]
    )

    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    let events = try await confirmedCollect(operation, using: workspace)

    let finalReceipt = try #require(events.last?.receipt)
    #expect(finalReceipt.status == .succeeded)
    #expect(finalReceipt.appliedChanges.count == 2)
    #expect(
      finalReceipt.appliedChanges.first { $0.change.label == alpha.label }?.succeeded
        == true
    )
    #expect(
      finalReceipt.appliedChanges.first { $0.change.label == beta.label }?.succeeded
        == false
    )
    #expect(await simulator.disabledServiceLabels() == [alpha.label])
    #expect(events.contains { $0.phase == .applying && $0.state == .warning })
    #expect(events.last?.state == .succeeded)
  }

  @Test("恢复只操作源回执中成功触及的服务")
  func restoreTouchesOnlySuccessfullyAppliedReceiptLabels() async throws {
    let alpha = makeWorkspaceService(id: "alpha", label: "com.test.alpha")
    let beta = makeWorkspaceService(id: "beta", label: "com.test.beta")
    let gamma = makeWorkspaceService(id: "gamma", label: "com.test.gamma")
    let device = makeWorkspaceDevice(
      id: "33333333-4444-4555-8666-777777777777",
      state: .booted
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [alpha.label, beta.label, gamma.label]
    )
    let sourceReceipt = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .partial,
      originalDeviceState: .booted,
      baselineCapturedAt: Date(),
      baselineDisabledLabels: [],
      appliedChanges: [
        AppliedChange(
          change: serviceChange(for: alpha, transition: .disable),
          succeeded: true
        ),
        AppliedChange(
          change: serviceChange(for: beta, transition: .disable),
          succeeded: false,
          errorMessage: "模拟失败"
        ),
      ]
    )
    let receiptStore = WorkspaceReceiptStoreSpy(seed: [sourceReceipt])
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [alpha, beta, gamma]
    )

    let operation = SimulatorOperation.restore(
      deviceID: device.id,
      receiptID: sourceReceipt.id
    )
    let events = try await confirmedCollect(operation, using: workspace)

    let serviceCommands = await simulator.serviceCommands()
    #expect(serviceCommands.count == 1)
    #expect(serviceCommands.first?.label == alpha.label)
    #expect(serviceCommands.first?.transition == "enable")
    #expect(await simulator.disabledServiceLabels() == [beta.label, gamma.label])
    #expect(events.last?.receipt?.status == .succeeded)
  }

  @Test("相同采样条件会记录真实内存差值和比较说明")
  func comparableMemorySnapshotsProduceDifference() async throws {
    let service = makeWorkspaceService(id: "memory", label: "com.test.memory")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "44444444-5555-4666-8777-888888888888",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service],
      memoryInspector: WorkspaceMemorySequenceStub(
        snapshots: [
          MemorySnapshot(bytes: 512 * 1_024 * 1_024, processCount: 8),
          MemorySnapshot(bytes: 320 * 1_024 * 1_024, processCount: 6),
        ]
      )
    )

    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    let events = try await confirmedCollect(operation, using: workspace)

    let receipt = try #require(events.last?.receipt)
    let reclaimedBytes = try #require(receipt.reclaimedBytes)
    #expect(reclaimedBytes == Int64(192 * 1_024 * 1_024))
    #expect(receipt.messages.contains { $0.contains("内存对比条件") })
  }

  @Test("应用内存采集失败时仍返回应用清单")
  func applicationMemoryFailureKeepsApplicationCatalog() async throws {
    let device = makeWorkspaceDevice(
      id: "45454545-5656-4787-8989-909090909090",
      state: .booted
    )
    let catalog = SimulatorApplicationCatalog(
      runner: WorkspaceApplicationCatalogRunner(
        output: """
          {
            "com.example.demo" = {
              ApplicationType = User;
              Bundle = "file:///tmp/SimulatorSlimmer-Demo.app/";
              CFBundleDisplayName = "演示应用";
              CFBundleIdentifier = "com.example.demo";
            };
          }
          """
      )
    )
    let workspace = makeWorkspace(
      simulator: WorkspaceSimulatorSpy(device: device),
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [],
      memoryInspector: WorkspaceFailingApplicationMemoryInspector(),
      applicationCatalog: catalog
    )

    let result = try await workspace.applications(for: device.id)

    #expect(result.applications.map(\.bundleIdentifier) == ["com.example.demo"])
    #expect(result.memoryByBundleIdentifier.isEmpty)
    #expect(result.memoryError == "模拟失败")
  }

  @Test("存储清理每完成一个目标都会持久化进度")
  func storageCleanupPersistsEachCompletedTarget() async throws {
    let device = makeWorkspaceDevice(
      id: "45454545-5656-4787-8989-909090909090",
      state: .shutdown
    )
    let simulator = WorkspaceSimulatorSpy(device: device)
    let receiptStore = WorkspaceReceiptStoreSpy()
    let planID = UUID()
    let plan = StoragePlan(
      id: planID,
      deviceID: device.id,
      totalBytes: 3_072,
      cleanableBytes: 3_072,
      categories: [
        StorageCategorySummary(
          id: "cache",
          name: "缓存",
          summary: "缓存",
          consequence: "可重建",
          recovery: "自动",
          risk: .low,
          isDefaultSelected: true,
          canClean: true,
          bytes: 3_072,
          targetCount: 2
        )
      ],
      items: [StorageItemSummary(categoryID: "cache", relativePath: "Library/Caches", bytes: 3_072)]
    )
    let storageManager = WorkspaceStorageManagerStub(
      latestPlan: plan,
      cleanupProgress: [
        StorageCleanupProgress(
          stage: .pending,
          relativePath: "Library/Caches/a.cache",
          targetRelativePath: "Library/Caches",
          targetReclaimedBytes: 0,
          reclaimedBytes: 0,
          completedTargetCount: 0,
          totalTargetCount: 2
        ),
        StorageCleanupProgress(
          relativePath: "Library/Caches/a.cache",
          targetRelativePath: "Library/Caches",
          targetReclaimedBytes: 1_024,
          reclaimedBytes: 1_024,
          completedTargetCount: 1,
          totalTargetCount: 2
        ),
        StorageCleanupProgress(
          stage: .pending,
          relativePath: "Library/Caches/b.cache",
          targetRelativePath: "Library/Caches",
          targetReclaimedBytes: 0,
          reclaimedBytes: 1_024,
          completedTargetCount: 1,
          totalTargetCount: 2
        ),
        StorageCleanupProgress(
          relativePath: "Library/Caches/b.cache",
          targetRelativePath: "Library/Caches",
          targetReclaimedBytes: 2_048,
          reclaimedBytes: 3_072,
          completedTargetCount: 2,
          totalTargetCount: 2
        ),
      ]
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [],
      storageManager: storageManager
    )

    let operation = SimulatorOperation.cleanStorage(
      deviceID: device.id,
      planID: planID,
      categoryIDs: ["cache"],
      preserveBootState: true
    )
    _ = try await workspace.preview(operation)
    let events = try await collect(await workspace.perform(operation))
    let finalReceipt = try #require(events.last?.receipt)
    let versions = await receiptStore.savedVersions(for: finalReceipt.id)

    #expect(finalReceipt.reclaimedBytes == 3_072)
    #expect(
      versions.contains {
        $0.reclaimedBytes == 1_024
          && $0.completedStorageCleanupItems?.count == 1
      }
    )
    #expect(
      versions.contains {
        $0.reclaimedBytes == 3_072
          && $0.completedStorageCleanupItems?.count == 2
      }
    )
    #expect(finalReceipt.pendingStorageCleanupPath == nil)
    #expect(
      events.contains {
        $0.phase == .cleaningStorage && $0.completedCount == 1 && $0.totalCount == 2
      }
    )
  }

  @Test("高风险设备操作缺少确认或输入漂移时拒绝修改")
  func destructiveDeviceActionsRequireExactConfirmation() async throws {
    let device = makeWorkspaceDevice(
      id: "A1A1A1A1-B2B2-43C3-84D4-E5E5E5E5E5E5",
      state: .booted
    )
    for operation in [
      SimulatorOperation.erase(deviceID: device.id),
      .delete(deviceID: device.id),
      .clone(deviceID: device.id, name: "副本一"),
    ] {
      let simulator = WorkspaceSimulatorSpy(device: device)
      let workspace = makeWorkspace(
        simulator: simulator,
        receiptStore: WorkspaceReceiptStoreSpy(),
        services: []
      )
      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await collect(await workspace.perform(operation))
      }
      #expect(await simulator.mutatingCommands().isEmpty)
    }

    let simulator = WorkspaceSimulatorSpy(device: device)
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: []
    )
    _ = try await workspace.preview(.clone(deviceID: device.id, name: "副本一"))
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(
        await workspace.perform(.clone(deviceID: device.id, name: "副本二"))
      )
    }
    #expect(await simulator.mutatingCommands().isEmpty)

    let receiptStore = WorkspaceReceiptStoreSpy()
    let confirmedSimulator = WorkspaceSimulatorSpy(device: device)
    let confirmedWorkspace = makeWorkspace(
      simulator: confirmedSimulator,
      receiptStore: receiptStore,
      services: []
    )
    let confirmedClone = SimulatorOperation.clone(deviceID: device.id, name: "  可追踪副本  ")
    _ = try await confirmedWorkspace.preview(confirmedClone)
    let cloneEvents = try await collect(await confirmedWorkspace.perform(confirmedClone))
    let cloneReceipt = try #require(cloneEvents.last?.receipt)
    let versions = await receiptStore.savedVersions(for: cloneReceipt.id)
    #expect(cloneReceipt.input?.cloneName == "可追踪副本")
    #expect(cloneReceipt.pendingDeviceAction == nil)
    #expect(cloneReceipt.clonedDeviceID != nil)
    #expect(
      versions.contains {
        $0.pendingDeviceAction?.kind == .clone
          && $0.pendingDeviceAction?.cloneName == "可追踪副本"
      }
    )
  }

  @Test("非法克隆名称在回执和设备命令前拒绝")
  func invalidCloneNamesAreRejectedBeforeMutation() async throws {
    let device = makeWorkspaceDevice(
      id: "A2A2A2A2-B3B3-44C4-85D5-E6E6E6E6E6E6",
      state: .booted
    )
    for invalidName in [String(repeating: "a", count: 129), "非法\n名称"] {
      let simulator = WorkspaceSimulatorSpy(device: device)
      let receiptStore = WorkspaceReceiptStoreSpy()
      let workspace = makeWorkspace(
        simulator: simulator,
        receiptStore: receiptStore,
        services: []
      )
      let operation = SimulatorOperation.clone(deviceID: device.id, name: invalidName)

      await #expect(throws: SimulatorWorkspaceError.self) {
        _ = try await workspace.preview(operation)
      }
      do {
        _ = try await collect(await workspace.perform(operation))
        Issue.record("非法克隆名称不应进入执行流程")
      } catch SimulatorWorkspaceError.invalidOperation(let message) {
        #expect(message.contains("克隆名称"))
      } catch {
        Issue.record("收到错误类型不符合预期：\(error)")
      }
      #expect(await receiptStore.receiptsSnapshot().isEmpty)
      #expect(await simulator.mutatingCommands().isEmpty)
    }
  }

  @Test("存储清理确认绑定计划、类别和电源策略")
  func storageCleanupRequiresExactConfirmation() async throws {
    let device = makeWorkspaceDevice(
      id: "B2B2B2B2-C3C3-44D4-85E5-F6F6F6F6F6F6",
      state: .shutdown
    )
    let planID = UUID()
    let plan = makeWorkspaceStoragePlan(id: planID, deviceID: device.id)
    let simulator = WorkspaceSimulatorSpy(device: device)
    let storageManager = WorkspaceStorageManagerStub(latestPlan: plan)
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [],
      storageManager: storageManager
    )
    let confirmedOperation = SimulatorOperation.cleanStorage(
      deviceID: device.id,
      planID: planID,
      categoryIDs: ["cache"],
      preserveBootState: true
    )

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(confirmedOperation))
    }
    _ = try await workspace.preview(confirmedOperation)
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(
        await workspace.perform(
          .cleanStorage(
            deviceID: device.id,
            planID: planID,
            categoryIDs: ["cache"],
            preserveBootState: false
          )
        )
      )
    }

    #expect(await simulator.mutatingCommands().isEmpty)
    #expect(await storageManager.recordedCleanCallCount() == 0)

    let replacementPlan = makeWorkspaceStoragePlan(id: UUID(), deviceID: device.id)
    await storageManager.setLatestPlan(replacementPlan)
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(confirmedOperation))
    }
    #expect(await simulator.mutatingCommands().isEmpty)
  }

  @Test("已启动设备必须先关机再重新扫描存储")
  func bootedDeviceCannotScanOrCleanStorage() async throws {
    let device = makeWorkspaceDevice(
      id: "B3B3B3B3-C4C4-45D5-86E6-F7F7F7F7F7F7",
      state: .booted
    )
    let planID = UUID()
    let simulator = WorkspaceSimulatorSpy(device: device)
    let receiptStore = WorkspaceReceiptStoreSpy()
    let storageManager = WorkspaceStorageManagerStub(
      latestPlan: makeWorkspaceStoragePlan(id: planID, deviceID: device.id)
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [],
      storageManager: storageManager
    )

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await workspace.preview(.scanStorage(deviceID: device.id))
    }
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(.scanStorage(deviceID: device.id)))
    }
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await workspace.preview(
        .cleanStorage(
          deviceID: device.id,
          planID: planID,
          categoryIDs: ["cache"],
          preserveBootState: true
        )
      )
    }
    #expect(await simulator.mutatingCommands().isEmpty)
    #expect(await storageManager.recordedScanCallCount() == 0)
    #expect(await receiptStore.receiptsSnapshot().isEmpty)
  }

  @Test("清理前二次校验发现设备已启动时拒绝删除")
  func storageCleanupRejectsBootRaceDuringRevalidation() async throws {
    let device = makeWorkspaceDevice(
      id: "B4B4B4B4-C5C5-46D6-87E7-F8F8F8F8F8F8",
      state: .shutdown
    )
    let planID = UUID()
    let simulator = WorkspaceSimulatorSpy(device: device)
    let storageManager = WorkspaceStorageManagerStub(
      latestPlan: makeWorkspaceStoragePlan(id: planID, deviceID: device.id)
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [],
      storageManager: storageManager
    )
    let operation = SimulatorOperation.cleanStorage(
      deviceID: device.id,
      planID: planID,
      categoryIDs: ["cache"],
      preserveBootState: false
    )

    _ = try await workspace.preview(operation)
    await simulator.overrideStateOnNextValidation(.booted)
    let events = try await collect(await workspace.perform(operation))

    #expect(events.last?.receipt?.status == .partial)
    #expect(events.last?.receipt?.messages.contains { $0.contains("请先关闭模拟器") } == true)
    #expect(await storageManager.recordedCleanCallCount() == 0)
    #expect(await simulator.mutatingCommands().isEmpty)
  }

  @Test("存储子项结果未知时保留明确待处理证据")
  func interruptedStorageChildRemainsPending() async throws {
    let device = makeWorkspaceDevice(
      id: "E5E5E5E5-F6F6-47A7-88B8-C9C9C9C9C9C9",
      state: .shutdown
    )
    let planID = UUID()
    let plan = makeWorkspaceStoragePlan(id: planID, deviceID: device.id)
    let storageManager = WorkspaceStorageManagerStub(
      latestPlan: plan,
      cleanupProgress: [
        StorageCleanupProgress(
          stage: .pending,
          relativePath: "Library/Caches/unknown.cache",
          targetRelativePath: "Library/Caches",
          targetReclaimedBytes: 0,
          reclaimedBytes: 0,
          completedTargetCount: 0,
          totalTargetCount: 1
        )
      ],
      cleanupError: WorkspaceTestError.simulatedFailure
    )
    let workspace = makeWorkspace(
      simulator: WorkspaceSimulatorSpy(device: device),
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [],
      storageManager: storageManager
    )
    let operation = SimulatorOperation.cleanStorage(
      deviceID: device.id,
      planID: planID,
      categoryIDs: ["cache"],
      preserveBootState: true
    )

    _ = try await workspace.preview(operation)
    let events = try await collect(await workspace.perform(operation))
    let receipt = try #require(events.last?.receipt)
    #expect(receipt.status == .partial)
    #expect(receipt.pendingStorageCleanupPath == "Library/Caches/unknown.cache")
    #expect(receipt.completedStorageCleanupItems == nil)
  }

  @Test("中断清理只在策略要求时恢复原始启动状态")
  func interruptedCleanupHonorsPowerRecoveryPolicy() async throws {
    let device = makeWorkspaceDevice(
      id: "C3C3C3C3-D4D4-45E5-86F6-A7A7A7A7A7A7",
      state: .shutdown
    )
    let recoverable = OperationReceipt(
      kind: .cleanStorage,
      deviceID: device.id,
      deviceName: device.name,
      status: .running,
      originalDeviceState: .booted,
      finalDeviceState: .shutdown,
      shouldRestoreOriginalDeviceState: true,
      pendingStorageCleanupPath: "Library/Caches/unknown.cache"
    )
    let receiptStore = WorkspaceReceiptStoreSpy(seed: [recoverable])
    let simulator = WorkspaceSimulatorSpy(device: device)
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )

    let overview = try await workspace.overview()
    let recovered = try #require(overview.recentReceipts.first { $0.id == recoverable.id })
    #expect(await simulator.currentState() == .booted)
    #expect(recovered.finalDeviceState == .booted)
    #expect(
      recovered.messages.contains { $0.contains(ReceiptStore.interruptionResolutionMarker) }
    )
    #expect(overview.pendingReceipts.map(\.id) == [recoverable.id])

    let noRestartDevice = makeWorkspaceDevice(
      id: "D4D4D4D4-E5E5-46F6-87A7-B8B8B8B8B8B8",
      state: .shutdown
    )
    let noRestart = OperationReceipt(
      kind: .cleanStorage,
      deviceID: noRestartDevice.id,
      deviceName: noRestartDevice.name,
      status: .running,
      originalDeviceState: .booted,
      finalDeviceState: .shutdown,
      shouldRestoreOriginalDeviceState: false
    )
    let noRestartSimulator = WorkspaceSimulatorSpy(device: noRestartDevice)
    let noRestartWorkspace = makeWorkspace(
      simulator: noRestartSimulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [noRestart]),
      services: []
    )
    _ = try await noRestartWorkspace.overview()
    #expect(await noRestartSimulator.currentState() == .shutdown)
  }

  @Test("继续验证只读核对中断前已完成的服务变更")
  func continuationVerificationDoesNotMutateServices() async throws {
    let service = makeWorkspaceService(id: "verify", label: "com.test.verify")
    let device = makeWorkspaceDevice(
      id: "55555555-6666-4777-8888-999999999999",
      state: .booted
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [service.label]
    )
    let sourceReceipt = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .partial,
      originalDeviceState: .booted,
      appliedChanges: [
        AppliedChange(
          change: serviceChange(for: service, transition: .disable),
          succeeded: true
        )
      ]
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [sourceReceipt]),
      services: [service]
    )

    let preview = try await workspace.preview(
      .verify(deviceID: device.id, receiptID: sourceReceipt.id)
    )
    #expect(preview.serviceChanges.map(\.label) == [service.label])

    let events = try await collect(
      await workspace.perform(
        .verify(deviceID: device.id, receiptID: sourceReceipt.id)
      )
    )
    let receipt = try #require(events.last?.receipt)
    #expect(receipt.kind == .verify)
    #expect(receipt.status == .succeeded)
    #expect(receipt.messages.contains { $0.contains("全部验证一致") })
    #expect(await simulator.serviceCommands().isEmpty)
    #expect(await simulator.disabledServiceLabels() == [service.label])
  }

  @Test("中断批次中的多项服务可逐项恢复状态")
  func interruptedServiceBatchCanBeResolvedItemByItem() async throws {
    let alpha = makeWorkspaceService(id: "pending-alpha", label: "com.test.pending.alpha")
    let beta = makeWorkspaceService(id: "pending-beta", label: "com.test.pending.beta")
    let device = makeWorkspaceDevice(
      id: "56565656-6767-4787-8989-ABABABABABAB",
      state: .booted
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [alpha.label]
    )
    let sourceReceipt = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .partial,
      originalDeviceState: .booted,
      pendingChanges: [
        serviceChange(for: alpha, transition: .disable),
        serviceChange(for: beta, transition: .disable),
      ]
    )
    let receiptStore = WorkspaceReceiptStoreSpy(seed: [sourceReceipt])
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [alpha, beta]
    )

    let preview = try await workspace.preview(
      .verify(deviceID: device.id, receiptID: sourceReceipt.id)
    )
    #expect(Set(preview.serviceChanges.map(\.label)) == [alpha.label, beta.label])

    _ = try await collect(
      await workspace.perform(
        .verify(deviceID: device.id, receiptID: sourceReceipt.id)
      )
    )

    let overview = try await workspace.overview()
    let resolved = try #require(
      overview.recentReceipts.first { $0.id == sourceReceipt.id }
    )
    #expect(resolved.pendingServiceChanges.isEmpty)
    #expect(
      resolved.appliedChanges.first { $0.change.label == alpha.label }?.succeeded == true
    )
    #expect(
      resolved.appliedChanges.first { $0.change.label == beta.label }?.succeeded == false
    )
  }

  @Test("中断回执保持待处理直到继续验证完成")
  func interruptedReceiptRemainsPendingUntilResolved() async throws {
    let device = makeWorkspaceDevice(
      id: "66666666-7777-4888-8999-AAAAAAAAAAAA",
      state: .booted
    )
    let sourceReceipt = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .partial,
      originalDeviceState: .booted,
      messages: ["\(ReceiptStore.interruptionMarker)；已保留现状"]
    )
    let workspace = makeWorkspace(
      simulator: WorkspaceSimulatorSpy(device: device),
      receiptStore: WorkspaceReceiptStoreSpy(seed: [sourceReceipt]),
      services: []
    )

    let before = try await workspace.overview()
    #expect(before.pendingReceipts.map(\.id) == [sourceReceipt.id])

    _ = try await collect(
      await workspace.perform(
        .verify(deviceID: device.id, receiptID: sourceReceipt.id)
      )
    )

    let after = try await workspace.overview()
    #expect(after.pendingReceipts.isEmpty)
    let updatedSource = try #require(
      after.recentReceipts.first { $0.id == sourceReceipt.id }
    )
    #expect(
      updatedSource.messages.contains {
        $0.contains(ReceiptStore.interruptionResolutionMarker)
      }
    )
  }

  @Test("取消会等待当前服务批次落盘再停止后续变更")
  func cancellationStopsAfterAtomicServiceBatch() async throws {
    let services = (0..<6).map {
      makeWorkspaceService(id: "cancel-\($0)", label: "com.test.cancel.\($0)")
    }
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "77777777-8888-4999-8AAA-BBBBBBBBBBBB",
        state: .booted
      ),
      serviceDelay: .milliseconds(180)
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: services
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    _ = try await workspace.preview(operation)
    let stream = await workspace.perform(operation)
    let consumer = Task {
      try await collect(stream)
    }

    while await simulator.serviceCommands().isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    consumer.cancel()

    var finalReceipt: OperationReceipt?
    for _ in 0..<100 {
      finalReceipt = await receiptStore.receiptsSnapshot().first {
        $0.kind == .optimize && $0.status == .cancelled
      }
      if finalReceipt != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let receipt = try #require(finalReceipt)
    let firstBatchLabels = Set(services.prefix(4).map(\.label))
    #expect(receipt.appliedChanges.count == 4)
    #expect(receipt.appliedChanges.allSatisfy { $0.succeeded })
    #expect(receipt.pendingServiceChanges.isEmpty)
    #expect(await simulator.serviceCommands().count == 4)
    #expect(await simulator.disabledServiceLabels() == firstBatchLabels)
  }

  @Test("服务变更固定为最多四路并发")
  func serviceChangesUseBoundedConcurrency() async throws {
    let services = (0..<10).map {
      makeWorkspaceService(id: "parallel-\($0)", label: "com.test.parallel.\($0)")
    }
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "78787878-8989-4A9A-8B8B-CDCDCDCDCDCD",
        state: .booted
      ),
      serviceDelay: .milliseconds(40)
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: services
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    let events = try await confirmedCollect(operation, using: workspace)

    #expect(events.last?.receipt?.status == .succeeded)
    #expect(await simulator.maximumConcurrentServiceCommands() == 4)
    #expect(await simulator.serviceCommands().count == services.count)
    #expect(await simulator.servicePresenceProbeCount() == 1)
  }

  @Test("服务命令与复核均失败时记录并跳过")
  func ambiguousServiceStepIsRecordedAndSkipped() async throws {
    let service = makeWorkspaceService(id: "ambiguous", label: "com.test.ambiguous")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "88888888-9999-4AAA-8BBB-CCCCCCCCCCCC",
        state: .booted
      ),
      failingServiceLabels: [service.label],
      failDisabledLabelReadsAfterServiceCommand: true
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [service]
    )

    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    let events = try await confirmedCollect(operation, using: workspace)
    let receipt = try #require(events.last?.receipt)
    #expect(receipt.status == .succeeded)
    #expect(receipt.pendingChange == nil)
    #expect(receipt.appliedChanges.count == 1)
    #expect(receipt.appliedChanges.first?.change.label == service.label)
    #expect(receipt.appliedChanges.first?.succeeded == false)
    #expect(receipt.appliedChanges.first?.errorMessage?.contains("已跳过") == true)
    #expect(events.contains { $0.phase == .applying && $0.state == .warning })

    let overview = try await workspace.overview()
    #expect(overview.pendingReceipts.isEmpty)
  }

  @Test("关机设备的精确预览使用回执并恢复原状态")
  func shutdownPreviewIsTransactional() async throws {
    let service = makeWorkspaceService(id: "preview", label: "com.test.preview")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD",
        state: .shutdown
      )
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [service]
    )

    _ = try await workspace.preview(
      .optimize(
        deviceID: await simulator.deviceID,
        profile: .recommended,
        customDisabledLabels: []
      )
    )

    #expect(await simulator.mutatingCommands() == ["boot", "shutdown"])
    #expect(await simulator.currentState() == .shutdown)
    let receipt = try #require(
      await receiptStore.receiptsSnapshot().first { $0.kind == .preflight }
    )
    #expect(receipt.status == .succeeded)
    #expect(receipt.originalDeviceState == .shutdown)
    #expect(receipt.finalDeviceState == .shutdown)
  }

  @Test("精确预览读取失败仍恢复关机并记录结果")
  func failedShutdownPreviewRestoresPowerState() async throws {
    let service = makeWorkspaceService(id: "preview-fail", label: "com.test.preview.fail")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
        state: .shutdown
      ),
      failDisabledLabelReads: true
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [service]
    )

    await #expect(throws: WorkspaceTestError.self) {
      _ = try await workspace.preview(
        .optimize(
          deviceID: await simulator.deviceID,
          profile: .recommended,
          customDisabledLabels: []
        )
      )
    }

    #expect(await simulator.mutatingCommands() == ["boot", "shutdown"])
    #expect(await simulator.currentState() == .shutdown)
    let receipt = try #require(
      await receiptStore.receiptsSnapshot().first { $0.kind == .preflight }
    )
    #expect(receipt.status == .failed)
    #expect(receipt.finalDeviceState == .shutdown)
  }

  @Test("启动时自动收尾中断的关机设备预检")
  func interruptedPreflightIsRecoveredOnLaunch() async throws {
    let device = makeWorkspaceDevice(
      id: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .preflight,
      deviceID: device.id,
      deviceName: device.name,
      status: .running,
      originalDeviceState: .shutdown
    )
    let simulator = WorkspaceSimulatorSpy(device: device)
    let receiptStore = WorkspaceReceiptStoreSpy(seed: [source])
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )

    let overview = try await workspace.overview()

    #expect(overview.pendingReceipts.isEmpty)
    #expect(await simulator.currentState() == .shutdown)
    #expect(await simulator.mutatingCommands() == ["shutdown"])
    let recovered = try #require(
      overview.recentReceipts.first { $0.id == source.id }
    )
    #expect(recovered.status == .partial)
    #expect(
      recovered.messages.contains {
        $0.contains(ReceiptStore.interruptionResolutionMarker)
      }
    )
  }

  @Test("预检自动恢复会遵守设备互斥锁并可在下次启动重试")
  func interruptedPreflightRecoveryHonorsDeviceLock() async throws {
    let device = makeWorkspaceDevice(
      id: "CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .preflight,
      deviceID: device.id,
      deviceName: device.name,
      status: .running,
      originalDeviceState: .shutdown
    )
    let simulator = WorkspaceSimulatorSpy(device: device)
    let receiptStore = WorkspaceReceiptStoreSpy(seed: [source])
    let gate = OperationGate()
    let heldLock = try await gate.acquire(for: device.id)
    let blockedWorkspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [],
      operationGate: gate
    )

    let blockedOverview = try await blockedWorkspace.overview()
    #expect(blockedOverview.pendingReceipts.map(\.id) == [source.id])
    #expect(await simulator.mutatingCommands().isEmpty)
    await heldLock.release()

    let retryWorkspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )
    let recoveredOverview = try await retryWorkspace.overview()
    #expect(recoveredOverview.pendingReceipts.isEmpty)
    #expect(await simulator.currentState() == .shutdown)
  }

  @Test("恢复会启用因停用而未加载的来源回执服务")
  func restoreEnablesDisabledServiceMissingFromLaunchctlPrint() async throws {
    let service = makeWorkspaceService(id: "unloaded", label: "com.test.unloaded")
    let device = makeWorkspaceDevice(
      id: "DDDDDDDD-EEEE-4FFF-8AAA-BBBBBBBBBBBB",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .succeeded,
      originalDeviceState: .booted,
      baselineCapturedAt: Date(),
      baselineDisabledLabels: [],
      appliedChanges: [
        AppliedChange(
          change: serviceChange(for: service, transition: .disable),
          succeeded: true
        )
      ]
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [service.label],
      disabledServicesAppearAbsent: true
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [source]),
      services: [service]
    )

    let preview = try await workspace.preview(
      .restore(deviceID: device.id, receiptID: source.id)
    )
    #expect(preview.serviceChanges.map(\.label) == [service.label])
    let operation = SimulatorOperation.restore(
      deviceID: device.id,
      receiptID: source.id
    )
    let events = try await confirmedCollect(operation, using: workspace)

    #expect(events.last?.receipt?.status == .succeeded)
    #expect(await simulator.disabledServiceLabels().isEmpty)
    #expect(await simulator.serviceCommands().first?.transition == "enable")
  }

  @Test("已完成回执的恢复保留当前操作开始时的启动状态")
  func completedRestorePreservesCurrentBootState() async throws {
    let service = makeWorkspaceService(id: "current-power", label: "com.test.current-power")
    let device = makeWorkspaceDevice(
      id: "12121212-3434-4567-8899-ABCDEFABCDEF",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .succeeded,
      originalDeviceState: .shutdown,
      baselineCapturedAt: Date(),
      baselineDisabledLabels: [],
      appliedChanges: [
        AppliedChange(
          change: serviceChange(for: service, transition: .disable),
          succeeded: true
        )
      ]
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [service.label]
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [source]),
      services: [service]
    )

    let operation = SimulatorOperation.restore(
      deviceID: device.id,
      receiptID: source.id
    )
    let events = try await confirmedCollect(operation, using: workspace)

    let receipt = try #require(events.last?.receipt)
    #expect(receipt.originalDeviceState == .booted)
    #expect(receipt.finalDeviceState == .booted)
    #expect(await simulator.currentState() == .booted)
  }

  @Test("中断回执会预告并恢复来源操作的关机状态")
  func interruptedVerificationRestoresSourceShutdownState() async throws {
    let service = makeWorkspaceService(id: "interrupted-power", label: "com.test.interrupted-power")
    let device = makeWorkspaceDevice(
      id: "23232323-4545-4678-899A-BCDEFABCDEF0",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .partial,
      originalDeviceState: .shutdown,
      baselineCapturedAt: Date(),
      appliedChanges: [
        AppliedChange(
          change: serviceChange(for: service, transition: .disable),
          succeeded: true
        )
      ],
      messages: ["\(ReceiptStore.interruptionMarker)；已保留现状"]
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      disabledLabels: [service.label]
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [source]),
      services: [service]
    )

    let preview = try await workspace.preview(
      .verify(deviceID: device.id, receiptID: source.id)
    )
    #expect(preview.warnings.contains { $0.contains("恢复该关机状态") })
    let events = try await collect(
      await workspace.perform(.verify(deviceID: device.id, receiptID: source.id))
    )

    #expect(events.last?.receipt?.originalDeviceState == .shutdown)
    #expect(events.last?.receipt?.finalDeviceState == .shutdown)
    #expect(await simulator.currentState() == .shutdown)
  }

  @Test("确认后服务差异漂移会拒绝执行并要求重新预览")
  func staleOptimizationPreviewPreventsMutation() async throws {
    let service = makeWorkspaceService(id: "stale", label: "com.test.stale")
    let device = makeWorkspaceDevice(
      id: "EEEEEEEE-FFFF-4AAA-8BBB-CCCCCCCCCCCC",
      state: .booted
    )
    let simulator = WorkspaceSimulatorSpy(device: device)
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )

    let preview = try await workspace.preview(
      .optimize(
        deviceID: device.id,
        profile: .recommended,
        customDisabledLabels: []
      )
    )
    #expect(preview.serviceChanges.map(\.label) == [service.label])
    await simulator.setDisabledServiceLabels([service.label])

    let events = try await collect(
      await workspace.perform(
        .optimize(
          deviceID: device.id,
          profile: .recommended,
          customDisabledLabels: []
        )
      )
    )

    #expect(events.last?.receipt?.status == .failed)
    #expect(
      events.last?.receipt?.messages.contains { $0.contains("重新预览") } == true
    )
    #expect(await simulator.serviceCommands().isEmpty)
  }

  @Test("优化缺少预览确认时拒绝执行")
  func optimizationWithoutConfirmationIsRejected() async throws {
    let service = makeWorkspaceService(id: "missing", label: "com.test.missing")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "ABABABAB-CDCD-4EFE-8123-456789ABCDEF",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }

    #expect(await simulator.mutatingCommands().isEmpty)
    #expect(await simulator.serviceCommands().isEmpty)
  }

  @Test("其他预览会使旧确认过期")
  func newerPreviewInvalidatesExistingConfirmation() async throws {
    let service = makeWorkspaceService(id: "expired", label: "com.test.expired")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "BCBCBCBC-DEDE-4FAF-8234-56789ABCDEF0",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    _ = try await workspace.preview(operation)
    _ = try await workspace.preview(.boot(deviceID: await simulator.deviceID))

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }
    #expect(await simulator.serviceCommands().isEmpty)
  }

  @Test("超过确认时效后拒绝执行")
  func expiredConfirmationIsRejected() async throws {
    let service = makeWorkspaceService(id: "timeout", label: "com.test.timeout")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "BDBDBDBD-E0E0-4900-8145-6789ABCDEF01",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service],
      serviceMutationConfirmationLifetime: .seconds(-1)
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    _ = try await workspace.preview(operation)
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }
    #expect(await simulator.mutatingCommands().isEmpty)
  }

  @Test("预览后电源状态漂移会拒绝执行")
  func powerStateDriftInvalidatesConfirmation() async throws {
    let service = makeWorkspaceService(id: "power-drift", label: "com.test.power-drift")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "CFCFCFCF-E1E1-4A01-8256-789ABCDEF012",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    _ = try await workspace.preview(operation)
    await simulator.setDeviceState(.shutdown)

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }
    #expect(await simulator.mutatingCommands().isEmpty)
    #expect(await simulator.serviceCommands().isEmpty)
  }

  @Test("确认签名只能消费一次")
  func confirmationCanOnlyBeConsumedOnce() async throws {
    let service = makeWorkspaceService(id: "once", label: "com.test.once")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "CDCDCDCD-EFEF-40B0-8345-6789ABCDEF01",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )

    _ = try await workspace.preview(operation)
    let firstEvents = try await collect(await workspace.perform(operation))
    #expect(firstEvents.last?.receipt?.status == .succeeded)

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }
    #expect(await simulator.serviceCommands().count == 1)
  }

  @Test("恢复缺少确认且预览后新增恢复项时均拒绝执行")
  func restoreConfirmationPreventsMissingAndNewChanges() async throws {
    let alpha = makeWorkspaceService(id: "restore-alpha", label: "com.test.restore.alpha")
    let beta = makeWorkspaceService(id: "restore-beta", label: "com.test.restore.beta")
    let device = makeWorkspaceDevice(
      id: "DEDEDEDE-F0F0-41C1-8456-789ABCDEF012",
      state: .booted
    )
    let source = OperationReceipt(
      kind: .optimize,
      deviceID: device.id,
      deviceName: device.name,
      status: .succeeded,
      originalDeviceState: .booted,
      baselineCapturedAt: Date(),
      baselineDisabledLabels: [],
      appliedChanges: [
        AppliedChange(change: serviceChange(for: alpha, transition: .disable), succeeded: true),
        AppliedChange(change: serviceChange(for: beta, transition: .disable), succeeded: true),
      ]
    )
    let simulator = WorkspaceSimulatorSpy(device: device, disabledLabels: [alpha.label])
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(seed: [source]),
      services: [alpha, beta]
    )
    let operation = SimulatorOperation.restore(deviceID: device.id, receiptID: source.id)

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(operation))
    }

    let preview = try await workspace.preview(operation)
    #expect(preview.serviceChanges.map(\.label) == [alpha.label])
    await simulator.setDisabledServiceLabels([alpha.label, beta.label])

    let events = try await collect(await workspace.perform(operation))
    #expect(events.last?.receipt?.status == .failed)
    #expect(events.last?.receipt?.messages.contains { $0.contains("重新预览") } == true)
    #expect(await simulator.serviceCommands().isEmpty)
  }

  @Test("关机设备取消优化后仍由非取消任务恢复关机")
  func cancellationRestoresOriginalShutdownState() async throws {
    let service = makeWorkspaceService(id: "cancel-power", label: "com.test.cancel.power")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "FFFFFFFF-AAAA-4BBB-8CCC-DDDDDDDDDDDD",
        state: .shutdown
      ),
      serviceDelay: .milliseconds(180)
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: [service]
    )
    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    _ = try await workspace.preview(operation)
    let stream = await workspace.perform(operation)
    let consumer = Task { try await collect(stream) }

    while await simulator.serviceCommands().isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    consumer.cancel()

    var finalReceipt: OperationReceipt?
    for _ in 0..<100 {
      finalReceipt = await receiptStore.receiptsSnapshot().first {
        $0.kind == .optimize && $0.status == .cancelled
      }
      if finalReceipt != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let receipt = try #require(finalReceipt)
    #expect(receipt.originalDeviceState == .shutdown)
    #expect(receipt.finalDeviceState == .shutdown)
    #expect(await simulator.currentState() == .shutdown)
  }

  @Test("修改性操作拒绝创建中等非稳定设备状态")
  func operationsRejectTransitionalDeviceState() async throws {
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "11111111-AAAA-4BBB-8CCC-EEEEEEEEEEEE",
        state: .creating
      )
    )
    let receiptStore = WorkspaceReceiptStoreSpy()
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: receiptStore,
      services: []
    )

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await workspace.preview(.scanStorage(deviceID: await simulator.deviceID))
    }
    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(
        await workspace.perform(.scanStorage(deviceID: await simulator.deviceID))
      )
    }

    #expect(await simulator.mutatingCommands().isEmpty)
    #expect(await receiptStore.receiptsSnapshot().isEmpty)
  }

  @Test("最终验证失败的服务记录并跳过")
  func finalVerificationFailureIsRecordedAndSkipped() async throws {
    let alpha = makeWorkspaceService(id: "verify-alpha", label: "com.test.verify.alpha")
    let beta = makeWorkspaceService(id: "verify-beta", label: "com.test.verify.beta")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "34343434-5656-4789-8ABC-DEFABCDEF012",
        state: .booted
      ),
      serviceToEnableOnRestart: beta.label
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [alpha, beta]
    )

    let operation = SimulatorOperation.optimize(
      deviceID: await simulator.deviceID,
      profile: .recommended,
      customDisabledLabels: []
    )
    let events = try await confirmedCollect(operation, using: workspace)

    let receipt = try #require(events.last?.receipt)
    #expect(receipt.status == .succeeded)
    #expect(receipt.messages.contains { $0.contains(beta.label) })
    #expect(
      receipt.appliedChanges.first { $0.change.label == beta.label }?.succeeded == false
    )
    #expect(
      receipt.appliedChanges.first { $0.change.label == beta.label }?.errorMessage?
        .contains("已跳过") == true
    )
    #expect(await simulator.serviceCommands().map(\.label) == [alpha.label, beta.label])
  }

  @Test("重复检查复用同一设备的服务存在性结果")
  func repeatedInspectionCachesServicePresencePerDevice() async throws {
    let service = makeWorkspaceService(id: "presence-cache", label: "com.test.presence-cache")
    let simulator = WorkspaceSimulatorSpy(
      device: makeWorkspaceDevice(
        id: "45454545-6767-489A-8BCD-EFABCDEF0123",
        state: .booted
      )
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )

    _ = try await workspace.inspect(await simulator.deviceID)
    _ = try await workspace.inspect(await simulator.deviceID)

    #expect(await simulator.servicePresenceProbeCount() == 1)
  }

  @Test("批量预览为每台设备分别保留一次性确认")
  func batchPreviewsRemainConsumablePerDevice() async throws {
    let service = makeWorkspaceService(id: "batch", label: "com.test.batch")
    let firstDevice = makeWorkspaceDevice(
      id: "EFEFEFEF-0101-42D2-8567-89ABCDEF0123",
      state: .booted
    )
    let secondDevice = makeWorkspaceDevice(
      id: "F0F0F0F0-1212-43E3-8678-9ABCDEF01234",
      state: .booted
    )
    let simulator = BatchWorkspaceSimulatorSpy(devices: [firstDevice, secondDevice])
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let firstOperation = SimulatorOperation.optimize(
      deviceID: firstDevice.id,
      profile: .recommended,
      customDisabledLabels: []
    )
    let secondOperation = SimulatorOperation.optimize(
      deviceID: secondDevice.id,
      profile: .recommended,
      customDisabledLabels: []
    )

    _ = try await workspace.preview(firstOperation)
    _ = try await workspace.preview(secondOperation)
    let firstEvents = try await collect(await workspace.perform(firstOperation))
    let secondEvents = try await collect(await workspace.perform(secondOperation))

    #expect(firstEvents.last?.receipt?.status == .succeeded)
    #expect(secondEvents.last?.receipt?.status == .succeeded)
    #expect(await simulator.serviceCommandDeviceIDs() == [firstDevice.id, secondDevice.id])
  }

  @Test("同设备并发预览只有最后开始的一次可执行")
  func concurrentPreviewsKeepOnlyLatestGeneration() async throws {
    let service = makeWorkspaceService(id: "race", label: "com.test.preview-race")
    let device = makeWorkspaceDevice(
      id: "F1F1F1F1-2323-44A4-89B9-C0C0C0C0C0C0",
      state: .booted
    )
    let simulator = WorkspaceSimulatorSpy(
      device: device,
      firstInventoryDelay: .milliseconds(80)
    )
    let workspace = makeWorkspace(
      simulator: simulator,
      receiptStore: WorkspaceReceiptStoreSpy(),
      services: [service]
    )
    let earlier = SimulatorOperation.optimize(
      deviceID: device.id,
      profile: .recommended,
      customDisabledLabels: []
    )
    let later = SimulatorOperation.optimize(
      deviceID: device.id,
      profile: .extreme,
      customDisabledLabels: []
    )

    let earlierPreview = Task { try await workspace.preview(earlier) }
    try await Task.sleep(for: .milliseconds(10))
    let laterPreview = Task { try await workspace.preview(later) }
    _ = try await laterPreview.value
    _ = try await earlierPreview.value

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await collect(await workspace.perform(earlier))
    }
    let events = try await collect(await workspace.perform(later))
    #expect(events.last?.receipt?.status == .succeeded)
    #expect(await simulator.serviceCommands().count == 1)
  }
}

private struct RecordedServiceCommand: Sendable {
  let label: String
  let transition: String
}

private actor WorkspaceSimulatorSpy: SimulatorControlling {
  private var device: SimulatorDevice
  private var disabledLabels: Set<String>
  private let failingServiceLabels: Set<String>
  private let serviceDelay: Duration
  private var failDisabledLabelReads: Bool
  private var failDisabledLabelReadsAfterServiceCommand: Bool
  private let disabledServicesAppearAbsent: Bool
  private let serviceToEnableOnRestart: String?
  private var commands: [String] = []
  private var recordedServiceCommands: [RecordedServiceCommand] = []
  private var activeServiceCommandCount = 0
  private var maximumActiveServiceCommandCount = 0
  private var presenceProbeCount = 0
  private let firstInventoryDelay: Duration?
  private var inventoryCallCount = 0
  private var stateOnNextValidation: SimulatorState?

  init(
    device: SimulatorDevice,
    disabledLabels: Set<String> = [],
    failingServiceLabels: Set<String> = [],
    serviceDelay: Duration = .zero,
    failDisabledLabelReads: Bool = false,
    failDisabledLabelReadsAfterServiceCommand: Bool = false,
    disabledServicesAppearAbsent: Bool = false,
    serviceToEnableOnRestart: String? = nil,
    firstInventoryDelay: Duration? = nil
  ) {
    self.device = device
    self.disabledLabels = disabledLabels
    self.failingServiceLabels = failingServiceLabels
    self.serviceDelay = serviceDelay
    self.failDisabledLabelReads = failDisabledLabelReads
    self.failDisabledLabelReadsAfterServiceCommand =
      failDisabledLabelReadsAfterServiceCommand
    self.disabledServicesAppearAbsent = disabledServicesAppearAbsent
    self.serviceToEnableOnRestart = serviceToEnableOnRestart
    self.firstInventoryDelay = firstInventoryDelay
  }

  var deviceID: SimulatorID { device.id }

  func inventory() async throws -> SimulatorInventory {
    inventoryCallCount += 1
    if inventoryCallCount == 1, let firstInventoryDelay {
      try await Task.sleep(for: firstInventoryDelay)
    }
    return SimulatorInventory(
      runtimes: [
        SimulatorRuntime(
          id: device.runtimeIdentifier,
          name: device.runtimeName,
          version: "26.5",
          isAvailable: true
        )
      ],
      devices: [device]
    )
  }

  func validatedDevice(_ id: SimulatorID) async throws -> SimulatorDevice {
    guard id == device.id else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    if let stateOnNextValidation {
      self.stateOnNextValidation = nil
      updateState(stateOnNextValidation)
    }
    return device
  }

  func disabledLabels(for id: SimulatorID) async throws -> Set<String> {
    guard id == device.id else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    if failDisabledLabelReads
      || (failDisabledLabelReadsAfterServiceCommand && !recordedServiceCommands.isEmpty)
    {
      throw WorkspaceTestError.simulatedFailure
    }
    return disabledLabels
  }

  func presentServiceLabels(
    _ labels: Set<String>,
    for id: SimulatorID
  ) async throws -> Set<String> {
    guard id == device.id else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    presenceProbeCount += 1
    return disabledServicesAppearAbsent ? labels.subtracting(disabledLabels) : labels
  }

  func setService(
    _ label: String,
    transition: ServiceTransition,
    deviceID: SimulatorID
  ) async throws {
    activeServiceCommandCount += 1
    maximumActiveServiceCommandCount = max(
      maximumActiveServiceCommandCount,
      activeServiceCommandCount
    )
    defer { activeServiceCommandCount -= 1 }
    commands.append("service")
    recordedServiceCommands.append(
      RecordedServiceCommand(label: label, transition: transition.rawValue)
    )
    try await Task.sleep(for: serviceDelay)
    if failingServiceLabels.contains(label) {
      throw WorkspaceTestError.simulatedFailure
    }
    switch transition {
    case .disable:
      disabledLabels.insert(label)
    case .enable:
      disabledLabels.remove(label)
    }
  }

  func boot(_ id: SimulatorID) async throws {
    commands.append("boot")
    if commands.contains("shutdown"), let serviceToEnableOnRestart {
      disabledLabels.remove(serviceToEnableOnRestart)
    }
    updateState(.booted)
  }

  func shutdown(_ id: SimulatorID) async throws {
    commands.append("shutdown")
    updateState(.shutdown)
  }

  func erase(_ id: SimulatorID) async throws {
    commands.append("erase")
  }

  func delete(_ id: SimulatorID) async throws {
    commands.append("delete")
    updateState(.unavailable)
  }

  func clone(_ id: SimulatorID, name: String) async throws -> SimulatorID {
    commands.append("clone")
    return SimulatorID(rawValue: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
  }

  func openSimulator(_ id: SimulatorID) async throws {
    commands.append("open")
    updateState(.booted)
  }

  func mutatingCommands() -> [String] { commands }

  func serviceCommands() -> [RecordedServiceCommand] {
    recordedServiceCommands
  }

  func maximumConcurrentServiceCommands() -> Int {
    maximumActiveServiceCommandCount
  }

  func disabledServiceLabels() -> Set<String> { disabledLabels }

  func allowDisabledLabelReads() {
    failDisabledLabelReads = false
    failDisabledLabelReadsAfterServiceCommand = false
  }

  func currentState() -> SimulatorState { device.state }

  func servicePresenceProbeCount() -> Int { presenceProbeCount }

  func setDisabledServiceLabels(_ labels: Set<String>) {
    disabledLabels = labels
  }

  func setDeviceState(_ state: SimulatorState) {
    updateState(state)
  }

  func overrideStateOnNextValidation(_ state: SimulatorState) {
    stateOnNextValidation = state
  }

  private func updateState(_ state: SimulatorState) {
    device = SimulatorDevice(
      id: device.id,
      name: device.name,
      runtimeIdentifier: device.runtimeIdentifier,
      runtimeName: device.runtimeName,
      deviceTypeIdentifier: device.deviceTypeIdentifier,
      state: state,
      isAvailable: state != .unavailable,
      availabilityError: device.availabilityError,
      dataPath: device.dataPath,
      logPath: device.logPath,
      dataSize: device.dataSize,
      logSize: device.logSize,
      lastBootedAt: device.lastBootedAt
    )
  }
}

private actor BatchWorkspaceSimulatorSpy: SimulatorControlling {
  private var devices: [SimulatorID: SimulatorDevice]
  private var disabledLabels: [SimulatorID: Set<String>]
  private var serviceCommandDevices: [SimulatorID] = []

  init(devices: [SimulatorDevice]) {
    self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    self.disabledLabels = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, []) })
  }

  func inventory() async throws -> SimulatorInventory {
    let devices = Array(devices.values)
    let runtimes = Dictionary(
      grouping: devices,
      by: \.runtimeIdentifier
    ).map { identifier, devices in
      SimulatorRuntime(
        id: identifier,
        name: devices[0].runtimeName,
        version: "26.5",
        isAvailable: true
      )
    }
    return SimulatorInventory(runtimes: runtimes, devices: devices)
  }

  func validatedDevice(_ id: SimulatorID) async throws -> SimulatorDevice {
    guard let device = devices[id] else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    return device
  }

  func disabledLabels(for id: SimulatorID) async throws -> Set<String> {
    guard let labels = disabledLabels[id] else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    return labels
  }

  func presentServiceLabels(
    _ labels: Set<String>,
    for id: SimulatorID
  ) async throws -> Set<String> {
    guard devices[id] != nil else { throw SimulatorWorkspaceError.deviceNotFound(id) }
    return labels
  }

  func setService(
    _ label: String,
    transition: ServiceTransition,
    deviceID: SimulatorID
  ) async throws {
    guard var labels = disabledLabels[deviceID] else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    serviceCommandDevices.append(deviceID)
    switch transition {
    case .disable: labels.insert(label)
    case .enable: labels.remove(label)
    }
    disabledLabels[deviceID] = labels
  }

  func boot(_ id: SimulatorID) async throws {
    try updateState(.booted, for: id)
  }

  func shutdown(_ id: SimulatorID) async throws {
    try updateState(.shutdown, for: id)
  }

  func erase(_ id: SimulatorID) async throws {
    guard devices[id] != nil else { throw SimulatorWorkspaceError.deviceNotFound(id) }
  }

  func delete(_ id: SimulatorID) async throws {
    guard devices.removeValue(forKey: id) != nil else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    disabledLabels.removeValue(forKey: id)
  }

  func clone(_ id: SimulatorID, name: String) async throws -> SimulatorID {
    guard devices[id] != nil else { throw SimulatorWorkspaceError.deviceNotFound(id) }
    return SimulatorID(rawValue: "01010101-2323-44F4-8789-ABCDEF012345")
  }

  func openSimulator(_ id: SimulatorID) async throws {
    try updateState(.booted, for: id)
  }

  func serviceCommandDeviceIDs() -> [SimulatorID] { serviceCommandDevices }

  private func updateState(_ state: SimulatorState, for id: SimulatorID) throws {
    guard let device = devices[id] else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    devices[id] = SimulatorDevice(
      id: device.id,
      name: device.name,
      runtimeIdentifier: device.runtimeIdentifier,
      runtimeName: device.runtimeName,
      deviceTypeIdentifier: device.deviceTypeIdentifier,
      state: state,
      isAvailable: true
    )
  }
}

private actor WorkspaceReceiptStoreSpy: ReceiptStoring {
  private var receipts: [ReceiptID: OperationReceipt]
  private var versions: [ReceiptID: [OperationReceipt]] = [:]
  private let failAllSaves: Bool

  init(seed: [OperationReceipt] = [], failAllSaves: Bool = false) {
    self.receipts = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    self.failAllSaves = failAllSaves
  }

  func save(_ receipt: OperationReceipt) async throws {
    guard !failAllSaves else { throw WorkspaceTestError.simulatedFailure }
    receipts[receipt.id] = receipt
    versions[receipt.id, default: []].append(receipt)
  }

  func receipt(id: ReceiptID) async throws -> OperationReceipt {
    guard let receipt = receipts[id] else {
      throw SimulatorWorkspaceError.receiptNotFound(id)
    }
    return receipt
  }

  func allReceipts() async throws -> [OperationReceipt] {
    receipts.values.sorted { $0.startedAt > $1.startedAt }
  }

  func recoverInterruptedReceipts() async throws -> [OperationReceipt] {
    var recovered: [OperationReceipt] = []
    for (id, var receipt) in receipts
    where receipt.status == .prepared || receipt.status == .running {
      receipt.status = .partial
      receipt.finishedAt = Date()
      receipt.messages.append("\(ReceiptStore.interruptionMarker)；已保留现状")
      receipts[id] = receipt
      recovered.append(receipt)
    }
    return recovered.sorted { $0.startedAt > $1.startedAt }
  }

  func receiptsSnapshot() -> [OperationReceipt] {
    Array(receipts.values)
  }

  func savedVersions(for id: ReceiptID) -> [OperationReceipt] {
    versions[id] ?? []
  }
}

private struct WorkspaceMemoryInspectorStub: MemoryInspecting {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    MemorySnapshot(bytes: 128 * 1_024 * 1_024, processCount: 4)
  }
}

private struct WorkspaceFailingMemoryInspector: MemoryInspecting {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    throw WorkspaceTestError.simulatedFailure
  }
}

private actor WorkspaceMemorySequenceStub: MemoryInspecting {
  private var snapshots: [MemorySnapshot]

  init(snapshots: [MemorySnapshot]) {
    self.snapshots = snapshots
  }

  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    guard !snapshots.isEmpty else { throw WorkspaceTestError.simulatedFailure }
    return snapshots.removeFirst()
  }
}

private struct WorkspaceFailingApplicationMemoryInspector: MemoryInspecting {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    MemorySnapshot(bytes: 128 * 1_024 * 1_024, processCount: 4)
  }

  func applicationMemorySnapshots(
    for deviceID: SimulatorID,
    applications: [SimulatorApplication]
  ) async throws -> [String: ApplicationMemorySnapshot] {
    throw WorkspaceTestError.simulatedFailure
  }
}

private actor WorkspaceApplicationCatalogRunner: CommandRunning {
  private let output: String

  init(output: String) {
    self.output = output
  }

  func run(_ command: Command) async throws -> CommandOutput {
    CommandOutput(
      standardOutput: output,
      standardError: "",
      exitCode: 0
    )
  }
}

private actor WorkspaceStorageManagerStub: StorageManaging {
  private var storedLatestPlan: StoragePlan?
  private let cleanupProgress: [StorageCleanupProgress]
  private let cleanupError: WorkspaceTestError?
  private var scanCallCount = 0
  private var cleanCallCount = 0

  init(
    latestPlan: StoragePlan? = nil,
    cleanupProgress: [StorageCleanupProgress] = [],
    cleanupError: WorkspaceTestError? = nil
  ) {
    self.storedLatestPlan = latestPlan
    self.cleanupProgress = cleanupProgress
    self.cleanupError = cleanupError
  }

  func scan(device: SimulatorDevice) async throws -> StoragePlan {
    scanCallCount += 1
    return StoragePlan(deviceID: device.id, totalBytes: 0, cleanableBytes: 0, categories: [])
  }

  func latestPlan(for deviceID: SimulatorID) async -> StoragePlan? {
    storedLatestPlan?.deviceID == deviceID ? storedLatestPlan : nil
  }

  func clean(
    device: SimulatorDevice,
    planID: UUID,
    categoryIDs: Set<String>
  ) async throws -> AsyncThrowingStream<StorageCleanupProgress, Error> {
    cleanCallCount += 1
    return AsyncThrowingStream { continuation in
      for progress in cleanupProgress { continuation.yield(progress) }
      if let cleanupError {
        continuation.finish(throwing: cleanupError)
      } else {
        continuation.finish()
      }
    }
  }

  func recordedScanCallCount() -> Int { scanCallCount }

  func recordedCleanCallCount() -> Int { cleanCallCount }

  func setLatestPlan(_ plan: StoragePlan) { storedLatestPlan = plan }
}

private enum WorkspaceTestError: LocalizedError {
  case simulatedFailure

  var errorDescription: String? { "模拟失败" }
}

private func makeWorkspace(
  simulator: any SimulatorControlling,
  receiptStore: WorkspaceReceiptStoreSpy,
  services: [ManagedService],
  memoryInspector: any MemoryInspecting = WorkspaceMemoryInspectorStub(),
  operationGate: OperationGate = OperationGate(),
  storageManager: any StorageManaging = WorkspaceStorageManagerStub(),
  applicationCatalog: SimulatorApplicationCatalog = SimulatorApplicationCatalog(),
  serviceMutationConfirmationLifetime: Duration = .seconds(300)
) -> SimulatorWorkspace {
  let category = ServiceCategory(
    id: "test",
    name: "测试",
    summary: "测试分类",
    symbol: "gear"
  )
  return SimulatorWorkspace(
    simulator: simulator,
    memoryInspector: memoryInspector,
    receiptStore: receiptStore,
    storageManager: storageManager,
    applicationCatalog: applicationCatalog,
    operationGate: operationGate,
    catalog: ServiceCatalog(
      schemaVersion: 1,
      categories: [category],
      services: services
    ),
    serviceMutationConfirmationLifetime: serviceMutationConfirmationLifetime
  )
}

private func makeWorkspaceDevice(
  id: String,
  state: SimulatorState
) -> SimulatorDevice {
  SimulatorDevice(
    id: SimulatorID(rawValue: id),
    name: "工作区测试设备",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    runtimeName: "iOS 26.5",
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    state: state,
    isAvailable: true
  )
}

private func makeWorkspaceService(id: String, label: String) -> ManagedService {
  ManagedService(
    id: id,
    label: label,
    name: id,
    impact: "测试影响",
    categoryID: "test",
    risk: .low,
    profiles: [.recommended, .extreme]
  )
}

private func makeWorkspaceStoragePlan(
  id: UUID,
  deviceID: SimulatorID
) -> StoragePlan {
  StoragePlan(
    id: id,
    deviceID: deviceID,
    totalBytes: 1_024,
    cleanableBytes: 1_024,
    categories: [
      StorageCategorySummary(
        id: "cache",
        name: "缓存",
        summary: "缓存",
        consequence: "可重建",
        recovery: "自动",
        risk: .low,
        isDefaultSelected: true,
        canClean: true,
        bytes: 1_024,
        targetCount: 1
      )
    ],
    items: [
      StorageItemSummary(
        categoryID: "cache",
        relativePath: "Library/Caches",
        bytes: 1_024
      )
    ]
  )
}

private func serviceChange(
  for service: ManagedService,
  transition: ServiceTransition
) -> ServiceChange {
  ServiceChange(
    label: service.label,
    serviceName: service.name,
    categoryID: service.categoryID,
    risk: service.risk,
    transition: transition
  )
}

private func collect(
  _ stream: AsyncThrowingStream<OperationEvent, Error>
) async throws -> [OperationEvent] {
  var events: [OperationEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
}

private func confirmedCollect(
  _ operation: SimulatorOperation,
  using workspace: SimulatorWorkspace
) async throws -> [OperationEvent] {
  _ = try await workspace.preview(operation)
  return try await collect(await workspace.perform(operation))
}
