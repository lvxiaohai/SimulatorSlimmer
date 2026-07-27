import Foundation

public struct SimulatorID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var id: String { rawValue }
  public var description: String { rawValue }
}

public struct ReceiptID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var id: UUID { rawValue }
}

public enum SimulatorState: String, Codable, CaseIterable, Sendable {
  case booted
  case shutdown
  case creating
  case shuttingDown
  case unavailable
  case unknown
}

public struct SimulatorRuntime: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let version: String
  public let build: String?
  public let isAvailable: Bool

  public init(
    id: String,
    name: String,
    version: String,
    build: String? = nil,
    isAvailable: Bool
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.build = build
    self.isAvailable = isAvailable
  }

  public var optimizationSupport: OptimizationSupportStatus {
    guard isAvailable else { return .unavailableRuntime }
    guard id.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") else {
      return .unsupportedRuntime
    }
    guard SimulatorOptimizationPolicy.supportedRuntimeVersions.contains(version) else {
      return .unsupportedRuntime
    }
    return .supported
  }
}

public struct SimulatorDeviceType: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let productFamily: String
  public let modelIdentifier: String?
  public let minimumRuntimeVersion: String
  public let maximumRuntimeVersion: String

  public init(
    id: String,
    name: String,
    productFamily: String,
    modelIdentifier: String? = nil,
    minimumRuntimeVersion: String,
    maximumRuntimeVersion: String
  ) {
    self.id = id
    self.name = name
    self.productFamily = productFamily
    self.modelIdentifier = modelIdentifier
    self.minimumRuntimeVersion = minimumRuntimeVersion
    self.maximumRuntimeVersion = maximumRuntimeVersion
  }

  public func supports(runtimeVersion: String) -> Bool {
    minimumRuntimeVersion.compare(runtimeVersion, options: .numeric) != .orderedDescending
      && maximumRuntimeVersion.compare(runtimeVersion, options: .numeric) != .orderedAscending
  }
}

public struct SimulatorCreationOptions: Sendable {
  public let runtimes: [SimulatorRuntime]
  public let deviceTypes: [SimulatorDeviceType]

  public init(
    runtimes: [SimulatorRuntime],
    deviceTypes: [SimulatorDeviceType]
  ) {
    self.runtimes = runtimes
    self.deviceTypes = deviceTypes
  }
}

public struct SimulatorCreationRequest: Sendable {
  public let name: String
  public let deviceTypeID: String
  public let runtimeID: String

  public init(name: String, deviceTypeID: String, runtimeID: String) {
    self.name = name
    self.deviceTypeID = deviceTypeID
    self.runtimeID = runtimeID
  }
}

public enum OptimizationSupportStatus: String, Codable, Hashable, Sendable {
  case supported
  case unavailableRuntime
  case unsupportedRuntime
}

public enum SimulatorOptimizationPolicy {
  public static let supportedRuntimeVersions: Set<String> = ["26.3.1", "26.5"]
}

public struct SimulatorDevice: Codable, Hashable, Sendable, Identifiable {
  public let id: SimulatorID
  public let name: String
  public let runtimeIdentifier: String
  public let runtimeName: String
  public let deviceTypeIdentifier: String
  public let state: SimulatorState
  public let isAvailable: Bool
  public let availabilityError: String?
  public let dataPath: URL?
  public let logPath: URL?
  public let dataSize: Int64?
  public let logSize: Int64?
  public let lastBootedAt: Date?

  public init(
    id: SimulatorID,
    name: String,
    runtimeIdentifier: String,
    runtimeName: String,
    deviceTypeIdentifier: String,
    state: SimulatorState,
    isAvailable: Bool,
    availabilityError: String? = nil,
    dataPath: URL? = nil,
    logPath: URL? = nil,
    dataSize: Int64? = nil,
    logSize: Int64? = nil,
    lastBootedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.runtimeIdentifier = runtimeIdentifier
    self.runtimeName = runtimeName
    self.deviceTypeIdentifier = deviceTypeIdentifier
    self.state = state
    self.isAvailable = isAvailable
    self.availabilityError = availabilityError
    self.dataPath = dataPath
    self.logPath = logPath
    self.dataSize = dataSize
    self.logSize = logSize
    self.lastBootedAt = lastBootedAt
  }
}

