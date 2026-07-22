import SimulatorSlimmerCore
import SwiftUI

struct HistoryView: View {
  @Bindable var model: AppModel
  @State private var selectedReceiptID: ReceiptID?
  @State private var query = ""

  private var filteredReceipts: [OperationReceipt] {
    guard !query.isEmpty else { return model.recentReceipts }
    return model.recentReceipts.filter {
      $0.deviceName.localizedCaseInsensitiveContains(query)
        || $0.kind.localizedTitle.localizedCaseInsensitiveContains(query)
        || $0.status.localizedTitle.localizedCaseInsensitiveContains(query)
    }
  }

  private var selectedReceipt: OperationReceipt? {
    let id = selectedReceiptID ?? filteredReceipts.first?.id
    return filteredReceipts.first { $0.id == id }
  }

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider()

      if filteredReceipts.isEmpty {
        ContentUnavailableView {
          Label("history.empty.title", systemImage: "clock.badge.questionmark")
        } description: {
          Text(
            query.isEmpty
              ? L10n.text("history.empty.message")
              : L10n.text("history.search-empty.message")
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          List(selection: $selectedReceiptID) {
            if !model.overviewPendingReceipts.isEmpty {
              Section("history.pending") {
                ForEach(model.overviewPendingReceipts) { receipt in
                  ReceiptHistoryRow(receipt: receipt)
                    .tag(receipt.id)
                }
              }
            }

            Section("history.recent") {
              ForEach(filteredReceipts) { receipt in
                ReceiptHistoryRow(receipt: receipt)
                  .tag(receipt.id)
              }
            }
          }
          .listStyle(.inset)
          .frame(minWidth: 280, idealWidth: 320, maxWidth: 390)

          ScrollView {
            if let selectedReceipt {
              VStack(alignment: .leading, spacing: 16) {
                ReceiptInspectorContent(receipt: selectedReceipt)
                if model.canContinueVerification(from: selectedReceipt)
                  || model.canRestore(from: selectedReceipt)
                {
                  recoveryActions(for: selectedReceipt)
                }
              }
              .padding(InstrumentTheme.pagePadding)
            }
          }
          .frame(minWidth: 430)
          .background(Color.instrumentBackground)
        }
      }
    }
    .background(Color.instrumentBackground)
    .navigationTitle("sidebar.history")
    .onAppear {
      selectedReceiptID = selectedReceiptID ?? filteredReceipts.first?.id
    }
    .onChange(of: filteredReceipts.count) { _, _ in
      if let selectedReceiptID,
        !filteredReceipts.contains(where: { $0.id == selectedReceiptID })
      {
        self.selectedReceiptID = filteredReceipts.first?.id
      }
    }
    .accessibilityIdentifier("history.page")
  }

  private var pageHeader: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text("history.title")
          .font(.title2.weight(.semibold))
        Text("history.subtitle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      TextField("history.search.prompt", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 240)
        .minimumHitArea()
        .accessibilityLabel("history.search.prompt")
    }
    .padding(.horizontal, InstrumentTheme.pagePadding)
    .padding(.vertical, 16)
    .background(.bar)
  }

  private func recoveryActions(for receipt: OperationReceipt) -> some View {
    InstrumentCard {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("receipt.recovery-actions.title")
            .font(.subheadline.weight(.semibold))
          Text("receipt.recovery-actions.message")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.canRestore(from: receipt) {
          Button {
            model.restore(from: receipt)
          } label: {
            Label("receipt.action.restore-baseline", systemImage: "arrow.uturn.backward")
          }
          .minimumHitArea()
        }
        if model.canContinueVerification(from: receipt) {
          Button {
            model.continueVerification(from: receipt)
          } label: {
            Label("action.continue-verification", systemImage: "checkmark.magnifyingglass")
          }
          .buttonStyle(PressablePrimaryButtonStyle())
          .minimumHitArea()
        }
      }
    }
  }
}

private struct ReceiptHistoryRow: View {
  let receipt: OperationReceipt

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: receipt.status.symbolName)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(receipt.status.tint)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(receipt.kind.localizedTitle)
            .font(.subheadline.weight(.medium))
          if let opaquePayload = receipt.opaquePayload {
            Text(
              opaquePayload.reason == .corrupted
                ? L10n.text("receipt.corrupted.badge")
                : L10n.text("receipt.read-only.badge")
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(opaquePayload.reason == .corrupted ? .red : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (opaquePayload.reason == .corrupted ? Color.red : Color.orange).opacity(0.1),
              in: Capsule()
            )
          }
          Spacer()
          Text(receipt.startedAt, style: .time)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        HStack {
          Text(receipt.deviceName)
            .lineLimit(1)
          Spacer()
          Text(receipt.status.localizedTitle)
            .foregroundStyle(receipt.status.tint)
        }
        .font(.caption)
      }
    }
    .frame(minHeight: 48)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("history.receipt.\(receipt.id.rawValue.uuidString)")
  }

  private var accessibilityLabel: String {
    let receiptSummary = L10n.formatted(
      "history.receipt.accessibility",
      receipt.kind.localizedTitle,
      receipt.deviceName,
      receipt.status.localizedTitle
    )
    guard let reason = receipt.opaquePayload?.reason else { return receiptSummary }
    let badge =
      reason == .corrupted
      ? L10n.text("receipt.corrupted.badge")
      : L10n.text("receipt.read-only.badge")
    return "\(receiptSummary)，\(badge)"
  }
}

extension AppModel {
  var overviewPendingReceipts: [OperationReceipt] {
    overview?.pendingReceipts.sorted { $0.startedAt > $1.startedAt } ?? []
  }
}
