public enum OperationPhaseProgressState: Sendable, Equatable {
  case waiting
  case running
  case succeeded
  case skipped
  case warning
  case failed
}

extension OperationEvent {
  public var isTerminal: Bool {
    phase == .completed
  }
}

public struct OperationPhaseTimeline: Sendable {
  private let phases: [OperationPhase]
  private let events: [OperationEvent]
  private let phaseAliases: [OperationPhase: OperationPhase]

  public init(
    phases: [OperationPhase],
    events: [OperationEvent],
    phaseAliases: [OperationPhase: OperationPhase] = [:]
  ) {
    self.phases = phases
    self.events = events
    self.phaseAliases = phaseAliases
  }

  public func state(for phase: OperationPhase) -> OperationPhaseProgressState {
    guard
      let phaseIndex = phases.firstIndex(of: phase),
      let currentPhaseIndex = events.compactMap({
        phases.firstIndex(of: visiblePhase(for: $0.phase))
      }).max()
    else {
      return .waiting
    }

    let phaseEvents = events.filter { visiblePhase(for: $0.phase) == phase }
    if phaseEvents.contains(where: { $0.state == .failed }) {
      return .failed
    }
    if phaseEvents.contains(where: { $0.state == .warning }) {
      return .warning
    }

    let latestEvent = phaseEvents.last
    if phaseIndex < currentPhaseIndex {
      switch latestEvent?.state {
      case .warning:
        return .warning
      case .failed:
        return .failed
      case .running, .succeeded:
        return .succeeded
      case nil:
        return .skipped
      }
    }

    guard phaseIndex == currentPhaseIndex, let latestEvent else {
      return .waiting
    }
    switch latestEvent.state {
    case .running:
      return .running
    case .succeeded:
      if let completedCount = latestEvent.completedCount,
        let totalCount = latestEvent.totalCount,
        completedCount < totalCount
      {
        return .running
      }
      return .succeeded
    case .warning:
      return .warning
    case .failed:
      return .failed
    }
  }

  private func visiblePhase(for phase: OperationPhase) -> OperationPhase {
    phaseAliases[phase] ?? phase
  }
}
