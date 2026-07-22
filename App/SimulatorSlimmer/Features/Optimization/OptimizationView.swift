import SimulatorSlimmerCore
import SwiftUI

struct OptimizationView: View {
  let snapshot: DeviceSnapshot
  @Bindable var model: AppModel

  private var presentServices: [ServiceState] {
    snapshot.services.filter(\.isPresent)
  }

  private var disabledServiceCount: Int {
    presentServices.filter(\.isDisabled).count
  }

  private var effectiveChanges: [ServiceChange] {
    if model.selectedProfile == .custom {
      return presentServices.compactMap { state in
        let shouldDisable = model.customDisabledLabels.contains(state.service.label)
        guard
          !state.service.alwaysEnabled,
          state.service.risk != .protected,
          state.isDisabled != shouldDisable
        else { return nil }
        return ServiceChange(
          label: state.service.label,
          serviceName: state.service.name,
          categoryID: state.service.categoryID,
          risk: state.service.risk,
          transition: shouldDisable ? .disable : .enable,
          impact: state.service.impact,
          currentDisabled: state.isDisabled,
          targetDisabled: shouldDisable
        )
      }
    }
    return snapshot.plans[model.selectedProfile]?.changes ?? []
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        operationState
        metrics
        profilePanel
        planPanel
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.bottom, InstrumentTheme.pagePadding)
    }
    .scrollIndicators(.visible)
    .accessibilityIdentifier("optimization.page")
  }

  @ViewBuilder
  private var operationState: some View {
    if let operation = model.operations[snapshot.device.id] {
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
          title: L10n.text("result.failed.title"),
          message: failure,
          actionTitle: L10n.text("action.retry"),
          action: model.runOptimization
        )
      }
    } else if let pending = model.overview?.pendingReceipts.first(where: {
      $0.deviceID == snapshot.device.id
    }) {
      NoticeStrip(
        tone: .warning,
        title: L10n.text("pending-receipt.title"),
        message: L10n.text("pending-receipt.message"),
        actionTitle: L10n.text("receipt.view"),
        action: { model.showReceipt(pending) }
      )
    }
  }

  private var metrics: some View {
    HStack(spacing: 16) {
      MetricCard(
        eyebrow: "metric.memory",
        value: snapshot.memory.map { ValueFormatter.bytes($0.bytes) }
          ?? L10n.text("metric.unavailable"),
        unitDetail: memoryDetail,
        symbol: "memorychip",
        tint: .mint
      )

      MetricCard(
        eyebrow: "metric.services",
        value: L10n.formatted("format.items", disabledServiceCount),
        unitDetail: L10n.formatted(
          "metric.services.detail",
          effectiveChanges.count,
          presentServices.count
        ),
        symbol: "switch.2",
        tint: effectiveChanges.isEmpty ? .mint : .orange,
        progress: presentServices.isEmpty
          ? 0
          : Double(disabledServiceCount) / Double(presentServices.count)
      )
    }
  }

  private var memoryDetail: String {
    if let memory = snapshot.memory {
      return L10n.formatted(
        "metric.memory.detail",
        memory.processCount,
        memory.collectedAt.formatted(date: .omitted, time: .shortened)
      )
    }
    return snapshot.memoryError ?? L10n.text("metric.memory.not-running")
  }

  private var profilePanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(
          title: "optimization.profile.title",
          detail: model.selectedProfile == .balanced
            ? L10n.text("profile.recommended")
            : nil
        )

        Picker("optimization.profile.title", selection: $model.selectedProfile) {
          ForEach(OptimizationProfile.allCases) { profile in
            Text(profile.localizedTitle).tag(profile)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minHeight: InstrumentTheme.minimumHitSize)
        .accessibilityLabel("optimization.profile.title")

        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: model.selectedProfile == .efficient
              ? "exclamationmark.triangle.fill"
              : "info.circle.fill"
          )
          .foregroundStyle(model.selectedProfile == .efficient ? .orange : .mint)
          .accessibilityHidden(true)
          Text(model.selectedProfile.localizedSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if model.selectedProfile == .custom {
          Divider()
          CustomServicePicker(snapshot: snapshot, model: model)
        }
      }
    }
  }

  private var planPanel: some View {
    InstrumentCard {
      VStack(alignment: .leading, spacing: 16) {
        InstrumentSectionLabel(
          title: "optimization.plan.title",
          detail: L10n.formatted("format.changes", effectiveChanges.count)
        )

        if effectiveChanges.isEmpty {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
              .font(.title2)
              .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 3) {
              Text("optimization.plan.empty.title")
                .font(.subheadline.weight(.semibold))
              Text("optimization.plan.empty.message")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 8)
          .accessibilityElement(children: .combine)
        } else {
          ChangePlanList(changes: effectiveChanges, categories: snapshot.categories)
        }

        Divider()

        HStack(spacing: 10) {
          if let latestReceipt = model.latestVerifiableReceipt {
            Button {
              model.continueLatestVerification()
            } label: {
              Label("action.continue-verification", systemImage: "checkmark.magnifyingglass")
            }
            .disabled(isBusy)
            .minimumHitArea()
            .accessibilityHint(
              L10n.formatted(
                "action.continue-verification.hint",
                latestReceipt.startedAt.formatted(date: .abbreviated, time: .shortened)
              )
            )
          }

          if let latestReceipt = model.latestRestorableReceipt {
            Button {
              model.restoreLatest()
            } label: {
              Label("action.restore-last", systemImage: "arrow.uturn.backward")
            }
            .disabled(isBusy)
            .minimumHitArea()
            .accessibilityHint(
              L10n.formatted(
                "action.restore-last.hint",
                latestReceipt.startedAt.formatted(date: .abbreviated, time: .shortened)
              )
            )
          }

          Spacer()

          Button("action.preview-changes") {
            model.requestOptimizationPreview()
          }
          .disabled(effectiveChanges.isEmpty || isBusy)
          .minimumHitArea()

          Button {
            model.runOptimization()
          } label: {
            Label("action.optimize-device", systemImage: "gauge.with.dots.needle.50percent")
          }
          .buttonStyle(PressablePrimaryButtonStyle())
          .disabled(effectiveChanges.isEmpty || isBusy || !snapshot.device.isAvailable)
          .accessibilityHint("action.optimize-device.hint")
        }
      }
    }
  }

  private var isBusy: Bool {
    model.isDeviceBusy(snapshot.device.id)
  }
}