public struct SimulatorInventory: Codable, Sendable {
  public let runtimes: [SimulatorRuntime]
  public let devices: [SimulatorDevice]
  public let collectedAt: Date

  public init(
    runtimes: [SimulatorRuntime],
    devices: [SimulatorDevice],
    collectedAt: Date = Date()
  ) {
    self.runtimes = runtimes
    self.devices = devices
    self.collectedAt = collectedAt
  }
}

public struct MemorySnapshot: Codable, Hashable, Sendable {
  public let bytes: Int64
  public let processCount: Int
  public let collectedAt: Date
  public let method: String

  public init(
    bytes: Int64,
    processCount: Int,
    collectedAt: Date = Date(),
    method: String = "physical-footprint"
  ) {
    self.bytes = bytes
    self.processCount = processCount
    self.collectedAt = collectedAt
    self.method = method
  }
}

public struct MenuBarDeviceSnapshot: Identifiable, Sendable {
  public let device: SimulatorDevice
  public let memory: MemorySnapshot?
  public let memoryError: String?

  public init(
    device: SimulatorDevice,
    memory: MemorySnapshot?,
    memoryError: String? = nil
  ) {
    self.device = device
    self.memory = memory
    self.memoryError = memoryError
  }

  public var id: SimulatorID { device.id }
}

public struct MenuBarSnapshot: Sendable {
  public let devices: [MenuBarDeviceSnapshot]
  public let collectedAt: Date

  public init(
    devices: [MenuBarDeviceSnapshot],
    collectedAt: Date = Date()
  ) {
    self.devices = devices
    self.collectedAt = collectedAt
  }
}

public struct ApplicationMemorySnapshot: Codable, Hashable, Sendable {
  public let bytes: Int64
  public let processCount: Int
  public let collectedAt: Date
  public let method: String

  public init(
    bytes: Int64,
    processCount: Int,
    collectedAt: Date = Date(),
    method: String = "physical-footprint (libproc)"
  ) {
    self.bytes = bytes
    self.processCount = processCount
    self.collectedAt = collectedAt
    self.method = method
  }
}

public struct SimulatorApplicationListSnapshot: Sendable {
  public let applications: [SimulatorApplication]
  public let memoryByBundleIdentifier: [String: ApplicationMemorySnapshot]
  public let memoryError: String?

  public init(
    applications: [SimulatorApplication],
    memoryByBundleIdentifier: [String: ApplicationMemorySnapshot] = [:],
    memoryError: String? = nil
  ) {
    self.applications = applications
    self.memoryByBundleIdentifier = memoryByBundleIdentifier
    self.memoryError = memoryError
  }
}

public enum ServiceRisk: String, Codable, CaseIterable, Comparable, Sendable {
  case low
  case moderate
  case high
  case protected

  public static func < (lhs: Self, rhs: Self) -> Bool {
    let order: [Self] = [.low, .moderate, .high, .protected]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }
}

public struct ServiceCategory: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let summary: String
  public let symbol: String
  public let approximateIdleMemoryMB: Int?

  public init(
    id: String,
    name: String,
    summary: String,
    symbol: String,
    approximateIdleMemoryMB: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.symbol = symbol
    self.approximateIdleMemoryMB = approximateIdleMemoryMB
  }
}

public struct ManagedService: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let name: String
  public let impact: String
  public let categoryID: String
  public let risk: ServiceRisk
  public let profiles: Set<OptimizationProfile>
  public let alwaysEnabled: Bool
  public let minimumRuntimeMajor: Int?
  public let maximumRuntimeMajor: Int?

  public init(
    id: String,
    label: String,
    name: String,
    impact: String,
    categoryID: String,
    risk: ServiceRisk,
    profiles: Set<OptimizationProfile>,
    alwaysEnabled: Bool = false,
    minimumRuntimeMajor: Int? = nil,
    maximumRuntimeMajor: Int? = nil
  ) {
    self.id = id
    self.label = label
    self.name = name
    self.impact = impact
    self.categoryID = categoryID
    self.risk = risk
    self.profiles = profiles
    self.alwaysEnabled = alwaysEnabled
    self.minimumRuntimeMajor = minimumRuntimeMajor
    self.maximumRuntimeMajor = maximumRuntimeMajor
  }
}

