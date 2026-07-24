import SimulatorSlimmerCore
import SwiftUI

struct OperationFlowSheet: View {
  let presentation: PreviewPresentation
  @Bindable var model: AppModel

  private var operation: PresentedOperation? {
    guard
      let operation = model.operations[presentation.preview.operation.deviceID],
      operation.isRunning
    else {
      return nil
    }
    return operation
  }

  var body: some View {
    if let operation {
      OperationExecutionSheet(
        presentation: operation,
        stop: model.requestStop
      )
    } else {
      OperationPreviewSheet(
        presentation: presentation,
        cancel: { model.previewPresentation = nil },
        confirm: model.runPreviewedOperation
      )
    }
  }
}

private struct OperationExecutionSheet: View {
  let presentation: PresentedOperation
  let stop: () -> Void

  var body: some View {
    ScrollView {
      OperationProgressPanel(
        presentation: presentation,
        stop: stop
      )
      .padding(20)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(
      minWidth: 560,
      idealWidth: 620,
      minHeight: 400,
      idealHeight: 500
    )
    .background(Color.instrumentBackground)
    .interactiveDismissDisabled()
    .suppressInitialFocus()
    .accessibilityIdentifier("operation-execution.sheet")
  }
}

struct OperationPreviewSheet: View {
  let presentation: PreviewPresentation
  let cancel: () -> Void
  let confirm: () -> Void

  private var preview: OperationPreview { presentation.preview }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader
      Divider()

      ScrollView {
        previewContent
          .padding(20)
      }
      .scrollBounceBehavior(.basedOnSize)

