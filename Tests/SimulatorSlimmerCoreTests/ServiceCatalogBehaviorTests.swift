import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("服务方案行为")
struct ServiceCatalogBehaviorTests {
  @Test("旧版方案值可迁移到新版方案")
  func legacyProfileValuesMigrate() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    for value in ["conservative", "balanced"] {
      let profile = try decoder.decode(
        OptimizationProfile.self,
        from: Data("\"\(value)\"".utf8)
      )
      #expect(profile == .recommended)
    }

    let efficient = try decoder.decode(
      OptimizationProfile.self,
      from: Data("\"efficient\"".utf8)
    )
    #expect(efficient == .extreme)
    #expect(String(decoding: try encoder.encode(efficient), as: UTF8.self) == "\"extreme\"")

    let enableAllServices = try decoder.decode(
      OptimizationProfile.self,
      from: Data("\"allEnabled\"".utf8)
    )
    #expect(enableAllServices == .enableAllServices)
    #expect(
      String(decoding: try encoder.encode(enableAllServices), as: UTF8.self)
        == "\"allEnabled\""
    )
  }

  @Test("全部启用只恢复目录内可管理服务")
  func enableAllServicesRestoresOnlyManagedServices() {
    let catalog = makeBehaviorCatalog()
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    let plan = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: "26.5",
      profile: .enableAllServices,
      currentDisabledLabels: [
        "com.test.low",
        "com.test.moderate",
        "com.test.protected",
        "com.other.unmanaged",
      ]
    )

    #expect(
      plan.changes.map { "\($0.label):\($0.transition.rawValue)" } == [
        "com.test.low:enable",
        "com.test.moderate:enable",
        "com.test.protected:enable",
      ]
    )
    #expect(plan.desiredDisabledLabels.isEmpty)
    #expect(plan.unknownDisabledLabels == ["com.other.unmanaged"])
  }

  @Test("方案只生成必要差异并保留未知标签")
  func planContainsOnlyRequiredDifferences() {
    let catalog = makeBehaviorCatalog()
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    let plan = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: "26.5",
      profile: .recommended,
      currentDisabledLabels: [
        "com.test.moderate",
        "com.test.protected",
        "com.other.unmanaged",
      ]
    )

    #expect(
      plan.changes.map { "\($0.label):\($0.transition.rawValue)" } == [
        "com.test.low:disable",
        "com.test.moderate:enable",
        "com.test.protected:enable",
      ]
    )
    #expect(plan.protectedLabels == ["com.test.protected"])
    #expect(plan.unknownDisabledLabels == ["com.other.unmanaged"])
  }

  @Test("自定义方案忽略未知及受保护标签")
  func customPlanRejectsLabelsOutsideMutableAllowlist() {
    let catalog = makeBehaviorCatalog()
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")

    let plan = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: "26.5",
      profile: .custom,
      currentDisabledLabels: [],
      customDisabledLabels: [
        "com.test.high",
        "com.test.protected",
        "com.other.unmanaged",
      ]
    )

    #expect(plan.changes.map(\.label) == ["com.test.high"])
    #expect(plan.changes.allSatisfy { $0.transition == .disable })
    #expect(!plan.changes.contains { $0.label == "com.test.protected" })
    #expect(!plan.changes.contains { $0.label == "com.other.unmanaged" })
  }

  @Test("受保护服务写入优化档位时拒绝目录")
  func protectedServiceCannotBelongToProfile() {
    let document = """
      {
        "schemaVersion": 1,
        "supportedRuntimeVersions": ["26.5"],
        "categories": [
          {"id":"system","name":"系统","summary":"系统能力","symbol":"gear"}
        ],
        "services": [
          {
            "id":"protected",
            "label":"com.test.protected",
            "name":"受保护服务",
            "impact":"必须保持启用",
            "categoryID":"system",
            "risk":"protected",
            "profiles":["recommended"],
            "alwaysEnabled":true
          }
        ]
      }
      """

    #expect(throws: SimulatorWorkspaceError.self) {
      try ServiceCatalog.decode(Data(document.utf8))
    }
  }

  @Test("Runtime 中不存在的目录服务只读显示且不进入计划")
  func absentServicesAreNeverChanged() {
    let catalog = makeBehaviorCatalog()
    let deviceID = SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555")
    let presentLabels: Set<String> = ["com.test.low", "com.test.protected"]

    let plan = catalog.plan(
      deviceID: deviceID,
      runtimeVersion: "26.5",
      profile: .extreme,
      currentDisabledLabels: [],
      presentLabels: presentLabels
    )
    let states = catalog.serviceStates(
      runtimeVersion: "26.5",
      disabledLabels: [],
      presentLabels: presentLabels
    )

    #expect(plan.changes.map(\.label) == ["com.test.low"])
    #expect(states.first { $0.service.label == "com.test.low" }?.isPresent == true)
    #expect(states.first { $0.service.label == "com.test.moderate" }?.isPresent == false)
    #expect(states.first { $0.service.label == "com.test.high" }?.isPresent == false)
  }

  @Test("优化候选排除不存在及受保护服务")
  func optimizationCandidatesExcludeUnavailableAndProtectedServices() {
    let catalog = makeBehaviorCatalog()
    let states = catalog.serviceStates(
      runtimeVersion: "26.5",
      disabledLabels: [],
      presentLabels: [
        "com.test.low",
        "com.test.moderate",
        "com.test.protected",
      ]
    )

    #expect(
      states
        .filter(\.isOptimizationCandidate)
        .map(\.service.label)
        .sorted()
        == [
          "com.test.low",
          "com.test.moderate",
        ]
    )
  }

  @Test("无法解析的 Runtime 版本默认拒绝全部服务规则")
  func malformedRuntimeVersionDefaultsToNoServices() {
    let catalog = makeBehaviorCatalog()
    let plan = catalog.plan(
      deviceID: SimulatorID(rawValue: "11111111-2222-4333-8444-555555555555"),
      runtimeVersion: "unknown-runtime",
      profile: .extreme,
      currentDisabledLabels: []
    )

    #expect(catalog.applicableServices(runtimeVersion: "unknown-runtime").isEmpty)
    #expect(plan.changes.isEmpty)
  }

  @Test("只允许经过实机验证的精确 Runtime 版本")
  func onlyExplicitlyVerifiedRuntimeVersionsAreMutable() {
    let catalog = makeBehaviorCatalog()

    #expect(!catalog.applicableServices(runtimeVersion: "26.3.1").isEmpty)
    #expect(!catalog.applicableServices(runtimeVersion: "26.5").isEmpty)
    #expect(catalog.applicableServices(runtimeVersion: "26.3").isEmpty)
    #expect(catalog.applicableServices(runtimeVersion: "26.4").isEmpty)
    #expect(catalog.applicableServices(runtimeVersion: "26.6").isEmpty)
  }
}

private func makeBehaviorCatalog() -> ServiceCatalog {
  let category = ServiceCategory(
    id: "system",
    name: "系统",
    summary: "测试分类",
    symbol: "gear"
  )
  let services = [
    ManagedService(
      id: "low",
      label: "com.test.low",
      name: "低风险服务",
      impact: "低风险影响",
      categoryID: category.id,
      risk: .low,
      profiles: [.recommended, .extreme]
    ),
    ManagedService(
      id: "moderate",
      label: "com.test.moderate",
      name: "中风险服务",
      impact: "中风险影响",
      categoryID: category.id,
      risk: .moderate,
      profiles: [.extreme]
    ),
    ManagedService(
      id: "high",
      label: "com.test.high",
      name: "高风险服务",
      impact: "高风险影响",
      categoryID: category.id,
      risk: .high,
      profiles: [.extreme]
    ),
    ManagedService(
      id: "protected",
      label: "com.test.protected",
      name: "受保护服务",
      impact: "必须保持启用",
      categoryID: category.id,
      risk: .protected,
      profiles: [],
      alwaysEnabled: true
    ),
  ]
  return ServiceCatalog(schemaVersion: 1, categories: [category], services: services)
}
