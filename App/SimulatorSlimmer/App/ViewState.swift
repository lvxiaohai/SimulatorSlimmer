import Foundation
import SimulatorSlimmerCore

enum SidebarSelection: Hashable {
  case device(SimulatorID)
}

enum WorkspaceModal: String, Identifiable {
  case batchOptimization
  case createSimulator
  case settings

  var id: String { rawValue }
}

enum DeviceSection: String, CaseIterable, Identifiable {
  case optimization
  case storage
  case applications
  case device

  var id: String { rawValue }

  var title: LocalizedStringResource {
    switch self {
    case .optimization: "tab.optimization"
    case .storage: "tab.storage"
    case .applications: "tab.applications"
    case .device: "tab.device"
    }
  }
}

enum ApplicationListState {
  case idle
  case loading(deviceID: SimulatorID)
  case loaded(deviceID: SimulatorID, snapshot: SimulatorApplicationListSnapshot)
  case failed(deviceID: SimulatorID, message: String)

  var deviceID: SimulatorID? {
    switch self {
    case .idle:
      nil
    case .loading(let deviceID), .loaded(let deviceID, _), .failed(let deviceID, _):
      deviceID
    }
  }
}

struct RuntimeDeviceGroup: Identifiable {
  let runtime: SimulatorRuntime
  let devices: [SimulatorDevice]

  var id: String { runtime.id }
}

struct AppNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

struct AppToast: Identifiable {
  let id = UUID()
  let message: String
}

struct PreviewPresentation: Identifiable {
  let id = UUID()
  let preview: OperationPreview
  let confirmsExecution: Bool
  let categories: [ServiceCategory]
  let services: [ServiceState]

  init(
    preview: OperationPreview,
    confirmsExecution: Bool,
    categories: [ServiceCategory] = [],
    services: [ServiceState] = []
  ) {
    self.preview = preview
    self.confirmsExecution = confirmsExecution
    self.categories = categories
    self.services = services
  }
}

struct BatchPreviewItem: Identifiable {
  let device: SimulatorDevice
  let operation: SimulatorOperation
  let preview: OperationPreview?
  let failureMessage: String?

  var id: SimulatorID { device.id }
  var canExecute: Bool { preview != nil && failureMessage == nil }
}

struct BatchPreviewPresentation: Identifiable {
  let id = UUID()
  let profile: OptimizationProfile
  let items: [BatchPreviewItem]

  var executableCount: Int { items.count(where: \.canExecute) }
  var failedCount: Int { items.count - executableCount }
  var totalChangeCount: Int {
    items.compactMap(\.preview).reduce(0) { $0 + $1.serviceChanges.count }
  }
}

struct DangerPresentation: Identifiable {
  enum Kind {
    case erase
    case delete
    case clone
  }

  let id = UUID()
  let kind: Kind
  let device: SimulatorDevice
}

struct PresentedOperation {
  let operation: SimulatorOperation
  var events: [OperationEvent] = []
  var receipt: OperationReceipt?
  var failureMessage: String?
  var stopRequested = false

  var isRunning: Bool {
    receipt == nil
      && failureMessage == nil
      && latestEvent?.isTerminal != true
  }

  var latestEvent: OperationEvent? { events.last }
}

struct OptimizationDraft {
  let profile: OptimizationProfile
}

enum BatchQueueItemStatus: Equatable {
  case pending
  case running
  case succeeded
  case failed
  case skipped
  case cancelled

  var localizedTitle: String {
    switch self {
    case .pending: L10n.text("batch.status.pending")
    case .running: L10n.text("batch.status.running")
    case .succeeded: L10n.text("batch.status.succeeded")
    case .failed: L10n.text("batch.status.failed")
    case .skipped: L10n.text("batch.status.skipped")
    case .cancelled: L10n.text("batch.status.cancelled")
    }
  }

  var isTerminal: Bool {
    switch self {
    case .pending, .running: false
    case .succeeded, .failed, .skipped, .cancelled: true
    }
  }
}

struct BatchQueueItem: Identifiable {
  let device: SimulatorDevice
  let initialPreview: OperationPreview?
  var status: BatchQueueItemStatus = .pending
  var detail: String?
  var receipt: OperationReceipt?

  var id: SimulatorID { device.id }
}

extension ServiceChange {
  var localizedStateTransition: String {
    let current = currentDisabled ?? (transition == .enable)
    let target = targetDisabled ?? (transition == .disable)
    return L10n.formatted(
      "service-change.state-transition",
      current ? L10n.text("service-state.paused") : L10n.text("service-state.enabled"),
      target ? L10n.text("service-state.paused") : L10n.text("service-state.enabled")
    )
  }
}

struct BatchOptimizationRun: Identifiable {
  let id = UUID()
  let profile: OptimizationProfile
  var items: [BatchQueueItem]
  let startedAt = Date()
  var finishedAt: Date?
  var cancellationRequested = false