      Divider()
      HStack {
        Text(safetyNote)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(
          presentation.confirmsExecution
            ? L10n.text("action.cancel")
            : L10n.text("action.close")
        ) {
          cancel()
        }
        .keyboardShortcut(.cancelAction)
        .minimumHitArea()

        if presentation.confirmsExecution {
          if allowsDefaultAction {
            executeButton
              .keyboardShortcut(.defaultAction)
          } else {
            executeButton
          }
        }
      }
      .padding(16)
    }
    .frame(
      minWidth: 560,
      idealWidth: 620,
      minHeight: minimumSheetHeight,
      idealHeight: idealSheetHeight
    )
    .background(Color.instrumentBackground)
    .suppressInitialFocus()
    .accessibilityIdentifier("operation-preview.sheet")
  }

  @ViewBuilder
  private var previewContent: some View {
    if usesImpactLayout {
      VStack(alignment: .leading, spacing: 14) {
        impactCard
        previewWarnings
      }
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity, alignment: .top)
    } else {
      VStack(alignment: .leading, spacing: 18) {
        Text(preview.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let bytes = preview.selectedBytes {
          previewMetric(
            title: L10n.text("preview.selected-space"),
            value: ValueFormatter.bytes(bytes),
            symbol: "internaldrive"
          )
        }

        previewWarnings

        if !preview.serviceChanges.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            InstrumentSectionLabel(
              title: "preview.service-changes",
              detail: L10n.formatted("format.changes", preview.serviceChanges.count)
            )
            PreviewChangeGroupList(
              changes: preview.serviceChanges,
              categories: presentation.categories
            )
          }
        }
      }
    }
  }

  private var impactCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text("preview.impact.title")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)

        Text(preview.summary)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(14)

      if !impactItems.isEmpty {
        Divider()
          .padding(.horizontal, 14)

        ForEach(impactItems) { item in
          impactRow(item)
          if item.id != impactItems.last?.id {
            Divider()
              .padding(.leading, 52)
          }
        }
      }
    }
    .background(
      Color.instrumentRaised.opacity(0.72),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }

  private func impactRow(_ item: PreviewImpactItem) -> some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(item.tint.opacity(0.1))
        Image(systemName: item.symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(item.tint)
      }
      .frame(width: 28, height: 28)
      .accessibilityHidden(true)

      Text(item.title)
        .font(.callout)
        .foregroundStyle(.secondary)

      Spacer(minLength: 16)

      Text(item.value)
        .font(.callout.weight(.semibold))
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 46)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var previewWarnings: some View {
    if !preview.warnings.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(preview.warnings, id: \.self) { warning in
          NoticeStrip(tone: warningTone, title: warning)
        }
      }
    }
  }

  private var impactItems: [PreviewImpactItem] {
    switch preview.operation.kind {
    case .delete:
      [
        PreviewImpactItem(
          title: L10n.text("preview.impact.device"),
          value: L10n.text("preview.impact.device-delete"),
          symbol: "iphone.slash",
          tint: .red
        ),
        PreviewImpactItem(
          title: L10n.text("preview.impact.local-data"),
          value: L10n.text("preview.impact.data-delete"),
          symbol: "internaldrive",
          tint: .red
        ),
      ]
    case .erase:
      [
        PreviewImpactItem(
          title: L10n.text("preview.impact.device"),
          value: L10n.text("preview.impact.device-keep"),
          symbol: "iphone",
          tint: .mint
        ),
        PreviewImpactItem(
          title: L10n.text("preview.impact.local-data"),
          value: L10n.text("preview.impact.data-delete"),
          symbol: "internaldrive",
          tint: .red
        ),
      ]
    case .clone:
      [
        PreviewImpactItem(
          title: L10n.text("preview.impact.source-device"),
          value: L10n.text("preview.impact.device-keep"),
          symbol: "iphone",
          tint: .mint
        ),
        PreviewImpactItem(
          title: L10n.text("preview.impact.device-copy"),
          value: L10n.text("preview.impact.copy-create"),
          symbol: "plus.square.on.square",
          tint: .orange
        ),
      ]
    default:
      []
    }
  }

  private var isSparsePreview: Bool {
    preview.selectedBytes == nil && preview.serviceChanges.isEmpty
  }

  private var usesImpactLayout: Bool {
    switch preview.operation.kind {
    case .erase, .delete, .clone:
      true
    default:
      false
    }
  }

  private var minimumSheetHeight: CGFloat {
    guard isSparsePreview else { return 420 }
    return usesImpactLayout ? 360 : 260
  }

  private var idealSheetHeight: CGFloat {
    guard isSparsePreview else { return 560 }
    return usesImpactLayout ? 410 : 300
  }

  private var safetyNote: String {
    switch preview.operation.kind {
    case .erase, .delete, .clone:
      L10n.text("preview.safety-note.device-operation")
    default:
      L10n.text("preview.safety-note")
    }
  }

  private var executeButton: some View {
    Button(role: actionRole) {
      confirm()
    } label: {
      Label(executeTitle, systemImage: preview.operation.kind.symbolName)
    }
    .buttonStyle(
      PressablePrimaryButtonStyle(
        tint: actionTint,
        foreground: .white
      )
    )
  }

  private var allowsDefaultAction: Bool {
    switch preview.operation.kind {
    case .cleanStorage, .erase, .delete:
      false
    default:
      true
    }
  }

  private var sheetHeader: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(actionTint.opacity(0.11))
        Image(systemName: preview.operation.kind.symbolName)
          .foregroundStyle(actionTint)
          .font(.system(size: 18, weight: .semibold))
      }
      .frame(width: 40, height: 40)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(preview.title)
          .font(.title3.weight(.semibold))
        Text("preview.subtitle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
    .background(.bar)
  }

  private var actionTint: Color {
    switch preview.operation.kind {
    case .erase, .delete: .red
    case .clone: .orange
    default: .mint
    }
  }

  private var actionRole: ButtonRole? {
    switch preview.operation.kind {
    case .erase, .delete: .destructive
    default: nil
    }
  }

  private var warningTone: NoticeStrip.Tone {
    switch preview.operation.kind {
    case .erase, .delete: .error
    default: .warning
    }
  }

  private var executeTitle: String {
    switch preview.operation.kind {
    case .optimize: L10n.text("action.optimize-device")
    case .verify: L10n.text("action.continue-verification")
    case .restore: L10n.text("action.restore")
    case .cleanStorage: L10n.text("action.clean")
    case .erase: L10n.text("action.erase")
    case .delete: L10n.text("action.delete")
    case .clone: L10n.text("action.clone")
    default: L10n.text("action.continue")
    }
  }

  private func previewMetric(title: String, value: String, symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(.mint)
        .frame(width: 24)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.headline.monospacedDigit())
    }
    .padding(14)
    .background(Color.instrumentRaised, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }
}

