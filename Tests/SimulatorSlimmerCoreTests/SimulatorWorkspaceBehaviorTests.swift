import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("工作区事务行为")
struct SimulatorWorkspaceBehaviorTests {
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

  @Test("单项服务失败时保留成功项并生成部分完成回执")
  func serviceFailureProducesPartialReceipt() async throws {
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

    let events = try await collect(
      await workspace.perform(
        .optimize(
          deviceID: await simulator.deviceID,
          profile: .conservative,
          customDisabledLabels: []
        )
      )
    )

    let finalReceipt = try #require(events.last?.receipt)
    #expect(finalReceipt.status == .partial)
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
    #expect(events.contains { $0.phase == .applying && $0.state == .failed })
    #expect(events.last?.state == .warning)
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

    let events = try await collect(
      await workspace.perform(
        .restore(deviceID: device.id, receiptID: sourceReceipt.id)
      )
    )

    let serviceCommands = await simulator.serviceCommands()
    #expect(serviceCommands.count == 1)
    #expect(serviceCommands.first?.label == alpha.label)
    #expect(serviceCommands.first?.transition == "enable")
    #expect(await simulator.disabledServiceLabels() == [beta.label, gamma.label])
    #expect(events.last?.receipt?.status == .succeeded)
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
  private var commands: [String] = []
  private var recordedServiceCommands: [RecordedServiceCommand] = []

  init(
    device: SimulatorDevice,
    disabledLabels: Set<String> = [],
    failingServiceLabels: Set<String> = []
  ) {
    self.device = device
    self.disabledLabels = disabledLabels
    self.failingServiceLabels = failingServiceLabels
  }

  var deviceID: SimulatorID { device.id }

  func inventory() async throws -> SimulatorInventory {
    SimulatorInventory(
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
    return device
  }

  func disabledLabels(for id: SimulatorID) async throws -> Set<String> {
    guard id == device.id else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    return disabledLabels
  }

  func setService(
    _ label: String,
    transition: ServiceTransition,
    deviceID: SimulatorID
  ) async throws {
    commands.append("service")
    recordedServiceCommands.append(
      RecordedServiceCommand(label: label, transition: transition.rawValue)
    )
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

  func disabledServiceLabels() -> Set<String> { disabledLabels }

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

private actor WorkspaceReceiptStoreSpy: ReceiptStoring {
  private var receipts: [ReceiptID: OperationReceipt]
  private let failAllSaves: Bool

  init(seed: [OperationReceipt] = [], failAllSaves: Bool = false) {
    self.receipts = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    self.failAllSaves = failAllSaves
  }

  func save(_ receipt: OperationReceipt) async throws {
    guard !failAllSaves else { throw WorkspaceTestError.simulatedFailure }
    receipts[receipt.id] = receipt
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

  func recoverInterruptedReceipts() async throws -> [OperationReceipt] { [] }
}

private struct WorkspaceMemoryInspectorStub: MemoryInspecting {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    MemorySnapshot(bytes: 128 * 1_024 * 1_024, processCount: 4)
  }
}

private actor WorkspaceStorageManagerStub: StorageManaging {
  func scan(device: SimulatorDevice) async throws -> StoragePlan {
    StoragePlan(deviceID: device.id, totalBytes: 0, cleanableBytes: 0, categories: [])
  }

  func latestPlan(for deviceID: SimulatorID) async -> StoragePlan? { nil }

  func clean(
    device: SimulatorDevice,
    planID: UUID,
    categoryIDs: Set<String>
  ) async throws -> Int64 { 0 }
}

private enum WorkspaceTestError: LocalizedError {
  case simulatedFailure

  var errorDescription: String? { "模拟失败" }
}

private func makeWorkspace(
  simulator: WorkspaceSimulatorSpy,
  receiptStore: WorkspaceReceiptStoreSpy,
  services: [ManagedService]
) -> SimulatorWorkspace {
  let category = ServiceCategory(
    id: "test",
    name: "测试",
    summary: "测试分类",
    symbol: "gear"
  )
  return SimulatorWorkspace(
    simulator: simulator,
    memoryInspector: WorkspaceMemoryInspectorStub(),
    receiptStore: receiptStore,
    storageManager: WorkspaceStorageManagerStub(),
    operationGate: OperationGate(),
    catalog: ServiceCatalog(
      schemaVersion: 1,
      categories: [category],
      services: services
    )
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
    profiles: [.conservative, .balanced, .efficient]
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