public struct ServiceState: Codable, Hashable, Sendable, Identifiable {
  public let service: ManagedService
  public let isDisabled: Bool
  public let isPresent: Bool

  public init(service: ManagedService, isDisabled: Bool, isPresent: Bool = true) {
    self.service = service
    self.isDisabled = isDisabled
    self.isPresent = isPresent
  }

  public var id: String { service.id }
  public var isOptimizationCandidate: Bool {
    isPresent && !service.alwaysEnabled && service.risk != .protected
  }
}

public enum OptimizationProfile: String, Codable, CaseIterable, Hashable, Sendable,
  Identifiable
{
  case recommended
  case extreme
  case custom
  case enableAllServices = "allEnabled"

  public var id: String { rawValue }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    switch value {
    case Self.recommended.rawValue, "conservative", "balanced":
      self = .recommended
    case Self.extreme.rawValue, "efficient":
      self = .extreme
    case Self.custom.rawValue:
      self = .custom
    case Self.enableAllServices.rawValue:
      self = .enableAllServices
    default:
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "未知精简方案：\(value)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ServiceTransition: String, Codable, Sendable {
  case disable
  case enable
}

public struct ServiceChange: Codable, Hashable, Sendable, Identifiable {
  public let label: String
  public let serviceName: String
  public let categoryID: String
  public let risk: ServiceRisk
  public let transition: ServiceTransition
  public let impact: String?
  public let currentDisabled: Bool?
  public let targetDisabled: Bool?

  public init(
    label: String,
    serviceName: String,
    categoryID: String,
    risk: ServiceRisk,
    transition: ServiceTransition,
    impact: String? = nil,
    currentDisabled: Bool? = nil,
    targetDisabled: Bool? = nil
  ) {
    self.label = label
    self.serviceName = serviceName
    self.categoryID = categoryID
    self.risk = risk
    self.transition = transition
    self.impact = impact
    self.currentDisabled = currentDisabled
    self.targetDisabled = targetDisabled
  }

  public var id: String { "\(transition.rawValue):\(label)" }
}

public struct OptimizationPlan: Codable, Sendable, Identifiable {
  public let id: UUID
  public let deviceID: SimulatorID
  public let profile: OptimizationProfile
  public let changes: [ServiceChange]
  public let protectedLabels: [String]
  public let unknownDisabledLabels: [String]
  public let desiredDisabledLabels: Set<String>
  public let managedLabels: Set<String>
  public let generatedAt: Date

  public init(
    id: UUID = UUID(),
    deviceID: SimulatorID,
    profile: OptimizationProfile,
    changes: [ServiceChange],
    protectedLabels: [String] = [],
    unknownDisabledLabels: [String] = [],
    desiredDisabledLabels: Set<String> = [],
    managedLabels: Set<String> = [],
    generatedAt: Date = Date()
  ) {
    self.id = id
    self.deviceID = deviceID
    self.profile = profile
    self.changes = changes
    self.protectedLabels = protectedLabels
    self.unknownDisabledLabels = unknownDisabledLabels
    self.desiredDisabledLabels = desiredDisabledLabels
    self.managedLabels = managedLabels
    self.generatedAt = generatedAt
  }
}

public enum StorageRisk: String, Codable, Sendable {
  case low
  case restoredOnDemand
  case protected
}

public struct StorageCategorySummary: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let summary: String
  public let consequence: String
  public let recovery: String
  public let risk: StorageRisk
  public let isDefaultSelected: Bool
  public let canClean: Bool
  public let bytes: Int64
  public let targetCount: Int

  public init(
    id: String,
    name: String,
    summary: String,
    consequence: String,
    recovery: String,
    risk: StorageRisk,
    isDefaultSelected: Bool,
    canClean: Bool,
    bytes: Int64,
    targetCount: Int
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.consequence = consequence
    self.recovery = recovery
    self.risk = risk
    self.isDefaultSelected = isDefaultSelected
    self.canClean = canClean
    self.bytes = bytes
    self.targetCount = targetCount
  }
}

