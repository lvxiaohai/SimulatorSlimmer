import AppKit
import SimulatorSlimmerCore
import SwiftUI

struct InstrumentCard<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(InstrumentTheme.cardPadding)
      .background(
        Color.instrumentRaised.opacity(colorScheme == .dark ? 0.62 : 0.72),
        in: cardShape
      )
      .overlay {
        cardShape.stroke(
          outlineColor,
          lineWidth: colorSchemeContrast == .increased ? 1 : 0
        )
      }
      .shadow(
        color: colorScheme == .dark ? .white.opacity(0.055) : .black.opacity(0.07),
        radius: 0.6
      )
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 7, y: 3)
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: InstrumentTheme.cardRadius, style: .continuous)
  }

  private var outlineColor: Color {
    if colorScheme == .dark {
      return .white.opacity(0.16)
    }
    return .black.opacity(0.13)
  }
}

struct InstrumentPageScroll<Content: View>: View {
  let alignment: HorizontalAlignment
  let spacing: CGFloat
  @ViewBuilder let content: () -> Content

  init(
    alignment: HorizontalAlignment = .leading,
    spacing: CGFloat = 16,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.alignment = alignment
    self.spacing = spacing
    self.content = content
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: alignment, spacing: spacing) {
        content()
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.bottom, InstrumentTheme.pagePadding)
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

struct InstrumentEmptyState<Action: View>: View {
  let symbol: String
  let badgeSymbol: String?
  let tint: Color
  let title: String
  let message: String
  @ViewBuilder let action: () -> Action

  init(
    symbol: String,
    badgeSymbol: String? = nil,
    tint: Color,
    title: String,
    message: String,
    @ViewBuilder action: @escaping () -> Action
  ) {
    self.symbol = symbol
    self.badgeSymbol = badgeSymbol
    self.tint = tint
    self.title = title
    self.message = message
    self.action = action
  }

  var body: some View {
    InstrumentCard {
      VStack(spacing: 14) {
        icon

        VStack(spacing: 5) {
          Text(title)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380)

        action()
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
    }
    .frame(maxWidth: 440)
  }

  private var icon: some View {
    ZStack {
      Circle()
        .fill(tint.opacity(0.10))
      Image(systemName: symbol)
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: 25, weight: .medium))
        .foregroundStyle(tint)
    }
    .frame(width: 58, height: 58)
    .overlay(alignment: .bottomTrailing) {
      if let badgeSymbol {
        Image(systemName: badgeSymbol)
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
          .background(tint.gradient, in: Circle())
          .offset(x: 2, y: 2)
      }
    }
    .accessibilityHidden(true)
  }
}

struct InstrumentSelectionBackground: View {
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(backgroundColor)
      .overlay(alignment: .leading) {
        if isSelected {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: 26)
            .padding(.leading, 3)
            .transition(.opacity)
        }
      }
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color.accentColor.opacity(0.10)
    }
    if isHovered {
      return Color.primary.opacity(0.045)
    }
    return .clear
  }
}

struct InstrumentToast: View {
  let message: String

  var body: some View {
    Label {
      Text(message)
        .font(.callout.weight(.medium))
    } icon: {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.mint)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: InstrumentTheme.minimumHitSize)
    .background(.regularMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    .fixedSize()
    .accessibilityElement(children: .combine)
    .onAppear {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: message,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
    }
  }
}

struct InstrumentSectionLabel: View {
  let title: LocalizedStringResource
  var detail: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .font(.headline)
      Spacer(minLength: 12)
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct MetricCard: View {
  let eyebrow: LocalizedStringResource
  let value: String
  let unitDetail: String?
  let symbol: String
  let tint: Color
  var progress: Double?

  var body: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label {
            Text(eyebrow)
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          } icon: {
            Image(systemName: symbol)
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(tint)
          }
          Spacer()
          Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .shadow(color: tint.opacity(0.55), radius: 4)
            .accessibilityHidden(true)
        }

        Text(value)
          .font(.title.weight(.semibold))
          .fontDesign(.rounded)
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(2)