private struct PreviewImpactItem: Identifiable {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  var id: String { title }
}

struct BatchPreviewSheet: View {
  let presentation: BatchPreviewPresentation
  let cancel: () -> Void
  let confirm: () -> Void

  @State private var expandedDeviceIDs: Set<SimulatorID> = []

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summary

          if presentation.failedCount > 0 {
            NoticeStrip(
              tone: .warning,
              title: L10n.formatted(
                "batch.preview.failures.title",
                presentation.failedCount
              ),
              message: L10n.text("batch.preview.failures.message")
            )
          }

          VStack(alignment: .leading, spacing: 10) {
            InstrumentSectionLabel(
              title: "batch.preview.devices.title",
              detail: L10n.formatted("format.items", presentation.items.count)
            )
            ForEach(presentation.items) { item in
              devicePreview(item)
            }
          }
        }
        .padding(20)
      }

      Divider()
      HStack(spacing: 12) {
        Label("batch.preview.signature-note", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("action.cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
          .minimumHitArea()
        Button {
          confirm()
        } label: {
          Label("batch.preview.confirm", systemImage: "play.fill")
        }
        .buttonStyle(PressablePrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(presentation.executableCount == 0)
        .accessibilityHint("batch.preview.confirm.hint")
      }
      .padding(16)
    }
    .frame(minWidth: 700, idealWidth: 760, minHeight: 540, idealHeight: 680)
    .background(Color.instrumentBackground)
    .suppressInitialFocus()
    .interactiveDismissDisabled()
    .accessibilityIdentifier("batch-preview.sheet")
  }

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.mint.opacity(0.11))
        Image(systemName: "rectangle.stack.badge.checkmark")
          .foregroundStyle(.mint)
          .font(.system(size: 18, weight: .semibold))
      }
      .frame(width: 40, height: 40)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("batch.preview.title")
          .font(.title3.weight(.semibold))
        Text(
          L10n.formatted(
            "batch.preview.subtitle",
            presentation.profile.localizedTitle
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
    .background(.bar)
  }

  private var summary: some View {
    InstrumentCard {
      HStack(spacing: 0) {
        summaryMetric(
          title: L10n.text("batch.preview.metric.selected"),
          value: presentation.items.count,
          tint: .primary
        )
        Divider().frame(height: 38)
        summaryMetric(
          title: L10n.text("batch.preview.metric.executable"),
          value: presentation.executableCount,
          tint: .mint
        )
        Divider().frame(height: 38)
        summaryMetric(
          title: L10n.text("batch.preview.metric.changes"),
          value: presentation.totalChangeCount,
          tint: .orange
        )
        Divider().frame(height: 38)
        summaryMetric(
          title: L10n.text("batch.preview.metric.failed"),
          value: presentation.failedCount,
          tint: presentation.failedCount == 0 ? .secondary : .red
        )
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func summaryMetric(title: String, value: Int, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value.formatted())
        .font(.title3.weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func devicePreview(_ item: BatchPreviewItem) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(
          systemName: item.device.deviceTypeIdentifier.localizedCaseInsensitiveContains("ipad")
            ? "ipad" : "iphone"
        )
        .foregroundStyle(item.canExecute ? .mint : .red)
        .frame(width: 24)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.device.name)
            .font(.headline)
          Text(item.device.runtimeName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let preview = item.preview {
          Text(L10n.formatted("format.changes", preview.serviceChanges.count))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
          if let highestRisk = preview.serviceChanges.map(\.risk).max() {
            RiskBadge(risk: highestRisk)
          }
        } else {
          Label("batch.preview.failed", systemImage: "xmark.octagon.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        }
      }

      if let failureMessage = item.failureMessage {
        NoticeStrip(
          tone: .error,
          title: L10n.text("batch.preview.failed"),
          message: failureMessage
        )
      } else if let preview = item.preview {
        ForEach(preview.warnings, id: \.self) { warning in
          NoticeStrip(tone: .warning, title: warning)
        }

        if preview.serviceChanges.isEmpty {
          Label("batch.preview.no-changes", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.mint)
        } else {
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedDeviceIDs.contains(item.id) },
              set: { expanded in
                if expanded {
                  expandedDeviceIDs.insert(item.id)
                } else {
                  expandedDeviceIDs.remove(item.id)
                }
              }
            )
          ) {
            VStack(spacing: 0) {
              ForEach(preview.serviceChanges) { change in
                PreviewChangeRow(change: change)
                if change.id != preview.serviceChanges.last?.id { Divider() }
              }
            }
            .padding(.horizontal, 12)
            .background(
              Color.instrumentBackground,
              in: RoundedRectangle(
                cornerRadius: InstrumentTheme.innerRadius,
                style: .continuous
              )
            )
            .padding(.top, 8)
          } label: {
            Text(
              L10n.formatted(
                "batch.preview.show-changes",
                preview.serviceChanges.count
              )
            )
            .font(.subheadline.weight(.medium))
            .frame(minHeight: InstrumentTheme.minimumHitSize)
          }
          .disclosureGroupStyle(InstrumentDisclosureGroupStyle())
        }
      }
    }
    .padding(14)
    .background(
      Color.instrumentRaised,
      in: RoundedRectangle(cornerRadius: InstrumentTheme.cardRadius, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("batch-preview.device.\(item.id.rawValue)")
  }
}

private struct PreviewChangeGroupList: View {
  private struct Group: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let changes: [ServiceChange]
  }

  let changes: [ServiceChange]
  let categories: [ServiceCategory]
  @State private var expandedCategoryIDs: Set<String>

  init(changes: [ServiceChange], categories: [ServiceCategory]) {
    self.changes = changes
    self.categories = categories
    _expandedCategoryIDs = State(initialValue: Set(changes.map(\.categoryID)))
  }

  private var groups: [Group] {
    let groupedChanges = Dictionary(grouping: changes, by: \.categoryID)
    let knownGroups = categories.compactMap { category -> Group? in
      guard let changes = groupedChanges[category.id] else { return nil }
      return Group(
        id: category.id,
        name: category.name,
        symbol: category.symbol,
        changes: changes.sorted(by: serviceNameAscending)
      )
    }
    let knownCategoryIDs = Set(categories.map(\.id))
    let unknownGroups = groupedChanges.compactMap { categoryID, changes -> Group? in
      guard !knownCategoryIDs.contains(categoryID) else { return nil }
      return Group(
        id: categoryID,
        name: categoryID,
        symbol: "square.grid.2x2",
        changes: changes.sorted(by: serviceNameAscending)
      )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return knownGroups + unknownGroups
  }

  var body: some View {
    VStack(spacing: 8) {
      ForEach(groups) { group in
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedCategoryIDs.contains(group.id) },
            set: { isExpanded in
              if isExpanded {
                expandedCategoryIDs.insert(group.id)
              } else {
                expandedCategoryIDs.remove(group.id)
              }
            }
          )
        ) {
          VStack(spacing: 0) {
            ForEach(group.changes) { change in
              PreviewChangeRow(change: change)
              if change.id != group.changes.last?.id { Divider() }
            }
          }
          .padding(.leading, 26)
          .padding(.top, 6)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: group.symbol)
              .foregroundStyle(.mint)
              .frame(width: 20)
            Text(group.name)
              .font(.subheadline.weight(.medium))
            Spacer()
            Text(L10n.formatted("format.items", group.changes.count))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .frame(minHeight: 40)
          .accessibilityIdentifier("preview-change-group.\(group.id)")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .background(
          Color.instrumentRaised,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .disclosureGroupStyle(InstrumentDisclosureGroupStyle())
      }
    }
  }

  private func serviceNameAscending(_ lhs: ServiceChange, _ rhs: ServiceChange) -> Bool {
    lhs.serviceName.localizedStandardCompare(rhs.serviceName) == .orderedAscending
  }
}

