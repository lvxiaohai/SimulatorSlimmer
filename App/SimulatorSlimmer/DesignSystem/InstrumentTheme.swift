import SimulatorSlimmerCore
import SwiftUI

enum InstrumentTheme {
  static let pagePadding: CGFloat = 24
  static let cardPadding: CGFloat = 16
  static let cardRadius: CGFloat = 18
  static let innerRadius: CGFloat = 10
  static let minimumHitSize: CGFloat = 40

  static let mintGradient = LinearGradient(
    colors: [.mint, .green.opacity(0.82)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}

extension Color {
  static let instrumentBackground = Color(nsColor: .windowBackgroundColor)
  static let instrumentRaised = Color(nsColor: .controlBackgroundColor)
  static let instrumentSecondary = Color(nsColor: .underPageBackgroundColor)
}

extension ServiceRisk {
  var tint: Color {
    switch self {
    case .low: .mint
    case .moderate: .orange
    case .high: .red
    case .protected: .secondary
    }
  }

  var localizedTitle: String {
    switch self {
    case .low: L10n.text("risk.low")
    case .moderate: L10n.text("risk.moderate")
    case .high: L10n.text("risk.high")
    case .protected: L10n.text("risk.protected")
    }
  }
}

extension OperationStatus {
  var tint: Color {
    switch self {
    case .prepared, .running: .blue
    case .succeeded: .mint
    case .partial: .orange
    case .failed: .red
    case .cancelled: .secondary
    }
  }

  var symbolName: String {
    switch self {
    case .prepared: "doc.badge.clock"
    case .running: "progress.indicator"
    case .succeeded: "checkmark.circle.fill"
    case .partial: "exclamationmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "minus.circle.fill"
    }
  }
}

enum ValueFormatter {
  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
  }

  static func shortIdentifier(_ value: String) -> String {
    guard value.count > 13 else { return value }
    return "\(value.prefix(8))…\(value.suffix(4))"
  }

  static func percent(delta: Int64, before: Int64) -> String? {
    guard before > 0 else { return nil }
    return (abs(Double(delta)) / Double(before)).formatted(
      .percent.precision(.fractionLength(0))
    )
  }
}

enum MemoryDeltaPresentation {
  static func title(for delta: Int64) -> String {
    if delta > 0 { return L10n.text("result.reclaimed") }
    if delta < 0 { return L10n.text("result.increased") }
    return L10n.text("result.unchanged")
  }

  static func value(for delta: Int64, before: Int64) -> String {
    let magnitude = delta == .min ? Int64.max : abs(delta)
    let bytes = ValueFormatter.bytes(magnitude)
    guard delta != 0, let percent = ValueFormatter.percent(delta: delta, before: before) else {
      return bytes
    }
    return L10n.formatted("result.delta-with-percent", bytes, percent)
  }

  static func tint(for delta: Int64) -> Color {
    if delta > 0 { return .mint }
    if delta < 0 { return .orange }
    return .secondary
  }
}

struct PressablePrimaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .frame(minHeight: InstrumentTheme.minimumHitSize)
      .background(
        isEnabled
          ? InstrumentTheme.mintGradient
          : LinearGradient(
            colors: [.gray.opacity(0.5), .gray.opacity(0.45)],
            startPoint: .leading,
            endPoint: .trailing
          ),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .shadow(color: .mint.opacity(isEnabled ? 0.18 : 0), radius: 8, y: 3)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.12),
        value: configuration.isPressed
      )
  }
}

struct MinimumHitArea: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(
        minWidth: InstrumentTheme.minimumHitSize,
        minHeight: InstrumentTheme.minimumHitSize
      )
      .contentShape(Rectangle())
  }
}

extension View {
  func minimumHitArea() -> some View {
    modifier(MinimumHitArea())
  }
}