  var isRunning: Bool { finishedAt == nil }
  var completedCount: Int { items.count(where: { $0.status.isTerminal }) }
  var succeededCount: Int { items.count(where: { $0.status == .succeeded }) }
  var failedCount: Int { items.count(where: { $0.status == .failed }) }
  var skippedCount: Int { items.count(where: { $0.status == .skipped }) }
  var cancelledCount: Int { items.count(where: { $0.status == .cancelled }) }
  var currentItem: BatchQueueItem? { items.first(where: { $0.status == .running }) }

  var progress: Double {
    guard !items.isEmpty else { return 0 }
    return Double(completedCount) / Double(items.count)
  }

  var currentPosition: Int {
    if let index = items.firstIndex(where: { $0.status == .running }) {
      return index + 1
    }
    return min(completedCount, items.count)
  }
}

enum L10n {
  static func text(_ key: String.LocalizationValue) -> String {
    String(localized: key)
  }

  static func formatted(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
    String(
      format: String(localized: key),
      locale: Locale.current,
      arguments: arguments
    )
  }
}

extension SimulatorState {
  var localizedTitle: String {
    switch self {
    case .booted: L10n.text("state.booted")
    case .shutdown: L10n.text("state.shutdown")
    case .creating: L10n.text("state.creating")
    case .shuttingDown: L10n.text("state.shutting-down")
    case .unavailable: L10n.text("state.unavailable")
    case .unknown: L10n.text("state.unknown")
    }
  }

  var symbolName: String {
    switch self {
    case .booted: "circle.fill"
    case .shutdown: "circle"
    case .creating, .shuttingDown: "circle.dotted"
    case .unavailable: "exclamationmark.circle.fill"
    case .unknown: "questionmark.circle"
    }
  }
}

extension OptimizationProfile {
  var localizedTitle: String {
    switch self {
    case .recommended: L10n.text("profile.recommended")
    case .extreme: L10n.text("profile.extreme")
    case .custom: L10n.text("profile.custom")
    case .enableAllServices: L10n.text("profile.all-enabled")
    }
  }

  var localizedSummary: String {
    switch self {
    case .recommended: L10n.text("profile.recommended.summary")
    case .extreme: L10n.text("profile.extreme.summary")
    case .custom: L10n.text("profile.custom.summary")
    case .enableAllServices: L10n.text("profile.all-enabled.summary")
    }
  }
}

extension OperationKind {
  var localizedTitle: String {
    switch self {
    case .preflight: L10n.text("operation.preflight")
    case .optimize: L10n.text("operation.optimize")
    case .verify: L10n.text("operation.verify")
    case .restore: L10n.text("operation.restore")
    case .scanStorage: L10n.text("operation.scan-storage")
    case .cleanStorage: L10n.text("operation.clean-storage")
    case .boot: L10n.text("operation.boot")
    case .shutdown: L10n.text("operation.shutdown")
    case .erase: L10n.text("operation.erase")
    case .delete: L10n.text("operation.delete")
    case .clone: L10n.text("operation.clone")
    case .openSimulator: L10n.text("operation.open-simulator")
    }
  }

  var symbolName: String {
    switch self {
    case .preflight: "checkmark.shield"
    case .optimize: "gauge.with.dots.needle.50percent"
    case .verify: "checkmark.magnifyingglass"
    case .restore: "arrow.uturn.backward.circle"
    case .scanStorage: "externaldrive.badge.magnifyingglass"
    case .cleanStorage: "sparkles"
    case .boot: "power"
    case .shutdown: "power.circle"
    case .erase: "eraser.fill"
    case .delete: "trash.fill"
    case .clone: "plus.square.on.square"
    case .openSimulator: "rectangle.on.rectangle"
    }
  }
}

extension OperationStatus {
  var localizedTitle: String {
    switch self {
    case .prepared: L10n.text("status.prepared")
    case .running: L10n.text("status.running")
    case .succeeded: L10n.text("status.succeeded")
    case .partial: L10n.text("status.partial")
    case .failed: L10n.text("status.failed")
    case .cancelled: L10n.text("status.cancelled")
    }
  }
}

extension OperationPhase {
  var localizedTitle: String {
    switch self {
    case .preflight: L10n.text("phase.preflight")
    case .preparing: L10n.text("phase.preparing")
    case .measuringBefore: L10n.text("phase.measuring-before")
    case .applying: L10n.text("phase.applying")
    case .restarting: L10n.text("phase.restarting")
    case .verifying: L10n.text("phase.verifying")
    case .measuringAfter: L10n.text("phase.measuring-after")
    case .scanningStorage: L10n.text("phase.scanning-storage")
    case .cleaningStorage: L10n.text("phase.cleaning-storage")
    case .deviceAction: L10n.text("phase.device-action")
    case .finalizing: L10n.text("phase.finalizing")
    case .completed: L10n.text("phase.completed")
    }
  }
}
