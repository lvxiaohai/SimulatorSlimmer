import SimulatorSlimmerCore
import SwiftUI

struct OptimizationView: View {
  let snapshot: DeviceSnapshot
  @Bindable var model: AppModel

  private var optimizationServices: [ServiceState] {
    snapshot.services.filter(\.isOptimizationCandidate)
  }

  private var disabledServiceCount: Int? {
    model.disabledServiceCount(for: snapshot)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        metrics
        profilePanel
      }
      .padding(.horizontal, InstrumentTheme.pagePadding)
      .padding(.bottom, InstrumentTheme.pagePadding)
    }
    .scrollIndicators(.visible)
    .accessibilityIdentifier("optimization.page")
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
      value: disabledServiceCount.map { L10n.formatted("format.items", $0) } ?? "-",
      unitDetail: nil,
      symbol: "switch.2",
      tint: .mint,
      progress: disabledServiceCount.flatMap { count in
        optimizationServices.isEmpty
          ? nil
          : Double(count) / Double(optimizationServices.count)
      }
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
        InstrumentSectionLabel(title: "optimization.profile.title")

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
    HStack(spacing: 10) {
      Spacer()
      previewAction
      optimizeAction
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
    .disabled(isBusy)
    .minimumHitArea()
  }

  private var optimizeAction: some View {
    Button {
      model.runOptimization()
    } label: {
      if model.isPreparingPreview(for: snapshot.device.id, confirmsExecution: true) {
        loadingLabel
      } else {
        Label(
          model.selectedProfile == .enableAllServices
            ? L10n.text("action.enable-all-services")
            : L10n.text("action.optimize-device"),
          systemImage: model.selectedProfile == .enableAllServices
            ? "play.circle"
            : "gauge.with.dots.needle.50percent"
        )
      }
    }
    .buttonStyle(PressablePrimaryButtonStyle())
    .disabled(isBusy || !snapshot.device.isAvailable)
    .accessibilityHint(
      model.selectedProfile == .enableAllServices
        ? L10n.text("action.enable-all-services.hint")
        : L10n.text("action.optimize-device.hint")
    )
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
          model.replaceCustomServices(with: visibleLabels)
        }
        .buttonStyle(.borderless)
        .minimumHitArea()
        .disabled(model.customDisabledLabels == visibleLabels)
        .accessibilityIdentifier("custom-services.select-all")
        Button("custom-services.action.clear") {
          model.clearCustomServices()
        }
        .buttonStyle(.borderless)
        .minimumHitArea()
        .disabled(model.customDisabledLabels.isEmpty)
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
            VStack(alignment: .trailing, spacing: 2) {
              if let megabytes = category.approximateIdleMemoryMB {
                CategoryMemoryEstimateLabel(
                  megabytes: megabytes,
                  style: .approximate
                )
              }
              categoryStatusSummary(for: services)
            }
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
