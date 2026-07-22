import AppKit
import SimulatorSlimmerCore
import SwiftUI

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

          if !preview.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(preview.warnings, id: \.self) { warning in
                NoticeStrip(tone: .warning, title: warning)
              }
            }
          }

          if !preview.serviceChanges.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              InstrumentSectionLabel(
                title: "preview.service-changes",
                detail: L10n.formatted("format.changes", preview.serviceChanges.count)
              )
              VStack(spacing: 0) {
                ForEach(preview.serviceChanges) { change in
                  PreviewChangeRow(change: change)
                  if change.id != preview.serviceChanges.last?.id { Divider() }
                }
              }
              .padding(.horizontal, 12)
              .background(
                Color.instrumentRaised,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
              )
            }
          }
        }
        .padding(20)
      }

      Divider()
      HStack {
        Text("preview.safety-note")
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
          Button {
            confirm()
          } label: {
            Label(executeTitle, systemImage: preview.operation.kind.symbolName)
          }
          .buttonStyle(PressablePrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(16)
    }
    .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 560)
    .background(Color.instrumentBackground)
    .accessibilityIdentifier("operation-preview.sheet")
  }

  private var sheetHeader: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.mint.opacity(0.11))
        Image(systemName: preview.operation.kind.symbolName)
          .foregroundStyle(.mint)
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
        Text(change.localizedStateTransition)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(change.transition == .disable ? .orange : .mint)
        if let impact = change.impact, !impact.isEmpty {
          Text(impact)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
    }
    .padding(.vertical, 10)
    .frame(minHeight: 52)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(change.localizedStateTransition)
    .accessibilityIdentifier("service-change.\(change.label)")
  }

  private var accessibilityLabel: String {
    [change.serviceName, change.impact, change.label]
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

  @State private var confirmationText = ""
  @State private var cloneName = ""
  @FocusState private var focusedField: Field?

  private enum Field {
    case confirmation
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
        }
        Spacer()
      }
      .padding(18)
      .background(.bar)

      Divider()

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
        } else {
          VStack(alignment: .leading, spacing: 7) {
            Text(
              L10n.formatted(
                "confirmation.type-device-name",
                presentation.device.name
              )
            )
            .font(.subheadline.weight(.medium))
            TextField(presentation.device.name, text: $confirmationText)
              .textFieldStyle(.roundedBorder)
              .frame(minHeight: InstrumentTheme.minimumHitSize)
              .focused($focusedField, equals: .confirmation)
              .accessibilityLabel("confirmation.input")
          }
        }
      }
      .padding(20)

      Spacer(minLength: 0)
      Divider()

      HStack {
        Spacer()
        Button("action.cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
          .minimumHitArea()
        Button(role: presentation.kind == .clone ? nil : .destructive) {
          confirm(presentation.kind == .clone ? cloneName : nil)
        } label: {
          Text(actionTitle)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canConfirm)
        .minimumHitArea()
      }
      .padding(16)
    }
    .frame(width: 520, height: 390)
    .background(Color.instrumentBackground)
    .onAppear {
      focusedField = presentation.kind == .clone ? .cloneName : .confirmation
    }
    .interactiveDismissDisabled()
    .accessibilityIdentifier("danger-confirmation.sheet")
  }

  private var canConfirm: Bool {
    if presentation.kind == .clone {
      return !cloneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return confirmationText == presentation.device.name
  }

  private var tint: Color { presentation.kind == .clone ? .blue : .red }
  private var tone: NoticeStrip.Tone { presentation.kind == .clone ? .info : .error }

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
    case .erase: L10n.text("action.erase")
    case .delete: L10n.text("action.delete")
    case .clone: L10n.text("action.clone")
    }
  }
}

struct ReceiptDetailSheet: View {
  let receipt: OperationReceipt
  let canContinueVerification: Bool
  let canRestore: Bool
  let dismiss: () -> Void
  let continueVerification: () -> Void
  let restore: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: receipt.status.symbolName)
          .font(.system(size: 25))
          .foregroundStyle(receipt.status.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(receipt.kind.localizedTitle)
            .font(.title3.weight(.semibold))
          Text(receipt.deviceName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let opaquePayload = receipt.opaquePayload {
          Text(
            opaquePayload.reason == .corrupted
              ? L10n.text("receipt.corrupted.badge")
              : L10n.text("receipt.read-only.badge")
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(opaquePayload.reason == .corrupted ? .red : .orange)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(
            (opaquePayload.reason == .corrupted ? Color.red : Color.orange).opacity(0.1),
            in: Capsule()
          )
        }
        Text(receipt.status.localizedTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(receipt.status.tint)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(receipt.status.tint.opacity(0.1), in: Capsule())
      }
      .padding(16)
      .background(.bar)

      Divider()

      ScrollView {
        ReceiptInspectorContent(receipt: receipt)
          .padding(20)
      }

      Divider()
      HStack {
        Button("receipt.copy-json") { copyReceipt() }
          .minimumHitArea()
        Spacer()
        if canRestore {
          Button {
            restore()
          } label: {
            Label("receipt.action.restore-baseline", systemImage: "arrow.uturn.backward")
          }
          .minimumHitArea()
          .accessibilityHint("receipt.action.restore-baseline.hint")
        }
        if canContinueVerification {
          Button {
            continueVerification()
          } label: {
            Label("action.continue-verification", systemImage: "checkmark.magnifyingglass")
          }
          .buttonStyle(PressablePrimaryButtonStyle())
          .minimumHitArea()
          .accessibilityHint("receipt.action.continue-verification.hint")
        }
        Button("action.close", action: dismiss)
          .keyboardShortcut(.defaultAction)
          .minimumHitArea()
      }
      .padding(16)
    }
    .frame(minWidth: 600, idealWidth: 680, minHeight: 500, idealHeight: 620)
    .background(Color.instrumentBackground)
    .accessibilityIdentifier("receipt-detail.sheet")
  }

  private func copyReceipt() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(receipt), let json = String(data: data, encoding: .utf8)
    else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(json, forType: .string)
  }
}

