import Foundation
import SimulatorSlimmerCore

enum WorkspaceFactory {
  static func make() -> any SimulatorWorkspaceClient {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--ui-testing") {
        return ScriptedSimulatorWorkspace(arguments: arguments)
      }
    #endif
    return SimulatorWorkspace()
  }
}

#if DEBUG
  /// 仅供 UI 测试使用，让界面状态不依赖开发机上的 Simulator 环境。
  private actor ScriptedSimulatorWorkspace: SimulatorWorkspaceClient {
    private let mode: Mode
    private let runtime: SimulatorRuntime
    private let phone: SimulatorDevice
    private let tablet: SimulatorDevice
    private var receipts: [OperationReceipt] = []
    private var storageScanned = false

    private enum Mode {
      case ready
      case empty
      case error
      case partial
      case interrupted
      case unsupported
      case opaqueReceipts
    }

    init(arguments: [String]) {
      if arguments.contains("--ui-testing-empty") {
        mode = .empty
      } else if arguments.contains("--ui-testing-error") {
        mode = .error
      } else if arguments.contains("--ui-testing-partial") {
        mode = .partial
      } else if arguments.contains("--ui-testing-interrupted") {
        mode = .interrupted
      } else if arguments.contains("--ui-testing-unsupported") {
        mode = .unsupported
      } else if arguments.contains("--ui-testing-opaque-receipts") {
        mode = .opaqueReceipts
      } else {
        mode = .ready
      }

      let runtimeVersion = mode == .unsupported ? "26.6" : "26.5"
      let runtimeIdentifier =
        "com.apple.CoreSimulator.SimRuntime.iOS-\(runtimeVersion.replacingOccurrences(of: ".", with: "-"))"
      runtime = SimulatorRuntime(
        id: runtimeIdentifier,
        name: "iOS \(runtimeVersion)",
        version: runtimeVersion,
        build: "23F80",
        isAvailable: true
      )
      phone = SimulatorDevice(
        id: SimulatorID(rawValue: "1B59C381-1963-4384-BC43-8A3EE7E8E61B"),
        name: "iPhone 17 Pro",
        runtimeIdentifier: runtimeIdentifier,
        runtimeName: "iOS \(runtimeVersion)",
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        state: .booted,
        isAvailable: true,
        dataSize: 9_120_000_000,
        logSize: 228_000_000,
        lastBootedAt: Date().addingTimeInterval(-1_860)
      )
      tablet = SimulatorDevice(
        id: SimulatorID(rawValue: "541BD79A-07A9-4EEB-9932-B1B2E019BF9A"),
        name: "iPad Pro 13-inch",
        runtimeIdentifier: runtimeIdentifier,
        runtimeName: "iOS \(runtimeVersion)",
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
        state: .shutdown,
        isAvailable: true,
        dataSize: 5_470_000_000,
        logSize: 96_000_000
      )

      if mode == .interrupted {
        receipts = [
          OperationReceipt(
            kind: .optimize,
            deviceID: phone.id,
            deviceName: phone.name,
            status: .running,
            startedAt: Date().addingTimeInterval(-180),
            originalDeviceState: .booted,
            baselineCapturedAt: Date().addingTimeInterval(-175),
            baselineDisabledLabels: ["com.apple.suggestionsd"],
            pendingChange: ServiceChange(
              label: "com.apple.suggestionsd",
              serviceName: "系统建议",
              categoryID: "intelligence",
              risk: .low,
              transition: .disable,
              impact: "暂停系统个性化建议与预测更新。",
              currentDisabled: false,
              targetDisabled: true
            ),
            messages: ["进程退出前已保存操作进度，可继续进行只读验证。"]
          )
        ]
      } else if mode == .opaqueReceipts {
        receipts = Self.opaqueReceipts(phone: phone, tablet: tablet)
      }
    }

    func overview() async throws -> WorkspaceOverview {
      if mode == .error {
        throw SimulatorWorkspaceError.xcodeToolsUnavailable(
          "未找到模拟器命令行工具，请检查开发工具设置。"
        )
      }
      let devices = mode == .empty ? [] : [phone, tablet]
      return WorkspaceOverview(
        inventory: SimulatorInventory(
          runtimes: mode == .empty ? [] : [runtime],
          devices: devices
        ),
        recentReceipts: receipts,
        pendingReceipts: mode == .interrupted ? receipts : []
      )
    }

    func inspect(_ deviceID: SimulatorID) async throws -> DeviceSnapshot {
      let device: SimulatorDevice
      if deviceID == phone.id {
        device = phone
      } else if deviceID == tablet.id {
        device = tablet
      } else {
        throw SimulatorWorkspaceError.deviceNotFound(deviceID)
      }

      let services = Self.services
      let plans = Dictionary(
        uniqueKeysWithValues: OptimizationProfile.allCases.map { profile in
          let changes = Self.changes(for: profile, services: services)
          return (
            profile,
            OptimizationPlan(deviceID: deviceID, profile: profile, changes: changes)
          )
        }
      )
      return DeviceSnapshot(
        device: device,
        memory: device.state == .booted
          ? MemorySnapshot(bytes: 3_984_572_416, processCount: 214)
          : nil,
        services: services,
        categories: Self.categories,
        plans: plans,
        latestStoragePlan: storageScanned ? Self.storagePlan(deviceID: deviceID) : nil,
        optimizationSupport: runtime.optimizationSupport
      )
    }

    func preview(_ operation: SimulatorOperation) async throws -> OperationPreview {
      switch operation {
      case .optimize(let deviceID, let profile, _):
        let snapshot = try await inspect(deviceID)
        return OperationPreview(
          operation: operation,
          title: "优化计划",
          summary: "仅修改预览中列出的模拟器后台服务；完成后会重新读取状态并保存恢复基线。",
          serviceChanges: snapshot.plans[profile]?.changes ?? [],
          warnings: profile == .efficient ? ["高效方案可能影响部分系统级测试场景。"] : []
        )
      case .verify(let deviceID, let receiptID):
        guard let source = receipts.first(where: { $0.id == receiptID }) else {
          throw SimulatorWorkspaceError.receiptNotFound(receiptID)
        }
        return OperationPreview(
          operation: operation,
          title: "继续验证",
          summary: "只读核对中断前已执行的服务状态，并保存一份新的验证回执。",
          serviceChanges: source.appliedChanges.filter(\.succeeded).map(\.change),
          warnings: deviceID == tablet.id ? ["验证期间可能短暂启动这台模拟器。"] : [],
          requiresConfirmation: true
        )
      case .cleanStorage(let deviceID, _, let categoryIDs, _):
        let plan = Self.storagePlan(deviceID: deviceID)
        let bytes = plan.categories
          .filter { categoryIDs.contains($0.id) }
          .reduce(0) { $0 + $1.bytes }
        return OperationPreview(
          operation: operation,
          title: "确认清理计划",
          summary: "只会处理已知安全路径；应用数据、安装包和符号链接目标不会被删除。",
          selectedBytes: bytes,
          requiresConfirmation: true
        )
      default:
        return OperationPreview(
          operation: operation,
          title: operation.kind.localizedDebugTitle,
          summary: "操作将在精确校验设备 UDID 后执行，并记录完整回执。",
          requiresConfirmation: operation.kind == .erase || operation.kind == .delete
        )
      }
    }

    func perform(
      _ operation: SimulatorOperation
    ) async -> AsyncThrowingStream<OperationEvent, Error> {
      let operationID = ReceiptID()
      let phases = Self.phases(for: operation.kind)
      return AsyncThrowingStream { continuation in
        let task = Task { [weak self] in
          do {
            for (index, phase) in phases.enumerated() {
              try await Task.sleep(for: .milliseconds(180))
              try Task.checkCancellation()
              continuation.yield(
                OperationEvent(
                  operationID: operationID,
                  deviceID: operation.deviceID,
                  phase: phase,
                  state: index == phases.count - 1 ? .succeeded : .running,
                  message: phase.localizedDebugMessage,
                  completedCount: phase == .applying ? min(18, index * 9) : nil,
                  totalCount: phase == .applying ? 18 : nil
                )
              )
            }

            guard let self else {
              continuation.finish()
              return
            }
            let receipt = await self.complete(operation, operationID: operationID)
            continuation.yield(
              OperationEvent(
                operationID: operationID,
                deviceID: operation.deviceID,
                phase: .completed,
                state: receipt.status == .partial ? .warning : .succeeded,
                message: receipt.status == .partial ? "部分服务未通过验证" : "操作已完成并验证",
                receipt: receipt
              )
            )
            continuation.finish()
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    func exportDiagnostics(to destinationURL: URL) async throws -> URL {
      let payload = "Simulator Slimmer UI 测试诊断包\n".data(using: .utf8) ?? Data()
      try payload.write(to: destinationURL, options: .atomic)
      return destinationURL
    }

    private func complete(
      _ operation: SimulatorOperation,
      operationID: ReceiptID
    ) -> OperationReceipt {
      if operation.kind == .scanStorage {
        storageScanned = true
      }
      let isPartial =
        mode == .partial && operation.kind == .optimize && operation.deviceID == tablet.id
      let snapshotChanges = Self.changes(for: .balanced, services: Self.services)
      let applied =
        operation.kind == .optimize
        ? snapshotChanges.map {
          AppliedChange(
            change: $0,
            succeeded: !isPartial || $0.id != snapshotChanges.last?.id,
            errorMessage: isPartial && $0.id == snapshotChanges.last?.id
              ? "服务在重启后恢复为启用状态"
              : nil
          )
        }
        : []
      let receipt = OperationReceipt(
        id: operationID,
        kind: operation.kind,
        deviceID: operation.deviceID,
        deviceName: operation.deviceID == phone.id ? phone.name : tablet.name,
        status: isPartial ? .partial : .succeeded,
        finishedAt: Date(),
        originalDeviceState: operation.deviceID == phone.id ? .booted : .shutdown,
        finalDeviceState: operation.deviceID == phone.id ? .booted : .shutdown,
        appliedChanges: applied,
        memoryBefore: operation.kind == .optimize
          ? MemorySnapshot(bytes: 3_984_572_416, processCount: 214)
          : nil,
        memoryAfter: operation.kind == .optimize
          ? MemorySnapshot(bytes: 2_761_474_048, processCount: 151)
          : nil,
        reclaimedBytes: operation.kind == .optimize ? 1_223_098_368 : nil,
        messages: isPartial
          ? ["17 项变更已验证。", "1 项变更未生效，可根据基线恢复。"]
          : ["操作完成。", "最终状态已验证并保存。"]
      )
      receipts.insert(receipt, at: 0)
      return receipt
    }

    private static let categories = [
      ServiceCategory(
        id: "intelligence",
        name: "系统智能与建议",
        summary: "建议、搜索与个性化后台能力",
        symbol: "sparkles"
      ),
      ServiceCategory(
        id: "sync",
        name: "同步与分享",
        summary: "云同步、共享与接力相关服务",
        symbol: "arrow.triangle.2.circlepath"
      ),
      ServiceCategory(
        id: "media",
        name: "非必要媒体服务",
        summary: "媒体分析与后台资源整理",
        symbol: "play.rectangle.on.rectangle"
      ),
    ]

    private static let services: [ServiceState] = [
      service(
        id: "suggestions",
        label: "com.apple.suggestionsd",
        name: "系统建议",
        impact: "暂停系统个性化建议与预测更新。",
        category: "intelligence",
        risk: .low,
        profiles: [.conservative, .balanced, .efficient]
      ),
      service(
        id: "knowledge",
        label: "com.apple.knowledge-agent",
        name: "知识索引",
        impact: "暂停非必要的设备知识索引。",
        category: "intelligence",
        risk: .moderate,
        profiles: [.balanced, .efficient]
      ),
      service(
        id: "sharing",
        label: "com.apple.sharingd",
        name: "共享服务",
        impact: "核心共享能力保持启用。",
        category: "sync",
        risk: .protected,
        profiles: [],
        alwaysEnabled: true
      ),
      service(
        id: "cloud",
        label: "com.apple.cloudd",
        name: "云同步",
        impact: "暂停模拟器中的云端后台同步。",
        category: "sync",
        risk: .moderate,
        profiles: [.balanced, .efficient]
      ),
      service(
        id: "media-analysis",
        label: "com.apple.mediaanalysisd",
        name: "媒体分析",
        impact: "暂停照片与媒体的后台分析。",
        category: "media",
        risk: .low,
        profiles: [.conservative, .balanced, .efficient]
      ),
      service(
        id: "photo-library",
        label: "com.apple.photoanalysisd",
        name: "照片资料库分析",
        impact: "暂停高开销的照片识别任务。",
        category: "media",
        risk: .high,
        profiles: [.efficient]
      ),
    ]

    private static func service(
      id: String,
      label: String,
      name: String,
      impact: String,
      category: String,
      risk: ServiceRisk,
      profiles: Set<OptimizationProfile>,
      alwaysEnabled: Bool = false
    ) -> ServiceState {
      ServiceState(
        service: ManagedService(
          id: id,
          label: label,
          name: name,
          impact: impact,
          categoryID: category,
          risk: risk,
          profiles: profiles,
          alwaysEnabled: alwaysEnabled
        ),
        isDisabled: false
      )
    }

    private static func opaqueReceipts(
      phone: SimulatorDevice,
      tablet: SimulatorDevice
    ) -> [OperationReceipt] {
      [
        OperationReceipt(
          id: ReceiptID(
            rawValue: UUID(uuidString: "2AF81128-F810-465B-9C9F-F9C702CC3752") ?? UUID()
          ),
          schemaVersion: 2,
          kind: .optimize,
          deviceID: phone.id,
          deviceName: phone.name,
          status: .failed,
          startedAt: Date().addingTimeInterval(-240),
          finishedAt: Date().addingTimeInterval(-238),
          originalDeviceState: .booted,
          messages: ["结构版本 2 尚不受支持，只能读取或导出。"],
          opaquePayload: OpaqueReceiptPayload(
            reason: .unsupportedSchema,
            sourceFileName: "future-receipt.json",
            rawJSON: "{\"schemaVersion\":2}",
            errorMessage: "结构版本 2 尚不受支持"
          )
        ),
        OperationReceipt(
          id: ReceiptID(
            rawValue: UUID(uuidString: "A94AA544-95B3-4663-A31D-D78E2A1E139E") ?? UUID()
          ),
          schemaVersion: 0,
          kind: .optimize,
          deviceID: tablet.id,
          deviceName: tablet.name,
          status: .failed,
          startedAt: Date().addingTimeInterval(-360),
          finishedAt: Date().addingTimeInterval(-358),
          originalDeviceState: .shutdown,
          messages: ["JSON 无法解析，只能保留原始内容。"],
          opaquePayload: OpaqueReceiptPayload(
            reason: .corrupted,
            sourceFileName: "broken-receipt.json",
            rawJSON: "{",
            errorMessage: "JSON 无法解析"
          )
        ),
      ]
    }

    private static func changes(
      for profile: OptimizationProfile,
      services: [ServiceState]
    ) -> [ServiceChange] {
      services.compactMap { state in
        guard
          !state.service.alwaysEnabled,
          state.service.risk != .protected,
          profile == .custom || state.service.profiles.contains(profile)
        else { return nil }
        return ServiceChange(
          label: state.service.label,
          serviceName: state.service.name,
          categoryID: state.service.categoryID,
          risk: state.service.risk,
          transition: .disable,
          impact: state.service.impact,
          currentDisabled: state.isDisabled,
          targetDisabled: true
        )
      }
    }

    private static func storagePlan(deviceID: SimulatorID) -> StoragePlan {
      StoragePlan(
        deviceID: deviceID,
        totalBytes: 18_400_000_000,
        cleanableBytes: 3_200_000_000,
        categories: [
          StorageCategorySummary(
            id: "caches",
            name: "缓存",
            summary: "可按需重新生成的应用缓存",
            consequence: "下次启动相关应用时可能重新下载或计算资源。",
            recovery: "由应用按需自动生成。",
            risk: .restoredOnDemand,
            isDefaultSelected: true,
            canClean: true,
            bytes: 2_600_000_000,
            targetCount: 38
          ),
          StorageCategorySummary(
            id: "logs",
            name: "日志",
            summary: "历史诊断与运行日志",
            consequence: "旧的调试记录将不再可用。",
            recovery: "后续运行会生成新的日志。",
            risk: .low,
            isDefaultSelected: true,
            canClean: true,
            bytes: 420_000_000,
            targetCount: 76
          ),
          StorageCategorySummary(
            id: "tmp",
            name: "临时文件",
            summary: "运行时创建的短期文件",
            consequence: "不会影响持久化应用数据。",
            recovery: "需要时由系统或应用重建。",
            risk: .low,
            isDefaultSelected: true,
            canClean: true,
            bytes: 180_000_000,
            targetCount: 24
          ),
          StorageCategorySummary(
            id: "app-data",
            name: "应用数据",
            summary: "文档、数据库和用户生成内容",
            consequence: "不会处理。",
            recovery: "不适用。",
            risk: .protected,
            isDefaultSelected: false,
            canClean: false,
            bytes: 11_800_000_000,
            targetCount: 12
          ),
          StorageCategorySummary(
            id: "app-bundles",
            name: "已安装应用包",
            summary: "模拟器中安装的应用程序",
            consequence: "不会处理。",
            recovery: "不适用。",
            risk: .protected,
            isDefaultSelected: false,
            canClean: false,
            bytes: 2_900_000_000,
            targetCount: 12
          ),
        ],
        items: [
          StorageItemSummary(
            categoryID: "caches",
            relativePath: "Containers/Data/Application/…/Library/Caches",
            bytes: 2_120_000_000
          ),
          StorageItemSummary(
            categoryID: "caches",
            relativePath: "Library/Caches",
            bytes: 480_000_000
          ),
          StorageItemSummary(
            categoryID: "logs",
            relativePath: "private/var/log",
            bytes: 420_000_000
          ),
          StorageItemSummary(
            categoryID: "tmp",
            relativePath: "private/var/tmp",
            bytes: 180_000_000
          ),
        ]
      )
    }

    private static func phases(for kind: OperationKind) -> [OperationPhase] {
      switch kind {
      case .preflight:
        [.preflight]
      case .optimize, .restore:
        [.preflight, .preparing, .applying, .restarting, .verifying]
      case .verify:
        [.preflight, .verifying]
      case .scanStorage:
        [.preflight, .scanningStorage, .finalizing]
      case .cleanStorage:
        [.preflight, .cleaningStorage, .verifying]
      case .boot, .shutdown, .erase, .delete, .clone, .openSimulator:
        [.preflight, .deviceAction, .verifying]
      }
    }
  }

  extension OperationKind {
    fileprivate nonisolated var localizedDebugTitle: String {
      switch self {
      case .preflight: "操作预检"
      case .optimize: "优化模拟器"
      case .verify: "继续验证"
      case .restore: "恢复模拟器"
      case .scanStorage: "扫描存储"
      case .cleanStorage: "清理存储"
      case .boot: "启动模拟器"
      case .shutdown: "关闭模拟器"
      case .erase: "抹掉模拟器内容"
      case .delete: "删除模拟器"
      case .clone: "克隆模拟器"
      case .openSimulator: "打开 Apple 模拟器"
      }
    }
  }

  extension OperationPhase {
    fileprivate nonisolated var localizedDebugMessage: String {
      switch self {
      case .preflight: "环境检查已通过"
      case .preparing: "正在记录修改前基线"
      case .measuringBefore: "正在采集优化前内存"
      case .applying: "正在更新后台服务"
      case .restarting: "正在重启模拟器"
      case .verifying: "正在验证最终状态"
      case .measuringAfter: "正在采集优化后内存"
      case .scanningStorage: "正在扫描安全路径"
      case .cleaningStorage: "正在清理所选项目"
      case .deviceAction: "正在执行设备操作"
      case .finalizing: "正在整理结果"
      case .completed: "操作已完成"
      }
    }
  }
#endif