public struct StorageItemSummary: Codable, Hashable, Sendable, Identifiable {
  public let categoryID: String
  public let relativePath: String
  public let bytes: Int64

  public init(categoryID: String, relativePath: String, bytes: Int64) {
    self.categoryID = categoryID
    self.relativePath = relativePath
    self.bytes = bytes
  }

  public var id: String { "\(categoryID):\(relativePath)" }
}

public struct StoragePlan: Codable, Sendable, Identifiable {
  public let id: UUID
  public let deviceID: SimulatorID
  public let generatedAt: Date
  public let totalBytes: Int64
  public let cleanableBytes: Int64
  public let categories: [StorageCategorySummary]
  public let items: [StorageItemSummary]

  public init(
    id: UUID = UUID(),
    deviceID: SimulatorID,
    generatedAt: Date = Date(),
    totalBytes: Int64,
    cleanableBytes: Int64,
    categories: [StorageCategorySummary],
    items: [StorageItemSummary] = []
  ) {
    self.id = id
    self.deviceID = deviceID
    self.generatedAt = generatedAt
    self.totalBytes = totalBytes
    self.cleanableBytes = cleanableBytes
    self.categories = categories
    self.items = items
  }
}

public struct DeviceSnapshot: Sendable {
  public let device: SimulatorDevice
  public let memory: MemorySnapshot?
  public let services: [ServiceState]
  public let categories: [ServiceCategory]
  public let plans: [OptimizationProfile: OptimizationPlan]
  public let latestStoragePlan: StoragePlan?
  public let memoryError: String?
  public let optimizationSupport: OptimizationSupportStatus

  public init(
    device: SimulatorDevice,
    memory: MemorySnapshot?,
    services: [ServiceState],
    categories: [ServiceCategory],
    plans: [OptimizationProfile: OptimizationPlan],
    latestStoragePlan: StoragePlan? = nil,
    memoryError: String? = nil,
    optimizationSupport: OptimizationSupportStatus = .supported
  ) {
    self.device = device
    self.memory = memory
    self.services = services
    self.categories = categories
    self.plans = plans
    self.latestStoragePlan = latestStoragePlan
    self.memoryError = memoryError
    self.optimizationSupport = optimizationSupport
  }
}

public enum OperationKind: String, Codable, Sendable {
  case preflight
  case optimize
  case verify
  case restore
  case scanStorage
  case cleanStorage
  case boot
  case shutdown
  case erase
  case delete
  case clone
  case openSimulator
}

public enum SimulatorOperation: Sendable {
  case optimize(
    deviceID: SimulatorID,
    profile: OptimizationProfile,
    customDisabledLabels: Set<String>
  )
  case verify(deviceID: SimulatorID, receiptID: ReceiptID)
  case restore(deviceID: SimulatorID, receiptID: ReceiptID)
  case scanStorage(deviceID: SimulatorID)
  case cleanStorage(
    deviceID: SimulatorID,
    planID: UUID,
    categoryIDs: Set<String>,
    preserveBootState: Bool
  )
  case boot(deviceID: SimulatorID)
  case shutdown(deviceID: SimulatorID)
  case erase(deviceID: SimulatorID)
  case delete(deviceID: SimulatorID)
  case clone(deviceID: SimulatorID, name: String)
  case openSimulator(deviceID: SimulatorID)

  public var deviceID: SimulatorID {
    switch self {
    case .optimize(let deviceID, _, _), .verify(let deviceID, _),
      .restore(let deviceID, _),
      .scanStorage(let deviceID), .cleanStorage(let deviceID, _, _, _),
      .boot(let deviceID), .shutdown(let deviceID), .erase(let deviceID),
      .delete(let deviceID), .clone(let deviceID, _), .openSimulator(let deviceID):
      deviceID
    }
  }