        HStack(spacing: 8) {
          if let progress {
            GeometryReader { proxy in
              Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                  Capsule()
                    .fill(tint.opacity(0.78))
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
          }
          if let unitDetail {
            Text(unitDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(minHeight: 16)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(eyebrow))
    .accessibilityValue(value)
    .accessibilityHint(unitDetail ?? "")
  }
}

struct SimulatorStateChip: View {
  let state: SimulatorState

  var tint: Color {
    switch state {
    case .booted: .mint
    case .creating, .shuttingDown: .orange
    case .unavailable: .red
    case .shutdown, .unknown: .secondary
    }
  }

  var body: some View {
    Label(state.localizedTitle, systemImage: state.symbolName)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(tint.opacity(0.1), in: Capsule())
      .accessibilityElement(children: .combine)
  }
}

struct RiskBadge: View {
  let risk: ServiceRisk

  var body: some View {
    Text(risk.localizedTitle)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(risk.tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(risk.tint.opacity(0.1), in: Capsule())
      .accessibilityLabel(L10n.formatted("accessibility.risk", risk.localizedTitle))
  }
}

struct NoticeStrip: View {
  enum Tone {
    case info
    case success
    case warning
    case error

    var tint: Color {
      switch self {
      case .info: .blue
      case .success: .mint
      case .warning: .orange
      case .error: .red
      }
    }

    var symbol: String {
      switch self {
      case .info: "info.circle.fill"
      case .success: "checkmark.circle.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .error: "xmark.circle.fill"
      }
    }
  }

  let tone: Tone
  let title: String
  var message: String?
  var actionTitle: String?
  var action: (() -> Void)?
  var actionSymbol: String?

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      noticeContent

      if let actionTitle, let action {
        Button(action: action) {
          if let actionSymbol {
            Label(actionTitle, systemImage: actionSymbol)
          } else {
            Text(actionTitle)
          }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(tone.tint)
        .minimumHitArea()
        .fixedSize()
      }
    }
    .padding(12)
    .background(tone.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
  }

  private var noticeContent: some View {
    HStack(alignment: message == nil ? .center : .top, spacing: 10) {
      ZStack {
        Circle()
          .fill(tone.tint.opacity(0.12))
        Image(systemName: tone.symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tone.tint)
      }
      .frame(width: 30, height: 30)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        if let message {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct OperationResultBanner: View {
  let receipt: OperationReceipt

  private var tone: NoticeStrip.Tone {
    switch receipt.status {
    case .succeeded: .success
    case .partial: .warning
    case .failed: .error
    case .prepared, .running, .cancelled: .info
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      NoticeStrip(
        tone: tone,
        title: receipt.status.localizedTitle,
        message: resultMessage
      )

      if receipt.kind == .optimize,
        let before = receipt.memoryBefore,
        let after = receipt.memoryAfter
      {
        HStack(spacing: 0) {
          resultValue(
            title: L10n.text("result.before"),
            value: ValueFormatter.bytes(before.bytes)
          )
          Divider().frame(height: 32)
          resultValue(
            title: L10n.text("result.after"),
            value: ValueFormatter.bytes(after.bytes)
          )
          if let delta = receipt.reclaimedBytes {
            Divider().frame(height: 32)
            resultValue(
              title: MemoryDeltaPresentation.title(for: delta),
              value: MemoryDeltaPresentation.value(for: delta, before: before.bytes),
              tint: MemoryDeltaPresentation.tint(for: delta)
            )
          }
        }
        .padding(.horizontal, 4)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var resultMessage: String {
    switch receipt.status {
    case .succeeded: return L10n.text("result.succeeded.message")
    case .partial: return L10n.text("result.partial.message")
    case .failed: return receipt.messages.last ?? L10n.text("result.failed.message")
    case .cancelled: return L10n.text("result.cancelled.message")
    case .prepared, .running: return L10n.text("result.running.message")
    }
  }

  private func resultValue(title: String, value: String, tint: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct OperationProgressPanel: View {
  let presentation: PresentedOperation
  let stop: () -> Void

  private var operationKind: OperationKind { presentation.operation.kind }

  var body: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 12) {
          ZStack {
            Circle()
              .fill(Color.mint.opacity(0.12))
            Image(systemName: operationKind.symbolName)
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(.mint)
          }
          .frame(width: 40, height: 40)

          VStack(alignment: .leading, spacing: 3) {
            Text(L10n.formatted("operation.running.title", operationKind.localizedTitle))
              .font(.headline)
            Text(presentation.latestEvent?.message ?? L10n.text("operation.preparing.message"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(L10n.text("accessibility.operation-running"))
        }

        phaseRows

        HStack {
          if presentation.stopRequested {
            Label(
              L10n.text("operation.stop-requested"),
              systemImage: "hourglass"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          } else {
            Spacer()
            Button(L10n.text("operation.stop-after-step"), action: stop)
              .buttonStyle(.borderless)
              .minimumHitArea()
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var phaseRows: some View {
    let phases = visiblePhases
    let timeline = OperationPhaseTimeline(
      phases: phases,
      events: presentation.events,
      phaseAliases: phaseAliases
    )
    VStack(alignment: .leading, spacing: 10) {
      ForEach(phases, id: \.self) { phase in
        let state = phaseState(phase, timeline: timeline)
        HStack(spacing: 10) {
          Image(systemName: state.symbol)
            .foregroundStyle(state.tint)
            .frame(width: 18)
          Text(phase.localizedTitle)
            .font(.subheadline)
            .foregroundStyle(state.isWaiting ? .secondary : .primary)
          Spacer()
          if let event = presentation.events.last(where: { $0.phase == phase }),
            let completed = event.completedCount,
            let total = event.totalCount
          {
            Text("\(completed) / \(total)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          } else {
            Text(state.label)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("operation.progress.phase.\(phase.rawValue)")
        .accessibilityValue(state.label)
      }
    }
  }

  private var visiblePhases: [OperationPhase] {
    switch operationKind {
    case .preflight:
      [.preflight, .completed]
    case .optimize, .restore:
      [.preflight, .preparing, .applying, .restarting, .verifying, .completed]
    case .verify:
      [.preflight, .verifying, .completed]
    case .scanStorage:
      [.preflight, .scanningStorage, .finalizing, .completed]
    case .cleanStorage:
      [.preflight, .cleaningStorage, .verifying, .completed]
    case .boot, .shutdown, .erase, .delete, .clone, .openSimulator:
      [.preflight, .deviceAction, .verifying, .completed]
    }
  }

  private var phaseAliases: [OperationPhase: OperationPhase] {
    switch operationKind {
    case .optimize, .restore:
      [
        .measuringBefore: .preparing,
        .measuringAfter: .verifying,
        .finalizing: .verifying,
      ]
    case .verify:
      [
        .preparing: .preflight,
        .measuringAfter: .verifying,
        .finalizing: .verifying,
      ]
    case .preflight, .scanStorage, .cleanStorage, .boot, .shutdown, .erase, .delete, .clone,
      .openSimulator:
      [:]
    }
  }

  private func phaseState(
    _ phase: OperationPhase,
    timeline: OperationPhaseTimeline
  ) -> PhaseAppearance {
    switch timeline.state(for: phase) {
    case .waiting:
      PhaseAppearance(
        symbol: "circle",
        tint: .secondary,
        label: L10n.text("progress.waiting"),
        isWaiting: true
      )
    case .running:
      PhaseAppearance(
        symbol: "circle.dotted",
        tint: .mint,
        label: L10n.text("progress.running"),
        isWaiting: false
      )
    case .succeeded:
      PhaseAppearance(
        symbol: "checkmark.circle.fill",
        tint: .mint,
        label: L10n.text("progress.completed"),
        isWaiting: false
      )
    case .skipped:
      PhaseAppearance(
        symbol: "minus.circle.fill",
        tint: .secondary,
        label: L10n.text("progress.skipped"),
        isWaiting: false
      )
    case .warning:
      PhaseAppearance(
        symbol: "exclamationmark.circle.fill",
        tint: .orange,
        label: L10n.text("progress.warning"),
        isWaiting: false
      )
    case .failed:
      PhaseAppearance(
        symbol: "xmark.circle.fill",
        tint: .red,
        label: L10n.text("progress.failed"),
        isWaiting: false
      )
    }
  }
}

private struct PhaseAppearance {
  let symbol: String
  let tint: Color
  let label: String
  let isWaiting: Bool
}

struct LoadingDetailView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("loading.device-details")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}
