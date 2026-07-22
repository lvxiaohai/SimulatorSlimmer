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
      LazyVStack(alignment: .leading, spacing: 20) {
        operationState
        statePanel
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
      operation.operation.kind != .optimize,
      operation.operation.kind != .restore,
      operation.operation.kind != .scanStorage,
      operation.operation.kind != .cleanStorage
    {
      if operation.isRunning {
        OperationProgressPanel(
          presentation: operation,
          stop: model.requestStop
        )
      } else if let receipt = operation.receipt {
        ReceiptResultBanner(
          receipt: receipt,
          showReceipt: { model.showReceipt(receipt) }
        )
      } else if let failure = operation.failureMessage {
        NoticeStrip(
          tone: .error,
          title: L10n.text("device.action-failed.title"),
          message: failure
        )
      }
    }
  }

  private var statePanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(title: "device.control.title")

        HStack(spacing: 14) {
          deviceAction(
            title: L10n.text("action.boot"),
            summary: L10n.text("action.boot.summary"),
            symbol: "power",
            tint: .mint,
            disabled: snapshot.device.state == .booted,
            action: { model.runDeviceOperation(.boot) }
          )

          deviceAction(
            title: L10n.text("action.shutdown"),
            summary: L10n.text("action.shutdown.summary"),
            symbol: "power.circle",
            tint: .orange,
            disabled: snapshot.device.state == .shutdown,
            action: { model.runDeviceOperation(.shutdown) }
          )

          deviceAction(
            title: L10n.text("action.open-simulator"),
            summary: L10n.text("action.open-simulator.summary"),
            symbol: "rectangle.on.rectangle",
            tint: .blue,
            disabled: false,
            action: { model.runDeviceOperation(.openSimulator) }
          )
        }
      }
    }
  }

  private func deviceAction(
    title: String,
    summary: String,
    symbol: String,
    tint: Color,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 36, height: 36)
          .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
      .padding(14)
      .background(
        Color.instrumentRaised,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(disabled || isBusy || !snapshot.device.isAvailable)
    .accessibilityHint(summary)
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
        .multilineTextAlignment(.trailing)
    }
    .frame(minHeight: 28)
    .accessibilityElement(children: .combine)
  }

  private var dangerPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 9) {
          Image(systemName: "exclamationmark.shield.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("device.danger.title")
              .font(.headline)
            Text("device.danger.message")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        dangerRow(
          title: L10n.text("action.clone"),
          summary: L10n.text("action.clone.summary"),
          symbol: "plus.square.on.square",
          role: nil,
          action: { model.requestDanger(.clone) }
        )
        Divider()
        dangerRow(
          title: L10n.text("action.erase"),
          summary: L10n.text("action.erase.summary"),
          symbol: "eraser.fill",
          role: .destructive,
          action: { model.requestDanger(.erase) }
        )
        Divider()
        dangerRow(
          title: L10n.text("action.delete"),
          summary: L10n.text("action.delete.summary"),
          symbol: "trash.fill",
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
    role: ButtonRole?,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(role == .destructive ? .red : .blue)
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
        .disabled(isBusy || !snapshot.device.isAvailable)
        .minimumHitArea()
    }
    .frame(minHeight: 48)
    .accessibilityElement(children: .contain)
  }
}