private struct CustomServicePicker: View {
  let snapshot: DeviceSnapshot
  let model: AppModel
  @State private var expandedCategories: Set<String> = []

  private var categoryServices: [(ServiceCategory, [ServiceState])] {
    snapshot.categories.compactMap { category in
      let services = snapshot.services
        .filter { $0.isPresent && $0.service.categoryID == category.id }
        .sorted { $0.service.name.localizedStandardCompare($1.service.name) == .orderedAscending }
      return services.isEmpty ? nil : (category, services)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("custom-services.title")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(L10n.formatted("format.selected-items", model.customDisabledLabels.count))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      ForEach(categoryServices, id: \.0.id) { category, services in
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedCategories.contains(category.id) },
            set: { expanded in
              if expanded {
                expandedCategories.insert(category.id)
              } else {
                expandedCategories.remove(category.id)
              }
            }
          )
        ) {
          VStack(spacing: 0) {
            ForEach(services) { state in
              CustomServiceRow(state: state, model: model)
              if state.id != services.last?.id { Divider() }
            }
          }
          .padding(.leading, 26)
          .padding(.top, 6)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: category.symbol)
              .foregroundStyle(.mint)
              .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
              Text(category.name)
              Text(category.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L10n.formatted("format.items", services.count))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .frame(minHeight: 40)
        }
      }
    }
  }
}

private struct CustomServiceRow: View {
  let state: ServiceState
  let model: AppModel

  private var isLocked: Bool {
    state.service.alwaysEnabled || state.service.risk == .protected
  }

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { model.customDisabledLabels.contains(state.service.label) },
        set: { model.toggleCustomService(state.service.label, disabled: $0) }
      )
    ) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(state.service.name)
            RiskBadge(risk: state.service.risk)
          }
          Text(state.service.impact)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(state.service.label)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        Spacer(minLength: 8)
      }
    }
    .toggleStyle(.switch)
    .disabled(isLocked)
    .padding(.vertical, 8)
    .frame(minHeight: 40)
    .accessibilityHint(
      isLocked
        ? L10n.text("custom-services.protected.hint")
        : L10n.text("custom-services.toggle.hint")
    )
  }
}

private struct ChangePlanList: View {
  let changes: [ServiceChange]
  let categories: [ServiceCategory]
  @State private var expandedCategoryIDs: Set<String> = []

  private var groups: [(id: String, name: String, symbol: String, changes: [ServiceChange])] {
    let grouped = Dictionary(grouping: changes, by: \.categoryID)
    return grouped.map { id, changes in
      let category = categories.first { $0.id == id }
      return (
        id: id,
        name: category?.name ?? id,
        symbol: category?.symbol ?? "square.grid.2x2",
        changes: changes.sorted { $0.serviceName < $1.serviceName }
      )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 8) {
      ForEach(groups, id: \.id) { group in
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedCategoryIDs.contains(group.id) },
            set: { expanded in
              if expanded {
                expandedCategoryIDs.insert(group.id)
              } else {
                expandedCategoryIDs.remove(group.id)
              }
            }
          )
        ) {
          VStack(spacing: 0) {
            ForEach(group.changes) { change in
              ServiceChangeRow(change: change)
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
        }
      }
    }
  }
}

private struct ServiceChangeRow: View {
  let change: ServiceChange

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: change.transition == .disable
          ? "pause.circle.fill"
          : "play.circle.fill"
      )
      .foregroundStyle(change.transition == .disable ? .orange : .mint)
      .padding(.top, 1)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(change.serviceName)
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
  }
}
