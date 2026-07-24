import SimulatorSlimmerCore
import SwiftUI

struct StorageView: View {
  let snapshot: DeviceSnapshot
  @Bindable var model: AppModel
  @State private var showingDetails = false
  @State private var isShowingShutdownConfirmation = false

  private var plan: StoragePlan? { snapshot.latestStoragePlan }

  private var selectedCategories: [StorageCategorySummary] {
    plan?.categories.filter { model.selectedStorageCategoryIDs.contains($0.id) } ?? []
  }

  private var selectedBytes: Int64 {
    selectedCategories.reduce(0) { $0 + $1.bytes }
  }

  private var isBusy: Bool {
    model.isDeviceBusy(snapshot.device.id)
  }

  private var requiresShutdown: Bool {
    snapshot.device.state != .shutdown
  }

  private var canRequestShutdown: Bool {
    snapshot.device.state == .booted && !isBusy
  }

  private var canRunStorageOperations: Bool {
    !requiresShutdown && !isBusy
  }

  var body: some View {
    InstrumentPageScroll {
      operationState

      if requiresShutdown {
        shutdownRequiredNotice
      }

      if let plan {
        storageOverview(plan)
        categoriesPanel(plan)
      } else {
        emptyScanState
      }
    }
    .accessibilityIdentifier("storage.page")
    .sheet(isPresented: $showingDetails) {
      if let plan {
        StorageDetailsSheet(plan: plan)
      }
    }
    .confirmationDialog(
      "operation.shutdown",
      isPresented: $isShowingShutdownConfirmation,
      titleVisibility: .visible
    ) {
      Button("action.shutdown") {
        model.runDeviceOperation(.shutdown)
      }
      Button("action.cancel", role: .cancel) {}
    } message: {
      Text("action.shutdown.summary")
    }
  }

  private var shutdownRequiredNotice: some View {
    NoticeStrip(
      tone: .warning,
      title: L10n.text("storage.shutdown-required.title"),
      message: L10n.text("storage.shutdown-required.message"),
      actionTitle: canRequestShutdown ? L10n.text("action.shutdown") : nil,
      action: canRequestShutdown ? { isShowingShutdownConfirmation = true } : nil,
      actionSymbol: canRequestShutdown ? "power" : nil
    )
    .accessibilityIdentifier("storage.shutdown-required")
  }

  @ViewBuilder
  private var operationState: some View {
    if let operation = model.operations[snapshot.device.id] {
      if operation.isRunning,
        operation.operation.kind == .scanStorage || operation.operation.kind == .cleanStorage
      {
        OperationProgressPanel(
          presentation: operation,
          stop: model.requestStop
        )
      } else if let receipt = operation.receipt,
        receipt.kind == .scanStorage || receipt.kind == .cleanStorage
      {
        OperationResultBanner(receipt: receipt)
      } else if let message = operation.failureMessage,
        operation.operation.kind == .scanStorage || operation.operation.kind == .cleanStorage
      {
        if canRunStorageOperations {
          NoticeStrip(
            tone: .error,
            title: L10n.text("storage.failed.title"),
            message: message,
            actionTitle: L10n.text("action.rescan"),
            action: model.scanStorage
          )
        } else {
          NoticeStrip(
            tone: .error,
            title: L10n.text("storage.failed.title"),
            message: message
          )
        }
      }
    }
  }