private struct PreviewChangeRow: View {
  let change: ServiceChange

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: change.transition == .disable
          ? "pause.circle.fill"
          : "play.circle.fill"
      )
      .foregroundStyle(change.transition == .disable ? .orange : .mint)
      .padding(.top, 2)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(change.serviceName)
            .font(.subheadline.weight(.medium))
          RiskBadge(risk: change.risk)
        }
        Text(change.label)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if let impact = change.impact, !impact.isEmpty {
          Text(impact)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(change.localizedStateTransition)
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(change.transition == .disable ? .orange : .mint)
        .frame(width: 104, alignment: .trailing)
        .padding(.top, 2)
    }
    .padding(.vertical, 10)
    .frame(minHeight: 52)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(change.localizedStateTransition)
    .accessibilityIdentifier("service-change.\(change.label)")
  }

  private var accessibilityLabel: String {
    [
      change.serviceName,
      L10n.formatted("accessibility.risk", change.risk.localizedTitle),
      change.impact,
      change.label,
    ]
    .compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    .joined(separator: "，")
  }
}

struct DangerConfirmationSheet: View {
  let presentation: DangerPresentation
  let cancel: () -> Void
  let confirm: (String?) -> Void

  @State private var cloneName = ""
  @FocusState private var focusedField: Field?

