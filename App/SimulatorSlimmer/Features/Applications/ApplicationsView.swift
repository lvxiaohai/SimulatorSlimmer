import AppKit
import ImageIO
import SimulatorSlimmerCore
import SwiftUI

struct ApplicationsView: View {
  let device: SimulatorDevice
  @Bindable var model: AppModel
  @State private var applicationFilter = ApplicationFilter.user

  private var isBusy: Bool {
    model.isDeviceBusy(device.id)
  }

  private var currentState: ApplicationListState {
    model.applicationListState
  }

  var body: some View {
    Group {
      switch device.state {
      case .shutdown:
        shutdownState
      case .creating, .shuttingDown:
        transitioningState
      case .booted:
        bootedContent
      case .unavailable, .unknown:
        unavailableState
      }
    }
    .accessibilityIdentifier("applications.page")
    .task(id: "\(device.id.rawValue)-\(device.state.rawValue)") {
      model.loadApplications(for: device.id, force: false)
    }
  }

  private var shutdownState: some View {
    emptyPage(
      symbol: "power",
      tint: .orange,
      title: L10n.text("applications.shutdown.title"),
      message: L10n.text("applications.shutdown.message")
    ) {
      Button {
        model.runDeviceOperation(.boot)
      } label: {
        Label("action.boot", systemImage: "power")
      }
      .buttonStyle(PressablePrimaryButtonStyle())
      .disabled(isBusy || !device.isAvailable)
      .help(L10n.text("action.boot.summary"))
      .accessibilityIdentifier("applications.boot")
    }
  }

  private var transitioningState: some View {
    emptyPage(
      symbol: "clock.arrow.circlepath",
      tint: .orange,
      title: L10n.text("applications.transitioning.title"),
      message: L10n.text("applications.transitioning.message")
    ) {
      ProgressView()
        .controlSize(.small)
        .frame(minWidth: InstrumentTheme.minimumHitSize, minHeight: InstrumentTheme.minimumHitSize)
        .accessibilityLabel("applications.loading")
    }
  }

  private var unavailableState: some View {
    emptyPage(
      symbol: "exclamationmark.triangle",
      tint: .secondary,
      title: L10n.text("applications.unavailable.title"),
      message: device.availabilityError ?? L10n.text("applications.unavailable.message")
    ) {}
  }

  @ViewBuilder
  private var bootedContent: some View {
    switch currentState {
    case .loaded(let deviceID, let snapshot) where deviceID == device.id:
      applicationsList(snapshot)
    case .failed(let deviceID, let message) where deviceID == device.id:
      failedState(message)
    case .idle, .loading, .loaded, .failed:
      loadingState
    }
  }

  private var loadingState: some View {
    emptyPage(
      symbol: "app.badge",
      tint: .mint,
      title: L10n.text("applications.loading.title"),
      message: L10n.text("applications.loading.message")
    ) {
      ProgressView()
        .controlSize(.small)
        .frame(minWidth: InstrumentTheme.minimumHitSize, minHeight: InstrumentTheme.minimumHitSize)
        .accessibilityLabel("applications.loading")
    }
  }

  private func failedState(_ message: String) -> some View {
    emptyPage(
      symbol: "exclamationmark.triangle.fill",
      tint: .red,
      title: L10n.text("applications.load-failed.title"),
      message: message
    ) {
      Button("action.retry") {
        model.loadApplications(for: device.id, force: true)
      }
      .buttonStyle(PressablePrimaryButtonStyle())
      .disabled(isBusy)
      .accessibilityIdentifier("applications.retry")
    }
  }

