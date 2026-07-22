import Foundation

struct ServiceCatalog: Sendable {
  let schemaVersion: Int
  let categories: [ServiceCategory]
  let services: [ManagedService]

  static func bundled() throws -> ServiceCatalog {
    guard let url = Bundle.module.url(forResource: "ServiceCatalog", withExtension: "json") else {
      throw SimulatorWorkspaceError.malformedOutput("应用内缺少服务目录")
    }
    return try decode(Data(contentsOf: url))
  }

  static func decode(_ data: Data) throws -> ServiceCatalog {
    let document: ServiceCatalogDocument
    do {
      document = try JSONDecoder().decode(ServiceCatalogDocument.self, from: data)
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(
        "服务目录不是有效 JSON：\(error.localizedDescription)"
      )
    }

    guard document.schemaVersion == 1 else {
      throw SimulatorWorkspaceError.malformedOutput(
        "不支持服务目录版本 \(document.schemaVersion)"
      )
    }

    let categoryIDs = document.categories.map(\.id)
    guard Set(categoryIDs).count == categoryIDs.count else {
      throw SimulatorWorkspaceError.malformedOutput("服务目录存在重复分类 ID")
    }

    let serviceIDs = document.services.map(\.id)
    let labels = document.services.map(\.label)
    guard Set(serviceIDs).count == serviceIDs.count,
      Set(labels).count == labels.count
    else {
      throw SimulatorWorkspaceError.malformedOutput("服务目录存在重复服务 ID 或标签")
    }

    let knownCategories = Set(categoryIDs)
    for service in document.services {
      guard knownCategories.contains(service.categoryID) else {
        throw SimulatorWorkspaceError.malformedOutput(
          "服务 \(service.label) 引用了未知分类 \(service.categoryID)"
        )
      }
      guard SimctlAdapter.isValidLaunchdLabel(service.label) else {
        throw SimulatorWorkspaceError.malformedOutput(
          "服务目录包含无效标签 \(service.label)"
        )
      }
      if service.alwaysEnabled || service.risk == .protected {
        guard service.profiles.isEmpty else {
          throw SimulatorWorkspaceError.malformedOutput(
            "受保护服务 \(service.label) 不能加入优化档位"
          )
        }
      }
    }

    return ServiceCatalog(
      schemaVersion: document.schemaVersion,
      categories: document.categories,
      services: document.services
    )
  }

  func applicableServices(runtimeVersion: String) -> [ManagedService] {
    guard let major = Self.runtimeMajor(runtimeVersion) else { return services }
    return services.filter { service in
      if let minimum = service.minimumRuntimeMajor, major < minimum { return false }
      if let maximum = service.maximumRuntimeMajor, major > maximum { return false }
      return true
    }
  }

  func serviceStates(
    runtimeVersion: String,
    disabledLabels: Set<String>
  ) -> [ServiceState] {
    applicableServices(runtimeVersion: runtimeVersion).map {
      ServiceState(service: $0, isDisabled: disabledLabels.contains($0.label))
    }
  }

  func plan(
    deviceID: SimulatorID,
    runtimeVersion: String,
    profile: OptimizationProfile,
    currentDisabledLabels: Set<String>,
    customDisabledLabels: Set<String> = []
  ) -> OptimizationPlan {
    let applicable = applicableServices(runtimeVersion: runtimeVersion)
    let servicesByLabel = Dictionary(uniqueKeysWithValues: applicable.map { ($0.label, $0) })
    let protected = applicable.filter { $0.alwaysEnabled || $0.risk == .protected }
    let mutable = applicable.filter { !$0.alwaysEnabled && $0.risk != .protected }
    let mutableLabels = Set(mutable.map(\.label))

    let desired: Set<String>
    if profile == .custom {
      desired = customDisabledLabels.intersection(mutableLabels)
    } else {
      desired = Set(mutable.filter { $0.profiles.contains(profile) }.map(\.label))
    }

    var changes: [ServiceChange] = []
    for label in desired.subtracting(currentDisabledLabels).sorted() {
      guard let service = servicesByLabel[label] else { continue }
      changes.append(Self.change(service: service, transition: .disable))
    }

    let labelsToEnable =
      currentDisabledLabels
      .intersection(mutableLabels)
      .subtracting(desired)
      .union(currentDisabledLabels.intersection(Set(protected.map(\.label))))
    for label in labelsToEnable.sorted() {
      guard let service = servicesByLabel[label] else { continue }
      changes.append(Self.change(service: service, transition: .enable))
    }

    let allCatalogLabels = Set(services.map(\.label))
    return OptimizationPlan(
      deviceID: deviceID,
      profile: profile,
      changes: changes,
      protectedLabels: protected.map(\.label).sorted(),
      unknownDisabledLabels: currentDisabledLabels.subtracting(allCatalogLabels).sorted()
    )
  }

  private static func change(
    service: ManagedService,
    transition: ServiceTransition
  ) -> ServiceChange {
    ServiceChange(
      label: service.label,
      serviceName: service.name,
      categoryID: service.categoryID,
      risk: service.risk,
      transition: transition
    )
  }

  private static func runtimeMajor(_ version: String) -> Int? {
    Int(version.split(separator: ".", maxSplits: 1).first ?? "")
  }
}

private struct ServiceCatalogDocument: Decodable {
  let schemaVersion: Int
  let categories: [ServiceCategory]
  let services: [ManagedService]
}