  private enum Field {
    case cloneName
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(tint.opacity(0.12))
          Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.title3.weight(.semibold))
          Text(presentation.device.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
        Spacer()
      }
      .padding(18)
      .background(.bar)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          NoticeStrip(tone: tone, title: warningTitle, message: warningMessage)

          if presentation.kind == .clone {
            VStack(alignment: .leading, spacing: 7) {
              Text("confirmation.clone-name")
                .font(.subheadline.weight(.medium))
              TextField("confirmation.clone-name.placeholder", text: $cloneName)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: InstrumentTheme.minimumHitSize)
                .focused($focusedField, equals: .cloneName)
                .accessibilityHint("confirmation.clone-name.hint")
            }
          }
        }
        .padding(20)
      }

      Divider()

      HStack {
        Spacer()
        Button("action.cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
          .minimumHitArea()
        if presentation.kind == .clone {
          confirmationButton
            .keyboardShortcut(.defaultAction)
        } else {
          confirmationButton
        }
      }
      .padding(16)
    }
    .frame(
      minWidth: 480,
      idealWidth: 520,
      minHeight: presentation.kind == .clone ? 360 : 280,
      idealHeight: presentation.kind == .clone ? 420 : 320
    )
    .background(Color.instrumentBackground)
    .onAppear {
      if presentation.kind == .clone {
        focusedField = .cloneName
      }
    }
    .interactiveDismissDisabled()
    .accessibilityIdentifier("danger-confirmation.sheet")
  }

  private var canConfirm: Bool {
    if presentation.kind == .clone {
      return !cloneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return true
  }

  private var tint: Color { presentation.kind == .clone ? .orange : .red }
  private var tone: NoticeStrip.Tone { presentation.kind == .clone ? .warning : .error }

  private var confirmationButton: some View {
    Button(role: presentation.kind == .clone ? nil : .destructive) {
      confirm(presentation.kind == .clone ? cloneName : nil)
    } label: {
      Text(actionTitle)
    }
    .buttonStyle(
      PressablePrimaryButtonStyle(
        tint: tint,
        foreground: .white
      )
    )
    .disabled(!canConfirm)
    .minimumHitArea()
  }

  private var title: String {
    switch presentation.kind {
    case .erase: L10n.text("confirmation.erase.title")
    case .delete: L10n.text("confirmation.delete.title")
    case .clone: L10n.text("confirmation.clone.title")
    }
  }

  private var warningTitle: String {
    switch presentation.kind {
    case .erase: L10n.text("confirmation.erase.warning")
    case .delete: L10n.text("confirmation.delete.warning")
    case .clone: L10n.text("confirmation.clone.warning")
    }
  }

  private var warningMessage: String {
    switch presentation.kind {
    case .erase: L10n.text("confirmation.erase.message")
    case .delete: L10n.text("confirmation.delete.message")
    case .clone: L10n.text("confirmation.clone.message")
    }
  }

  private var symbol: String {
    switch presentation.kind {
    case .erase: "eraser.fill"
    case .delete: "trash.fill"
    case .clone: "plus.square.on.square"
    }
  }

  private var actionTitle: String {
    switch presentation.kind {
    case .erase:
      L10n.text("confirmation.erase.action")
    case .delete:
      L10n.text("confirmation.delete.action")
    case .clone: L10n.text("action.clone")
    }
  }
}