  private func emptyPage<Action: View>(
    symbol: String,
    tint: Color,
    title: String,
    message: String,
    @ViewBuilder action: @escaping () -> Action
  ) -> some View {
    InstrumentPageScroll(alignment: .center) {
      InstrumentEmptyState(
        symbol: symbol,
        tint: tint,
        title: title,
        message: message,
        action: action
      )
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
  }

  private func applicationsList(_ snapshot: SimulatorApplicationListSnapshot) -> some View {
    let visibleApplications = snapshot.applications.filter(applicationFilter.includes)

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("applications.title")
            .font(.headline)
          Text(L10n.formatted("applications.count", visibleApplications.count))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Spacer(minLength: 12)
          Picker("applications.filter.label", selection: $applicationFilter) {
            ForEach(ApplicationFilter.allCases) { filter in
              Text(filter.title).tag(filter)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .controlSize(.small)
          .fixedSize()
          .minimumHitArea()
          .accessibilityLabel("applications.filter.label")
          .accessibilityIdentifier("applications.filter")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: InstrumentTheme.minimumHitSize)

        if visibleApplications.isEmpty {
          InstrumentEmptyState(
            symbol: "app.dashed",
            tint: .secondary,
            title: applicationFilter.emptyTitle,
            message: applicationFilter.emptyMessage
          ) {}
          .frame(maxWidth: .infinity)
          .frame(minHeight: 280)
        } else {
          LazyVStack(spacing: 8) {
            ForEach(visibleApplications) { application in
              ApplicationRow(
                application: application,
                memory: snapshot.memoryByBundleIdentifier[application.bundleIdentifier],
                memoryError: snapshot.memoryError,
                isOpening: model.openingApplicationBundleID == application.bundleIdentifier,
                isDisabled: isBusy,
                openDataContainer: {
                  model.openApplicationDataContainer(application, deviceID: device.id)
                }
              )
            }
          }
        }
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.vertical, 12)
    }
    .refreshable {
      model.loadApplications(for: device.id, force: true)
    }
  }
}

private enum ApplicationFilter: String, CaseIterable, Identifiable {
  case user
  case system
  case all

  var id: Self { self }

  var title: String {
    switch self {
    case .user: L10n.text("applications.filter.user")
    case .system: L10n.text("applications.filter.system")
    case .all: L10n.text("applications.filter.all")
    }
  }

  var emptyTitle: String {
    switch self {
    case .user: L10n.text("applications.empty.user.title")
    case .system: L10n.text("applications.empty.system.title")
    case .all: L10n.text("applications.empty.all.title")
    }
  }

  var emptyMessage: String {
    switch self {
    case .user: L10n.text("applications.empty.user.message")
    case .system: L10n.text("applications.empty.system.message")
    case .all: L10n.text("applications.empty.all.message")
    }
  }

  func includes(_ application: SimulatorApplication) -> Bool {
    switch self {
    case .user:
      application.kind == .user
    case .system:
      application.kind == .system
    case .all:
      true
    }
  }
}

private struct ApplicationRow: View {
  let application: SimulatorApplication
  let memory: ApplicationMemorySnapshot?
  let memoryError: String?
  let isOpening: Bool
  let isDisabled: Bool
  let openDataContainer: () -> Void

  @State private var isHovered = false

  private var version: String? {
    switch (application.marketingVersion, application.buildVersion) {
    case (.some(let marketing), .some(let build)):
      L10n.formatted("applications.version.marketing-build", marketing, build)
    case (.some(let marketing), .none):
      L10n.formatted("applications.version.marketing", marketing)
    case (.none, .some(let build)):
      L10n.formatted("applications.version.build", build)
    case (.none, .none):
      nil
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      ApplicationIcon(icon: application.icon, bundleURL: application.bundleURL)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(application.displayName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
          ApplicationKindBadge(kind: application.kind)
        }

        Text(application.bundleIdentifier)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        HStack(spacing: 10) {
          if let version {
            Text(version)
              .lineLimit(1)
          }
          ApplicationMemoryLabel(memory: memory, error: memoryError)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      ApplicationFolderButton(
        isOpening: isOpening,
        isDisabled: isDisabled,
        hasKnownDataContainer: application.dataContainerURL != nil,
        action: openDataContainer
      )
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background {
      RoundedRectangle(cornerRadius: InstrumentTheme.innerRadius, style: .continuous)
        .fill(isHovered ? Color.primary.opacity(0.045) : Color.instrumentRaised.opacity(0.55))
    }
    .overlay {
      RoundedRectangle(cornerRadius: InstrumentTheme.innerRadius, style: .continuous)
        .stroke(Color.primary.opacity(isHovered ? 0.09 : 0.045), lineWidth: 1)
    }
    .shadow(color: .black.opacity(isHovered ? 0.045 : 0.02), radius: isHovered ? 5 : 2, y: 1)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
  }
}

private struct ApplicationMemoryLabel: View {
  let memory: ApplicationMemorySnapshot?
  let error: String?

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: "memorychip")
    }
    .lineLimit(1)
    .help(helpText)
    .accessibilityLabel(accessibilityText)
  }

  private var title: String {
    if let memory {
      return ValueFormatter.bytes(memory.bytes)
    }
    return error == nil
      ? L10n.text("applications.memory.not-resident")
      : L10n.text("applications.memory.unavailable")
  }

  private var helpText: String {
    if let memory {
      return L10n.formatted(
        "applications.memory.detail",
        memory.processCount,
        memory.collectedAt.formatted(date: .omitted, time: .shortened)
      )
    }
    return error ?? L10n.text("applications.memory.not-resident.hint")
  }

  private var accessibilityText: String {
    if memory != nil {
      return "\(title)，\(helpText)"
    }
    return title
  }
}