struct ReceiptInspectorContent: View {
  let receipt: OperationReceipt

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let opaquePayload = receipt.opaquePayload {
        NoticeStrip(
          tone: opaquePayload.reason == .corrupted ? .error : .warning,
          title: opaquePayload.reason == .corrupted
            ? L10n.text("receipt.corrupted.title")
            : L10n.text("receipt.read-only.title"),
          message: L10n.formatted(
            "receipt.opaque.message",
            opaquePayload.sourceFileName,
            opaquePayload.errorMessage
          )
        )
        .accessibilityIdentifier("receipt.opaque.\(opaquePayload.reason.rawValue)")
      } else if receipt.schemaVersion != 1 {
        NoticeStrip(
          tone: .warning,
          title: L10n.text("receipt.unsupported-schema.title"),
          message: L10n.formatted(
            "receipt.unsupported-schema.message",
            receipt.schemaVersion
          )
        )
      }

      if let pendingChange = receipt.pendingChange {
        InstrumentCard {
          VStack(alignment: .leading, spacing: 12) {
            InstrumentSectionLabel(title: "receipt.pending-change")
            NoticeStrip(
              tone: .warning,
              title: L10n.text("receipt.pending-change.warning"),
              message: L10n.text("receipt.pending-change.message")
            )
            PreviewChangeRow(change: pendingChange)
          }
        }
        .accessibilityIdentifier("receipt.pending-change")
      }

      InstrumentCard {
        VStack(spacing: 12) {
          detailRow(L10n.text("receipt.id"), receipt.id.rawValue.uuidString, monospaced: true)
          Divider()
          detailRow(
            L10n.text("receipt.schema-version"),
            String(receipt.schemaVersion),
            monospaced: true
          )
          Divider()
          detailRow(
            L10n.text("receipt.started-at"),
            receipt.startedAt.formatted(date: .abbreviated, time: .standard)
          )
          if let finishedAt = receipt.finishedAt {
            Divider()
            detailRow(
              L10n.text("receipt.finished-at"),
              finishedAt.formatted(date: .abbreviated, time: .standard)
            )
          }
          Divider()
          detailRow(
            L10n.text("receipt.device-state"),
            "\(receipt.originalDeviceState.localizedTitle) → \(receipt.finalDeviceState?.localizedTitle ?? "—")"
          )
        }
      }

      if let before = receipt.memoryBefore, let after = receipt.memoryAfter {
        InstrumentCard {
          VStack(alignment: .leading, spacing: 12) {
            InstrumentSectionLabel(title: "receipt.memory")
            HStack(spacing: 0) {
              resultMetric(
                L10n.text("result.before"),
                ValueFormatter.bytes(before.bytes)
              )
              Divider().frame(height: 34)
              resultMetric(
                L10n.text("result.after"),
                ValueFormatter.bytes(after.bytes)
              )
              if let delta = receipt.reclaimedBytes {
                Divider().frame(height: 34)
                resultMetric(
                  MemoryDeltaPresentation.title(for: delta),
                  MemoryDeltaPresentation.value(for: delta, before: before.bytes),
                  tint: MemoryDeltaPresentation.tint(for: delta)
                )
              }
            }
          }
        }
      }

      if !receipt.appliedChanges.isEmpty {
        InstrumentCard {
          VStack(alignment: .leading, spacing: 10) {
            InstrumentSectionLabel(
              title: "receipt.applied-changes",
              detail: L10n.formatted("format.items", receipt.appliedChanges.count)
            )
            ForEach(receipt.appliedChanges) { applied in
              HStack(alignment: .top, spacing: 10) {
                Image(
                  systemName: applied.succeeded
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
                )
                .foregroundStyle(applied.succeeded ? .mint : .red)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                  Text(applied.change.serviceName)
                    .font(.subheadline.weight(.medium))
                  Text(applied.change.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                  Text(applied.change.localizedStateTransition)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(
                      applied.change.transition == .disable ? .orange : .mint
                    )
                  if let impact = applied.change.impact, !impact.isEmpty {
                    Text(impact)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  if let errorMessage = applied.errorMessage {
                    Text(errorMessage)
                      .font(.caption)
                      .foregroundStyle(.red)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
                Spacer()
              }
              .padding(.vertical, 5)
              .accessibilityElement(children: .combine)
            }
          }
        }
      }

      if !receipt.messages.isEmpty {
        InstrumentCard {
          VStack(alignment: .leading, spacing: 10) {
            InstrumentSectionLabel(title: "receipt.messages")
            ForEach(Array(receipt.messages.enumerated()), id: \.offset) { index, message in
              HStack(alignment: .top, spacing: 9) {
                Text("\(index + 1)")
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.secondary)
                  .frame(width: 22, alignment: .trailing)
                Text(message)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  private func detailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(monospaced ? .caption.monospaced() : .callout)
        .monospacedDigit()
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private func resultMetric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline.monospacedDigit())
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