  public var kind: OperationKind {
    switch self {
    case .optimize: .optimize
    case .verify: .verify
    case .restore: .restore
    case .scanStorage: .scanStorage
    case .cleanStorage: .cleanStorage
    case .boot: .boot
    case .shutdown: .shutdown
    case .erase: .erase
    case .delete: .delete
    case .clone: .clone
    case .openSimulator: .openSimulator
    }
  }
}

public struct OperationPreview: Sendable {
  public let operation: SimulatorOperation
  public let title: String
  public let summary: String
  public let serviceChanges: [ServiceChange]
  public let selectedBytes: Int64?
  public let warnings: [String]
  public let requiresConfirmation: Bool
  public let confirmationPhrase: String?

  public init(
    operation: SimulatorOperation,
    title: String,
    summary: String,
    serviceChanges: [ServiceChange] = [],
    selectedBytes: Int64? = nil,
    warnings: [String] = [],
    requiresConfirmation: Bool = false,
    confirmationPhrase: String? = nil
  ) {
    self.operation = operation
    self.title = title
    self.summary = summary
    self.serviceChanges = serviceChanges
    self.selectedBytes = selectedBytes
    self.warnings = warnings
    self.requiresConfirmation = requiresConfirmation
    self.confirmationPhrase = confirmationPhrase
  }
}

public enum OperationPhase: String, Codable, Sendable {
  case preflight
  case preparing
  case measuringBefore
  case applying
  case restarting
  case verifying
  case measuringAfter
  case scanningStorage
  case cleaningStorage
  case deviceAction
  case finalizing
  case completed
}

public enum OperationEventState: String, Codable, Sendable {
  case running
  case succeeded
  case warning
  case failed
}

public struct OperationEvent: Sendable, Identifiable {
  public let id: UUID
  public let operationID: ReceiptID
  public let deviceID: SimulatorID
  public let phase: OperationPhase
  public let state: OperationEventState
  public let message: String
  public let completedCount: Int?
  public let totalCount: Int?
  public let receipt: OperationReceipt?
  public let date: Date

  public init(
    id: UUID = UUID(),
    operationID: ReceiptID,
    deviceID: SimulatorID,
    phase: OperationPhase,
    state: OperationEventState,
    message: String,
    completedCount: Int? = nil,
    totalCount: Int? = nil,
    receipt: OperationReceipt? = nil,
    date: Date = Date()
  ) {
    self.id = id
    self.operationID = operationID
    self.deviceID = deviceID
    self.phase = phase
    self.state = state
    self.message = message
    self.completedCount = completedCount
    self.totalCount = totalCount
    self.receipt = receipt
    self.date = date
  }
}

public enum OperationStatus: String, Codable, Sendable {
  case prepared
  case running
  case succeeded
  case partial
  case failed
  case cancelled
}

public struct AppliedChange: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let change: ServiceChange
  public let succeeded: Bool
  public let errorMessage: String?
  public let appliedAt: Date

  public init(
    id: UUID = UUID(),
    change: ServiceChange,
    succeeded: Bool,
    errorMessage: String? = nil,
    appliedAt: Date = Date()
  ) {
    self.id = id
    self.change = change
    self.succeeded = succeeded
    self.errorMessage = errorMessage
    self.appliedAt = appliedAt
  }
}

public struct StorageCleanupEvidence: Codable, Hashable, Sendable, Identifiable {
  public let relativePath: String
  public let targetRelativePath: String
  public let reclaimedBytes: Int64
  public let completedAt: Date

  public init(
    relativePath: String,
    targetRelativePath: String,
    reclaimedBytes: Int64,
    completedAt: Date = Date()
  ) {
    self.relativePath = relativePath
    self.targetRelativePath = targetRelativePath
    self.reclaimedBytes = reclaimedBytes
    self.completedAt = completedAt
  }

  public var id: String { relativePath }
}