private struct ApplicationFolderButton: View {
  let isOpening: Bool
  let isDisabled: Bool
  let hasKnownDataContainer: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Group {
        if isOpening {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("applications.open-folder", systemImage: "folder")
        }
      }
      .frame(minHeight: InstrumentTheme.compactButtonMinimumHeight)
    }
    .buttonStyle(ApplicationFolderButtonStyle(isHovered: isHovered))
    .disabled(isDisabled || isOpening)
    .minimumHitArea()
    .onHover { isHovered = $0 }
    .help(
      hasKnownDataContainer
        ? L10n.text("applications.open-folder")
        : L10n.text("applications.folder-unavailable.message")
    )
    .accessibilityLabel("applications.open-folder")
    .accessibilityHint(
      hasKnownDataContainer
        ? L10n.text("applications.open-folder.hint")
        : L10n.text("applications.folder-unavailable.message")
    )
  }
}

private struct ApplicationFolderButtonStyle: ButtonStyle {
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.medium))
      .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
      .padding(.horizontal, 9)
      .background(
        isHovered && isEnabled ? Color.accentColor.opacity(0.10) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.accentColor.opacity(isHovered && isEnabled ? 0.25 : 0.12), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(isEnabled ? 1 : 0.6)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.12),
        value: configuration.isPressed
      )
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
  }
}

private struct ApplicationKindBadge: View {
  let kind: SimulatorApplicationKind

  private var title: String {
    switch kind {
    case .user: L10n.text("applications.kind.user")
    case .system: L10n.text("applications.kind.system")
    case .unknown: L10n.text("applications.kind.unknown")
    }
  }

  private var tint: Color {
    switch kind {
    case .user: .mint
    case .system: .secondary
    case .unknown: .orange
    }
  }

  var body: some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(tint.opacity(0.10), in: Capsule())
      .fixedSize()
  }
}

private struct ApplicationIcon: View {
  let icon: SimulatorApplicationIcon
  let bundleURL: URL?
  @Environment(\.colorScheme) private var colorScheme
  @State private var image: NSImage?

  private var sourceIdentity: String {
    "\(icon.fileURL?.path ?? "")|\(bundleURL?.path ?? "")"
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFill()
      } else {
        Image(systemName: "app.dashed")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.primary.opacity(0.045))
      }
    }
    .frame(width: 42, height: 42)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.10), lineWidth: 1)
    }
    .accessibilityHidden(true)
    .task(id: sourceIdentity) {
      await Task.yield()
      image = Self.loadImage(iconURL: icon.fileURL, bundleURL: bundleURL)
    }
  }

  private static func loadImage(iconURL: URL?, bundleURL: URL?) -> NSImage? {
    if let iconURL, let thumbnail = thumbnail(at: iconURL) {
      return thumbnail
    }
    guard let bundleURL else { return nil }
    let workspaceIcon = NSWorkspace.shared.icon(forFile: bundleURL.path)
    return workspaceIcon.isValid ? workspaceIcon : nil
  }

  private static func thumbnail(at url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 128,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
