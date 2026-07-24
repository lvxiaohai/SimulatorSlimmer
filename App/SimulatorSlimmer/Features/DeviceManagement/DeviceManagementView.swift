import SimulatorSlimmerCore
import SwiftUI

struct DeviceManagementView: View {
  let snapshot: DeviceSnapshot
  @Bindable var model: AppModel

  private var isBusy: Bool {
    model.isDeviceBusy(snapshot.device.id)
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        operationState
        informationPanel
        if snapshot.optimizationSupport == .supported {
          dangerPanel
        }
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.bottom, InstrumentTheme.pagePadding)
    }
    .accessibilityIdentifier("device-management.page")
  }

  @ViewBuilder
  private var operationState: some View {
    if let operation = model.operations[snapshot.device.id],
      isDeviceManagementOperation(operation.operation.kind)
    {
      if operation.isRunning {
        OperationProgressPanel(
          presentation: operation,
          stop: model.requestStop
        )
      } else if let receipt = operation.receipt, shouldShowResult(receipt) {
        OperationResultBanner(receipt: receipt)
      } else if let failure = operation.failureMessage {
        NoticeStrip(
          tone: .error,
          title: L10n.text("device.action-failed.title"),
          message: failure
        )
      }
    }
  }

  private func isDeviceManagementOperation(_ kind: OperationKind) -> Bool {
    switch kind {
    case .clone, .erase, .delete:
      true
    case .preflight, .optimize, .verify, .restore, .scanStorage, .cleanStorage, .boot,
      .shutdown, .openSimulator:
      false
    }
  }

  private func shouldShowResult(_ receipt: OperationReceipt) -> Bool {
    guard receipt.status == .succeeded else { return true }
    return receipt.kind == .clone || receipt.kind == .erase
  }

  private var informationPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        InstrumentSectionLabel(title: "device.information.title")

        informationRow(
          title: L10n.text("device.information.runtime"),
          value: snapshot.device.runtimeName
        )
        Divider()
        informationRow(
          title: L10n.text("device.information.state"),
          value: snapshot.device.state.localizedTitle
        )
        Divider()
        informationRow(
          title: L10n.text("device.information.udid"),
          value: snapshot.device.id.rawValue,
          monospaced: true
        )
        if let lastBootedAt = snapshot.device.lastBootedAt {
          Divider()
          informationRow(
            title: L10n.text("device.information.last-booted"),
            value: lastBootedAt.formatted(date: .abbreviated, time: .shortened)
          )
        }
        if let dataSize = snapshot.device.dataSize {
          Divider()
          informationRow(
            title: L10n.text("device.information.data-size"),
            value: ValueFormatter.bytes(dataSize),
            monospaced: true
          )
        }
      }
    }
  }

  private func informationRow(
    title: String,
    value: String,
    monospaced: Bool = false
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(monospaced ? .callout.monospaced() : .callout)
        .monospacedDigit()
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(monospaced ? .middle : .tail)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(minHeight: 28)
    .accessibilityElement(children: .combine)
  }

  private var dangerPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Text("device.danger.title")
            .font(.headline)
          Text("device.danger.message")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        dangerRow(
          title: L10n.text("action.clone"),
          summary: L10n.text("action.clone.summary"),
          symbol: "plus.square.on.square",
          tint: .orange,
          role: nil,
          action: { model.requestDanger(.clone) }
        )
        Divider()
        dangerRow(
          title: L10n.text("action.erase"),
          summary: L10n.text("action.erase.summary"),
          symbol: "eraser.fill",
          tint: .red,
          role: .destructive,
          action: { model.requestDanger(.erase) }
        )
        Divider()
        dangerRow(
          title: L10n.text("action.delete"),
          summary: L10n.text("action.delete.summary"),
          symbol: "trash.fill",
          tint: .red,
          role: .destructive,
          action: { model.requestDanger(.delete) }
        )
      }
    }
  }

  private func dangerRow(
    title: String,
    summary: String,
    symbol: String,
    tint: Color,
    role: ButtonRole?,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(title, role: role, action: action)
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(isBusy || !snapshot.device.isAvailable)
        .minimumHitArea()
    }
    .frame(minHeight: 48)
    .accessibilityElement(children: .contain)
  }
}