  private func storageOverview(_ plan: StoragePlan) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        totalStorageMetric(plan)
          .frame(minWidth: 230)
        cleanableStorageMetric(plan)
          .frame(minWidth: 230)
      }
      VStack(spacing: 12) {
        totalStorageMetric(plan)
        cleanableStorageMetric(plan)
      }
    }
  }

  private func totalStorageMetric(_ plan: StoragePlan) -> some View {
    MetricCard(
      eyebrow: "storage.total",
      value: ValueFormatter.bytes(plan.totalBytes),
      unitDetail: L10n.formatted(
        "storage.scanned-at",
        plan.generatedAt.formatted(date: .omitted, time: .shortened)
      ),
      symbol: "internaldrive",
      tint: .blue
    )
  }

  private func cleanableStorageMetric(_ plan: StoragePlan) -> some View {
    MetricCard(
      eyebrow: "storage.cleanable",
      value: ValueFormatter.bytes(plan.cleanableBytes),
      unitDetail: L10n.formatted("storage.selected", ValueFormatter.bytes(selectedBytes)),
      symbol: "sparkles",
      tint: .mint,
      progress: plan.totalBytes == 0
        ? 0
        : Double(plan.cleanableBytes) / Double(plan.totalBytes)
    )
  }

  private func categoriesPanel(_ plan: StoragePlan) -> some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(
          title: "storage.categories.title",
          detail: L10n.formatted(
            "format.targets", selectedCategories.reduce(0) { $0 + $1.targetCount })
        )

        VStack(spacing: 0) {
          ForEach(plan.categories.filter(\.canClean)) { category in
            StorageCategoryRow(
              category: category,
              isSelected: model.selectedStorageCategoryIDs.contains(category.id),
              isEnabled: canRunStorageOperations,
              setSelected: {
                model.toggleStorageCategory(category.id, selected: $0)
              }
            )
            if category.id != plan.categories.filter(\.canClean).last?.id {
              Divider()
            }
          }
        }

        let protected = plan.categories.filter { !$0.canClean }
        if !protected.isEmpty {
          Divider()
          Text("storage.protected.title")
            .font(.subheadline.weight(.semibold))
          VStack(spacing: 0) {
            ForEach(protected) { category in
              ProtectedStorageRow(category: category)
              if category.id != protected.last?.id { Divider() }
            }
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 4) {
          Label("storage.safety-note", systemImage: "checkmark.shield.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              Spacer()
              detailsAction(plan)
              rescanAction
              cleanupAction
            }
            VStack(alignment: .trailing, spacing: 4) {
              detailsAction(plan)
              rescanAction
              cleanupAction
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
  }

  private func detailsAction(_ plan: StoragePlan) -> some View {
    Button("action.view-details") {
      showingDetails = true
    }
    .disabled(plan.items.isEmpty)
    .minimumHitArea()
  }

  private var rescanAction: some View {
    Button("action.rescan") {
      model.scanStorage()
    }
    .disabled(!canRunStorageOperations)
    .minimumHitArea()
    .help(
      canRunStorageOperations
        ? L10n.text("action.rescan")
        : L10n.text("storage.shutdown-required.title")
    )
  }

  private var cleanupAction: some View {
    Button {
      model.requestStorageCleanup()
    } label: {
      Label(
        L10n.formatted("action.clean-bytes", ValueFormatter.bytes(selectedBytes)),
        systemImage: "sparkles"
      )
    }
    .buttonStyle(PressablePrimaryButtonStyle())
    .disabled(selectedCategories.isEmpty || !canRunStorageOperations)
    .help(
      canRunStorageOperations
        ? L10n.text("storage.safety-note")
        : L10n.text("storage.shutdown-required.title")
    )
  }

  private var emptyScanState: some View {
    InstrumentEmptyState(
      symbol: "externaldrive",
      badgeSymbol: "magnifyingglass",
      tint: .mint,
      title: L10n.text("storage.empty.title"),
      message: L10n.text("storage.empty.message")
    ) {
      Button {
        model.scanStorage()
      } label: {
        Label("action.scan-storage", systemImage: "magnifyingglass")
      }
      .buttonStyle(PressablePrimaryButtonStyle())
      .disabled(!canRunStorageOperations)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}

private struct StorageDetailsSheet: View {
  let plan: StoragePlan
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "list.bullet.rectangle.portrait")
          .font(.title2)
          .foregroundStyle(.mint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("storage.details.title")
            .font(.title3.weight(.semibold))
          Text("storage.details.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(16)
      .background(.bar)

      Divider()

      List {
        ForEach(plan.categories) { category in
          let items = plan.items.filter { $0.categoryID == category.id }
          if !items.isEmpty {
            Section(category.name) {
              ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(item.relativePath)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                  Spacer(minLength: 16)
                  if category.canClean {
                    Text(ValueFormatter.bytes(item.bytes))
                      .font(.callout.monospacedDigit())
                      .foregroundStyle(.secondary)
                  } else {
                    Label("storage.details.protected-item", systemImage: "lock.fill")
                      .font(.caption.weight(.medium))
                      .foregroundStyle(.secondary)
                  }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
              }
            }
          }
        }
      }
      .listStyle(.inset)

      Divider()

      HStack {
        Label("storage.details.privacy", systemImage: "hand.raised")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("action.close") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .minimumHitArea()
      }
      .padding(16)
    }
    .frame(minWidth: 620, minHeight: 480)
    .suppressInitialFocus()
    .accessibilityIdentifier("storage-details.sheet")
  }
}

private struct StorageCategoryRow: View {
  let category: StorageCategorySummary
  let isSelected: Bool
  let isEnabled: Bool
  let setSelected: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { isSelected },
        set: { newValue in setSelected(newValue) }
      )
    ) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: symbol)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.mint)
          .frame(width: 24)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(category.name)
            .font(.subheadline.weight(.medium))
          Text(category.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(category.consequence)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 3) {
          Text(ValueFormatter.bytes(category.bytes))
            .font(.subheadline.weight(.semibold).monospacedDigit())
          Text(L10n.formatted("format.targets", category.targetCount))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .toggleStyle(.checkbox)
    .disabled(!isEnabled)
    .padding(.vertical, 10)
    .frame(minHeight: 44)
    .accessibilityHint(category.recovery)
  }

  private var symbol: String {
    switch category.id.lowercased() {
    case let id where id.contains("log"): "doc.text"
    case let id where id.contains("tmp") || id.contains("temp"): "hourglass.bottomhalf.filled"
    default: "shippingbox"
    }
  }
}

private struct ProtectedStorageRow: View {
  let category: StorageCategorySummary

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "lock.shield.fill")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(category.name)
          .font(.subheadline.weight(.medium))
        Text(category.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        Text(ValueFormatter.bytes(category.bytes))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
        if category.targetCount > 0 {
          Text(L10n.formatted("format.targets", category.targetCount))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 10)
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
    .accessibilityHint("storage.protected.hint")
  }
}