public struct OperationInput: Codable, Hashable, Sendable {
  public var profile: OptimizationProfile?
  public var customDisabledLabels: Set<String>?
  public var sourceReceiptID: ReceiptID?
  public var storagePlanID: UUID?
  public var storageCategoryIDs: Set<String>?
  public var preserveBootState: Bool?
  public var cloneName: String?

  public init(
    profile: OptimizationProfile? = nil,
    customDisabledLabels: Set<String>? = nil,
    sourceReceiptID: ReceiptID? = nil,
    storagePlanID: UUID? = nil,
    storageCategoryIDs: Set<String>? = nil,
    preserveBootState: Bool? = nil,
    cloneName: String? = nil
  ) {
    self.profile = profile
    self.customDisabledLabels = customDisabledLabels
    self.sourceReceiptID = sourceReceiptID
    self.storagePlanID = storagePlanID
    self.storageCategoryIDs = storageCategoryIDs
    self.preserveBootState = preserveBootState
    self.cloneName = cloneName
  }
}

public struct PendingDeviceAction: Codable, Hashable, Sendable {
  public let kind: OperationKind
  public let cloneName: String?
  public let startedAt: Date

  public init(kind: OperationKind, cloneName: String? = nil, startedAt: Date = Date()) {
    self.kind = kind
    self.cloneName = cloneName
    self.startedAt = startedAt
  }
}

public struct OpaqueReceiptPayload: Codable, Hashable, Sendable {
  public enum Reason: String, Codable, Hashable, Sendable {
    case unsupportedSchema
    case corrupted
  }

  public let reason: Reason
  public let sourceFileName: String
  public let rawJSON: String?
  public let errorMessage: String

  public init(
    reason: Reason,
    sourceFileName: String,
    rawJSON: String? = nil,
    errorMessage: String
  ) {
    self.reason = reason
    self.sourceFileName = sourceFileName
    self.rawJSON = rawJSON
    self.errorMessage = errorMessage
  }
}

public struct OperationReceipt: Codable, Sendable, Identifiable {
  public let id: ReceiptID
  public let schemaVersion: Int
  public let kind: OperationKind
  public let deviceID: SimulatorID
  public let deviceName: String
  public var status: OperationStatus
  public let startedAt: Date
  public var finishedAt: Date?
  public let originalDeviceState: SimulatorState
  public var finalDeviceState: SimulatorState?
  public var shouldRestoreOriginalDeviceState: Bool?
  public var input: OperationInput?
  public var runtimeIdentifier: String?
  public var runtimeVersion: String?
  public var serviceCatalogVersion: Int?
  public var baselineCapturedAt: Date?
  public var baselineDisabledLabels: Set<String>
  public var pendingChange: ServiceChange?
  public var pendingChanges: [ServiceChange]?
  public var appliedChanges: [AppliedChange]
  public var memoryBefore: MemorySnapshot?
  public var memoryAfter: MemorySnapshot?
  public var reclaimedBytes: Int64?
  public var pendingStorageCleanupPath: String?
  public var completedStorageCleanupItems: [StorageCleanupEvidence]?
  public var pendingDeviceAction: PendingDeviceAction?
  public var clonedDeviceID: SimulatorID?
  public var messages: [String]
  public var opaquePayload: OpaqueReceiptPayload?

