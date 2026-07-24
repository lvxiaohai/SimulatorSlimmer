import SimulatorSlimmerCore
import SwiftUI

struct OptimizationView: View {
  let snapshot: DeviceSnapshot
  @Bindable var model: AppModel

  private var optimizationServices: [ServiceState] {
    snapshot.services.filter(\.isOptimizationCandidate)
  }

  private var optimizationServiceLabels: Set<String> {
    Set(optimizationServices.map(\.service.label))
  }

  private var disabledServiceCount: Int {
    optimizationServices.filter(\.isDisabled).count
  }

  private var effectiveChanges: [ServiceChange] {
    if model.selectedProfile == .custom {
      return optimizationServices.compactMap { state in
        let shouldDisable = model.customDisabledLabels.contains(state.service.label)
        guard state.isDisabled != shouldDisable else { return nil }
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
    return (snapshot.plans[model.selectedProfile]?.changes ?? []).filter {
      optimizationServiceLabels.contains($0.label)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        operationState
        metrics
        profilePanel
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.bottom, InstrumentTheme.pagePadding)
    }
    .scrollIndicators(.visible)
    .accessibilityIdentifier("optimization.page")
  }

  @ViewBuilder
  private var operationState: some View {
    if let operation = model.operations[snapshot.device.id],
      isOptimizationOperation(operation.operation.kind)
    {
      if operation.isRunning {
        OperationProgressPanel(
          presentation: operation,
          stop: model.requestStop
        )
      } else if let receipt = operation.receipt {
        OperationResultBanner(receipt: receipt)
      } else if let failure = operation.failureMessage {
        NoticeStrip(
          tone: .error,
          title: L10n.text("result.failed.title"),
          message: failure,
          actionTitle: L10n.text("action.retry"),
          action: model.runOptimization
        )
      }
    }
  }

  private func isOptimizationOperation(_ kind: OperationKind) -> Bool {
    switch kind {
    case .preflight, .optimize, .verify, .restore:
      true
    case .scanStorage, .cleanStorage, .boot, .shutdown, .erase, .delete, .clone,
      .openSimulator:
      false
    }
  }

  private var metrics: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        memoryMetric
          .frame(minWidth: 230)
        servicesMetric
          .frame(minWidth: 230)
      }
      VStack(spacing: 12) {
        memoryMetric
        servicesMetric
      }
    }
  }

  private var memoryMetric: some View {
    MetricCard(
      eyebrow: "metric.memory",
      value: snapshot.memory.map { ValueFormatter.bytes($0.bytes) }
        ?? L10n.text("metric.unavailable"),
      unitDetail: memoryDetail,
      symbol: "memorychip",
      tint: .mint
    )
  }

  private var servicesMetric: some View {
    MetricCard(
      eyebrow: "metric.services",
      value: L10n.formatted("format.items", disabledServiceCount),
      unitDetail: L10n.formatted(
        "metric.services.detail",
        effectiveChanges.count,
        optimizationServices.count
      ),
      symbol: "switch.2",
      tint: effectiveChanges.isEmpty ? .mint : .orange,
      progress: optimizationServices.isEmpty
        ? 0
        : Double(disabledServiceCount) / Double(optimizationServices.count)
    )
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
          detail: model.selectedProfile == .recommended
            ? L10n.text("profile.default")
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
        .disabled(isBusy)
        .accessibilityLabel("optimization.profile.title")

        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: model.selectedProfile == .extreme
              ? "exclamationmark.triangle.fill"
              : "info.circle.fill"
          )
          .foregroundStyle(model.selectedProfile == .extreme ? .orange : .mint)
          .accessibilityHidden(true)
          Text(model.selectedProfile.localizedSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if model.selectedProfile == .custom {
          Divider()
          CustomServicePicker(snapshot: snapshot, model: model)
            .disabled(isBusy)
        }

        Divider()

        profileActions
      }
    }
  }

  private var profileActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        continuationAction
        Spacer()
        previewAction
        optimizeAction
      }
      VStack(alignment: .trailing, spacing: 4) {
        continuationAction
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 10) {
          Spacer()
          previewAction
          optimizeAction
        }
      }
    }
  }

  @ViewBuilder
  private var continuationAction: some View {
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
  }

  private var previewAction: some View {
    Button {
      model.requestOptimizationPreview()
    } label: {
      if model.isPreparingPreview(for: snapshot.device.id, confirmsExecution: false) {
        loadingLabel
      } else {
        Text("action.preview-changes")
      }
    }
    .disabled(effectiveChanges.isEmpty || isBusy)
    .minimumHitArea()
  }

  private var optimizeAction: some View {
    Button {
      model.runOptimization()
    } label: {
      if model.isPreparingPreview(for: snapshot.device.id, confirmsExecution: true) {
        loadingLabel
      } else {
        Label("action.optimize-device", systemImage: "gauge.with.dots.needle.50percent")
      }
    }
    .buttonStyle(PressablePrimaryButtonStyle())
    .disabled(effectiveChanges.isEmpty || isBusy || !snapshot.device.isAvailable)
    .accessibilityHint("action.optimize-device.hint")
  }

  private var isBusy: Bool {
    model.isDeviceBusy(snapshot.device.id)
  }

  private var loadingLabel: some View {
    HStack(spacing: 7) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      Text("action.preparing-preview")
    }
    .accessibilityElement(children: .combine)
  }
}

