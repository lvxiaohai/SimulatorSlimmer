import Testing

@testable import SimulatorSlimmerCore

@Suite("操作阶段时间线")
struct OperationPhaseTimelineBehaviorTests {
  @Test("进入后续阶段时前序运行事件显示为已完成")
  func priorRunningPhasesBecomeCompleted() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")
    let phases: [OperationPhase] = [
      .preflight,
      .preparing,
      .applying,
      .restarting,
      .verifying,
      .completed,
    ]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(.preparing, state: .running, operationID: operationID, deviceID: deviceID),
      event(.applying, state: .succeeded, operationID: operationID, deviceID: deviceID),
      event(.restarting, state: .running, operationID: operationID, deviceID: deviceID),
    ]

    let timeline = OperationPhaseTimeline(phases: phases, events: events)

    #expect(timeline.state(for: .preflight) == .succeeded)
    #expect(timeline.state(for: .preparing) == .succeeded)
    #expect(timeline.state(for: .applying) == .succeeded)
    #expect(timeline.state(for: .restarting) == .running)
    #expect(timeline.state(for: .verifying) == .waiting)
    #expect(timeline.state(for: .completed) == .waiting)
  }

  @Test("前序阶段出现失败后不会被后续成功事件覆盖")
  func earlierFailureRemainsVisible() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "22222222-3333-4444-8555-666666666666")
    let phases: [OperationPhase] = [.preflight, .applying, .restarting]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(.applying, state: .failed, operationID: operationID, deviceID: deviceID),
      event(.applying, state: .succeeded, operationID: operationID, deviceID: deviceID),
      event(.restarting, state: .running, operationID: operationID, deviceID: deviceID),
    ]

    let timeline = OperationPhaseTimeline(phases: phases, events: events)

    #expect(timeline.state(for: .applying) == .failed)
  }

  @Test("前序阶段出现警告后不会被后续成功事件覆盖")
  func earlierWarningRemainsVisible() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "33333333-4444-4555-8666-777777777777")
    let phases: [OperationPhase] = [.preflight, .applying, .restarting]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(.applying, state: .warning, operationID: operationID, deviceID: deviceID),
      event(.applying, state: .succeeded, operationID: operationID, deviceID: deviceID),
      event(.restarting, state: .running, operationID: operationID, deviceID: deviceID),
    ]

    let timeline = OperationPhaseTimeline(phases: phases, events: events)

    #expect(timeline.state(for: .applying) == .warning)
  }

  @Test("当前计数阶段未完成全部项目时保持进行中")
  func incompleteCountedPhaseRemainsRunning() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "44444444-5555-4666-8777-888888888888")
    let phases: [OperationPhase] = [.preflight, .applying, .restarting]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(
        .applying,
        state: .succeeded,
        operationID: operationID,
        deviceID: deviceID,
        completedCount: 40,
        totalCount: 102
      ),
    ]

    let timeline = OperationPhaseTimeline(phases: phases, events: events)

    #expect(timeline.state(for: .preflight) == .succeeded)
    #expect(timeline.state(for: .applying) == .running)
    #expect(timeline.state(for: .restarting) == .waiting)
  }

  @Test("隐藏测量阶段会推进对应的可见阶段")
  func hiddenMeasurementAdvancesVisiblePhase() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "55555555-6666-4777-8888-999999999999")
    let phases: [OperationPhase] = [
      .preflight,
      .preparing,
      .applying,
      .restarting,
      .verifying,
      .completed,
    ]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(.measuringBefore, state: .running, operationID: operationID, deviceID: deviceID),
    ]

    let timeline = OperationPhaseTimeline(
      phases: phases,
      events: events,
      phaseAliases: [.measuringBefore: .preparing]
    )

    #expect(timeline.state(for: .preflight) == .succeeded)
    #expect(timeline.state(for: .preparing) == .running)
    #expect(timeline.state(for: .applying) == .waiting)
  }

  @Test("未执行的前序阶段显示为已跳过")
  func phasesWithoutEventsAreSkipped() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "66666666-7777-4888-8999-AAAAAAAAAAAA")
    let phases: [OperationPhase] = [
      .preflight,
      .preparing,
      .applying,
      .restarting,
      .verifying,
      .completed,
    ]
    let events = [
      event(.preflight, state: .running, operationID: operationID, deviceID: deviceID),
      event(.preparing, state: .running, operationID: operationID, deviceID: deviceID),
      event(.verifying, state: .running, operationID: operationID, deviceID: deviceID),
    ]

    let timeline = OperationPhaseTimeline(phases: phases, events: events)

    #expect(timeline.state(for: .preflight) == .succeeded)
    #expect(timeline.state(for: .preparing) == .succeeded)
    #expect(timeline.state(for: .applying) == .skipped)
    #expect(timeline.state(for: .restarting) == .skipped)
    #expect(timeline.state(for: .verifying) == .running)
  }

  @Test("单项失败事件不会提前结束整个操作")
  func intermediateFailureIsNotTerminal() {
    let operationID = ReceiptID()
    let deviceID = SimulatorID(rawValue: "77777777-8888-4999-8AAA-BBBBBBBBBBBB")
    let intermediateFailure = event(
      .applying,
      state: .failed,
      operationID: operationID,
      deviceID: deviceID
    )
    let terminalFailure = event(
      .completed,
      state: .failed,
      operationID: operationID,
      deviceID: deviceID
    )

    #expect(!intermediateFailure.isTerminal)
    #expect(terminalFailure.isTerminal)
  }

  private func event(
    _ phase: OperationPhase,
    state: OperationEventState,
    operationID: ReceiptID,
    deviceID: SimulatorID,
    completedCount: Int? = nil,
    totalCount: Int? = nil
  ) -> OperationEvent {
    OperationEvent(
      operationID: operationID,
      deviceID: deviceID,
      phase: phase,
      state: state,
      message: phase.rawValue,
      completedCount: completedCount,
      totalCount: totalCount
    )
  }
}
