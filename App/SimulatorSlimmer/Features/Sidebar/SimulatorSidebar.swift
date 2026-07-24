import SimulatorSlimmerCore
import SwiftUI

struct SimulatorSidebar: View {
  @Bindable var model: AppModel
  @AppStorage("showUnavailableDevices") private var showUnavailableDevices = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var hasKeyboardFocus: Bool

  var body: some View {
    VStack(spacing: 0) {
      workspaceActions
      Divider()

      ScrollViewReader { proxy in
        List {
          ForEach(visibleRuntimeGroups) { group in
            Section(group.name) {
              ForEach(group.devices) { device in
                let selection = SidebarSelection.device(device.id)
                sidebarButton(for: selection) {
                  SimulatorSidebarRow(
                    device: device,
                    operation: model.operations[device.id],
                    isSelected: model.sidebarSelection == selection
                  )
                }
              }
            }
          }
        }
        .listStyle(.sidebar)
        .defaultScrollAnchor(.top)
        .contentMargins(.top, 0, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
          Color.clear
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .scrollBounceBehavior(.basedOnSize)
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
          guard let next = moveSelection(.up) else {
            return visibleSelections.isEmpty ? .ignored : .handled
          }
          scrollToSelection(next, using: proxy)
          return .handled
        }
        .onKeyPress(.downArrow) {
          guard let next = moveSelection(.down) else {
            return visibleSelections.isEmpty ? .ignored : .handled
          }
          scrollToSelection(next, using: proxy)
          return .handled
        }
        .onChange(of: visibleDeviceSelections) { _, selections in
          reconcileDeviceSelection(with: selections)
        }
      }
    }
    .navigationTitle("app.name")
  }

  private var workspaceActions: some View {
    HStack(spacing: 6) {
      SidebarHeaderButton(
        title: "sidebar.batch-optimization",
        systemImage: "rectangle.stack.badge.play",
        isActive: model.workspaceModal == .batchOptimization,
        showsProgress: model.isPreparingBatchPreview || model.batchRun?.isRunning == true
      ) {
        model.showBatchOptimization()
      }
      .accessibilityIdentifier("sidebar.batch-optimization")

      Spacer(minLength: 4)

      SidebarHeaderButton(
        title: nil,
        systemImage: "plus",
        isActive: model.workspaceModal == .createSimulator
      ) {
        model.showCreateSimulator()
      }
      .accessibilityLabel("sidebar.create-simulator")
      .accessibilityIdentifier("sidebar.create-simulator")
      .help("sidebar.create-simulator")

      SidebarHeaderButton(
        title: nil,
        systemImage: "gearshape",
        isActive: model.workspaceModal == .settings
      ) {
        model.showSettings()
      }
      .accessibilityLabel("sidebar.settings")
      .accessibilityIdentifier("sidebar.settings")
      .help("sidebar.settings")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
  }

  private var visibleRuntimeGroups: [VisibleRuntimeGroup] {
    model.runtimeGroups.compactMap { group in
      let devices = group.devices.filter {
        showUnavailableDevices || $0.isAvailable
      }
      guard !devices.isEmpty else { return nil }
      return VisibleRuntimeGroup(
        id: group.id,
        name: group.runtime.name,
        devices: devices
      )
    }
  }

  private var visibleSelections: [SidebarSelection] {
    visibleDeviceSelections
  }

  private var visibleDeviceSelections: [SidebarSelection] {
    visibleRuntimeGroups.flatMap { group in
      group.devices.map { SidebarSelection.device($0.id) }
    }
  }

  private func sidebarButton<Content: View>(
    for selection: SidebarSelection,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      WindowFocus.endTextEditing()
      model.sidebarSelection = selection
      hasKeyboardFocus = true
    } label: {
      content()
    }
    .buttonStyle(.plain)
    .id(selection)
    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityAddTraits(model.sidebarSelection == selection ? .isSelected : [])
  }

  private func moveSelection(_ direction: MoveCommandDirection) -> SidebarSelection? {
    guard let selection = model.sidebarSelection else {
      guard let first = visibleSelections.first else { return nil }
      model.sidebarSelection = first
      return first
    }
    guard let index = visibleSelections.firstIndex(of: selection) else { return nil }

    let nextIndex: Int
    switch direction {
    case .up:
      guard index > visibleSelections.startIndex else { return nil }
      nextIndex = visibleSelections.index(before: index)
    case .down:
      guard index < visibleSelections.index(before: visibleSelections.endIndex) else { return nil }
      nextIndex = visibleSelections.index(after: index)
    default:
      return nil
    }

    let next = visibleSelections[nextIndex]
    model.sidebarSelection = next
    return next
  }

  private func scrollToSelection(
    _ selection: SidebarSelection,
    using proxy: ScrollViewProxy
  ) {
    if reduceMotion {
      proxy.scrollTo(selection)
    } else {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(selection)
      }
    }
  }

  private func reconcileDeviceSelection(with visibleDevices: [SidebarSelection]) {
    guard
      let selection = model.sidebarSelection,
      case .device = selection,
      !visibleDevices.contains(selection)
    else { return }

    model.sidebarSelection = visibleDevices.first
  }
}

private struct VisibleRuntimeGroup: Identifiable {
  let id: String
  let name: String
  let devices: [SimulatorDevice]
}

private struct SidebarHeaderButton: View {
  let title: LocalizedStringResource?
  let systemImage: String
  let isActive: Bool
  var showsProgress = false
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
        if let title {
          Text(title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
        }
        if showsProgress {
          ProgressView()
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, title == nil ? 0 : 10)
      .frame(
        minWidth: InstrumentTheme.minimumHitSize,
        minHeight: InstrumentTheme.minimumHitSize
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(
      SidebarHeaderButtonStyle(
        isActive: isActive,
        isHovered: isHovered
      )
    )
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }
}

private struct SidebarHeaderButtonStyle: ButtonStyle {
  let isActive: Bool
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isActive ? Color.mint : Color.primary)
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.1),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.12),
        value: isHovered
      )
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed { return Color.primary.opacity(0.1) }
    if isActive { return Color.mint.opacity(0.12) }
    return isHovered ? Color.primary.opacity(0.055) : .clear
  }
}

private struct SimulatorSidebarRow: View {
  let device: SimulatorDevice
  let operation: PresentedOperation?
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: deviceSymbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(device.isAvailable ? .primary : .secondary)
        .frame(width: 22)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(device.name)
          .lineLimit(1)
        HStack(spacing: 5) {
          Image(systemName: device.state.symbolName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(stateTint)
          Text(device.state.localizedTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 4)

      if operation?.isRunning == true {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("accessibility.device-operation-running")
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background {
      InstrumentSelectionBackground(isSelected: isSelected, isHovered: isHovered)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onHover { isHovered = $0 }
    .opacity(device.isAvailable ? 1 : 0.62)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(device.name)
    .accessibilityValue("\(device.runtimeName)，\(device.state.localizedTitle)")
  }

  private var deviceSymbol: String {
    device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
      ? "ipad"
      : "iphone"
  }

  private var stateTint: Color {
    switch device.state {
    case .booted: .mint
    case .creating, .shuttingDown: .orange
    case .unavailable: .red
    case .shutdown, .unknown: .secondary
    }
  }
}