struct CustomServicePicker: View {
  let snapshot: DeviceSnapshot
  let model: AppModel
  @State private var expandedCategories: Set<String> = []

  private var categoryServices: [(ServiceCategory, [ServiceState])] {
    snapshot.categories.compactMap { category in
      let services = snapshot.services
        .filter { $0.isOptimizationCandidate && $0.service.categoryID == category.id }
        .sorted { $0.service.name.localizedStandardCompare($1.service.name) == .orderedAscending }
      return services.isEmpty ? nil : (category, services)
    }
  }

  private var visibleSelectedCount: Int {
    return model.customDisabledLabels.intersection(visibleLabels).count
  }

  private var visibleLabels: Set<String> {
    Set(
      categoryServices.flatMap { _, services in
        services.map(\.service.label)
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("custom-services.title")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(L10n.formatted("format.selected-items", visibleSelectedCount))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button("custom-services.action.select-all") {
          model.setCustomServices(visibleLabels, disabled: true)
        }
        .buttonStyle(.borderless)
        .minimumHitArea()
        .disabled(visibleSelectedCount == visibleLabels.count)
        .accessibilityIdentifier("custom-services.select-all")
        Button("custom-services.action.clear") {
          model.setCustomServices(visibleLabels, disabled: false)
        }
        .buttonStyle(.borderless)
        .minimumHitArea()
        .disabled(visibleSelectedCount == 0)
        .accessibilityIdentifier("custom-services.clear")
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
            CustomServiceGroupActions(
              services: services,
              model: model,
              categoryID: category.id
            )
            Divider()
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
            categoryStatusSummary(for: services)
          }
          .frame(minHeight: 40)
        }
        .disclosureGroupStyle(InstrumentDisclosureGroupStyle())
      }
    }
  }

  private func categoryStatusSummary(for services: [ServiceState]) -> some View {
    let disabledCount = services.count {
      model.customDisabledLabels.contains($0.service.label)
    }

    return Text(
      L10n.formatted(
        "format.disabled-ratio",
        disabledCount,
        services.count
      )
    )
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .layoutPriority(1)
    .accessibilityLabel(
      L10n.formatted(
        "format.disabled-ratio.accessibility",
        disabledCount,
        services.count
      )
    )
    .help(
      L10n.formatted(
        "format.disabled-ratio.accessibility",
        disabledCount,
        services.count
      )
    )
  }
}

private struct CustomServiceGroupActions: View {
  let services: [ServiceState]
  let model: AppModel
  let categoryID: String

  private var labels: Set<String> {
    Set(services.map(\.service.label))
  }

  private var selectedCount: Int {
    model.customDisabledLabels.intersection(labels).count
  }

  var body: some View {
    HStack(spacing: 8) {
      Text("custom-services.group-actions")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("custom-services.action.select-all") {
        model.setCustomServices(labels, disabled: true)
      }
      .buttonStyle(.borderless)
      .minimumHitArea()
      .disabled(selectedCount == labels.count)
      .accessibilityIdentifier("custom-services.group.\(categoryID).select-all")
      Button("custom-services.action.clear") {
        model.setCustomServices(labels, disabled: false)
      }
      .buttonStyle(.borderless)
      .minimumHitArea()
      .disabled(selectedCount == 0)
      .accessibilityIdentifier("custom-services.group.\(categoryID).clear")
    }
    .frame(minHeight: InstrumentTheme.minimumHitSize)
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
