import AppKit
import SimulatorSlimmerCore
import SwiftUI

enum InstrumentTheme {
  static let pagePadding: CGFloat = 20
  static let cardPadding: CGFloat = 14
  static let cardRadius: CGFloat = 16
  static let innerRadius: CGFloat = 10
  static let compactButtonMinimumHeight: CGFloat = 30
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

  let tint: Color
  let foreground: Color

  init(tint: Color = .mint, foreground: Color = .white) {
    self.tint = tint
    self.foreground = foreground
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 14)
      .padding(.vertical, 5)
      .frame(minHeight: InstrumentTheme.compactButtonMinimumHeight)
      .background(
        isEnabled
          ? LinearGradient(
            colors: [tint, tint.opacity(0.82)],
            startPoint: .leading,
            endPoint: .trailing
          )
          : LinearGradient(
            colors: [.gray.opacity(0.5), .gray.opacity(0.45)],
            startPoint: .leading,
            endPoint: .trailing
          ),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .shadow(color: tint.opacity(isEnabled ? 0.16 : 0), radius: 4, y: 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(isEnabled ? 1 : 0.72)
      .frame(minHeight: InstrumentTheme.minimumHitSize)
      .contentShape(Rectangle())
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

struct InstrumentDisclosureGroupStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      InstrumentDisclosureHeader(
        isExpanded: configuration.$isExpanded,
        label: { configuration.label }
      )

      if configuration.isExpanded {
        configuration.content
      }
    }
  }
}

private struct InstrumentDisclosureHeader<Label: View>: View {
  @Binding var isExpanded: Bool
  @ViewBuilder let label: () -> Label

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    Button {
      if reduceMotion {
        isExpanded.toggle()
      } else {
        withAnimation(.easeOut(duration: 0.16)) {
          isExpanded.toggle()
        }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)

        label()
      }
      .padding(.trailing, 16)
      .frame(
        maxWidth: .infinity,
        minHeight: InstrumentTheme.minimumHitSize,
        alignment: .leading
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(
      InstrumentDisclosureButtonStyle(
        isExpanded: isExpanded,
        isHovered: isHovered
      )
    )
    .onHover { isHovered = $0 }
    .accessibilityValue(
      isExpanded
        ? L10n.text("disclosure.expanded")
        : L10n.text("disclosure.collapsed")
    )
  }
}

private struct InstrumentDisclosureButtonStyle: ButtonStyle {
  let isExpanded: Bool
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
      }
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.1),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.12),
        value: isHovered
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.16),
        value: isExpanded
      )
  }

  private func backgroundOpacity(isPressed: Bool) -> Double {
    if isPressed {
      return 0.07
    }
    if isExpanded {
      return isHovered ? 0.055 : 0.04
    }
    return isHovered ? 0.04 : 0
  }
}

extension View {
  func minimumHitArea() -> some View {
    modifier(MinimumHitArea())
  }

  /// 点击非文本内容时结束当前搜索或文本输入，但不清除按钮、列表等键盘焦点。
  func dismissWindowTextEditingOnTap() -> some View {
    simultaneousGesture(
      TapGesture().onEnded {
        WindowFocus.endTextEditing()
      }
    )
  }

  /// 防止窗口或工作表出现时把键盘焦点自动放到首个按钮上。
  ///
  /// 需要立即输入的确认表单不应使用此修饰器，而应显式聚焦输入框。
  func suppressInitialFocus() -> some View {
    background(InitialFocusSuppressor())
  }
}

@MainActor
enum WindowFocus {
  static func endTextEditing() {
    guard
      let window = NSApp.keyWindow,
      let textView = window.firstResponder as? NSTextView,
      textView.isFieldEditor
    else { return }
    window.makeFirstResponder(nil)
  }
}

private struct InitialFocusSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> InitialFocusSuppressorView {
    InitialFocusSuppressorView()
  }

  func updateNSView(_ nsView: InitialFocusSuppressorView, context: Context) {}
}

@MainActor
private final class InitialFocusSuppressorView: NSView {
  private var didSuppressInitialFocus = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !didSuppressInitialFocus else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self, let window, !didSuppressInitialFocus else { return }
      window.makeFirstResponder(nil)
      didSuppressInitialFocus = true
    }
  }
}