  public init(
    id: ReceiptID = ReceiptID(),
    schemaVersion: Int = 1,
    kind: OperationKind,
    deviceID: SimulatorID,
    deviceName: String,
    status: OperationStatus,
    startedAt: Date = Date(),
    finishedAt: Date? = nil,
    originalDeviceState: SimulatorState,
    finalDeviceState: SimulatorState? = nil,
    shouldRestoreOriginalDeviceState: Bool? = nil,
    input: OperationInput? = nil,
    runtimeIdentifier: String? = nil,
    runtimeVersion: String? = nil,
    serviceCatalogVersion: Int? = nil,
    baselineCapturedAt: Date? = nil,
    baselineDisabledLabels: Set<String> = [],
    pendingChange: ServiceChange? = nil,
    pendingChanges: [ServiceChange]? = nil,
    appliedChanges: [AppliedChange] = [],
    memoryBefore: MemorySnapshot? = nil,
    memoryAfter: MemorySnapshot? = nil,
    reclaimedBytes: Int64? = nil,
    pendingStorageCleanupPath: String? = nil,
    completedStorageCleanupItems: [StorageCleanupEvidence]? = nil,
    pendingDeviceAction: PendingDeviceAction? = nil,
    clonedDeviceID: SimulatorID? = nil,
    messages: [String] = [],
    opaquePayload: OpaqueReceiptPayload? = nil
  ) {
    self.id = id
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.originalDeviceState = originalDeviceState
    self.finalDeviceState = finalDeviceState
    self.shouldRestoreOriginalDeviceState = shouldRestoreOriginalDeviceState
    self.input = input
    self.runtimeIdentifier = runtimeIdentifier
    self.runtimeVersion = runtimeVersion
    self.serviceCatalogVersion = serviceCatalogVersion
    self.baselineCapturedAt = baselineCapturedAt
    self.baselineDisabledLabels = baselineDisabledLabels
    self.pendingChange = pendingChange
    self.pendingChanges = pendingChanges
    self.appliedChanges = appliedChanges
    self.memoryBefore = memoryBefore
    self.memoryAfter = memoryAfter
    self.reclaimedBytes = reclaimedBytes
    self.pendingStorageCleanupPath = pendingStorageCleanupPath
    self.completedStorageCleanupItems = completedStorageCleanupItems
    self.pendingDeviceAction = pendingDeviceAction
    self.clonedDeviceID = clonedDeviceID
    self.messages = messages
    self.opaquePayload = opaquePayload
  }

  public var pendingServiceChanges: [ServiceChange] {
    var changes = pendingChanges ?? []
    if let pendingChange, !changes.contains(where: { $0.label == pendingChange.label }) {
      changes.append(pendingChange)
    }
    return changes
  }
}

public struct WorkspaceOverview: Sendable {
  public let inventory: SimulatorInventory
  public let recentReceipts: [OperationReceipt]
  public let pendingReceipts: [OperationReceipt]

  public init(
    inventory: SimulatorInventory,
    recentReceipts: [OperationReceipt],
    pendingReceipts: [OperationReceipt]
  ) {
    self.inventory = inventory
    self.recentReceipts = recentReceipts
    self.pendingReceipts = pendingReceipts
  }
}

public enum SimulatorWorkspaceError: LocalizedError, Sendable {
  case xcodeToolsUnavailable(String)
  case deviceNotFound(SimulatorID)
  case deviceNotBooted(SimulatorID)
  case deviceUnavailable(String)
  case invalidOperation(String)
  case commandFailed(command: String, code: Int32, message: String)
  case commandTimedOut(String)
  case malformedOutput(String)
  case receiptNotFound(ReceiptID)
  case staleStoragePlan
  case unsafePath(String)
  case operationAlreadyRunning(SimulatorID)

  public var errorDescription: String? {
    switch self {
    case .xcodeToolsUnavailable(let message): message
    case .deviceNotFound(let id): "找不到模拟器 \(id.rawValue)"
    case .deviceNotBooted(let id): "模拟器 \(id.rawValue) 尚未启动"
    case .deviceUnavailable(let message): message
    case .invalidOperation(let message): message
    case .commandFailed(let command, let code, let message):
      "命令 \(command) 失败（\(code)）：\(message)"
    case .commandTimedOut(let command): "命令超时：\(command)"
    case .malformedOutput(let message): "无法解析系统输出：\(message)"
    case .receiptNotFound(let id): "找不到内部恢复数据 \(id.rawValue.uuidString)"
    case .staleStoragePlan: "存储扫描结果已过期，请重新扫描"
    case .unsafePath(let path): "拒绝访问不安全路径：\(path)"
    case .operationAlreadyRunning(let id): "模拟器 \(id.rawValue) 已有操作正在运行"
    }
  }
}
