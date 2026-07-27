import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("服务目录契约")
struct ServiceCatalogContractTests {
  @Test("目录可按公开领域模型解码")
  func catalogDecodesWithPublicDomainTypes() throws {
    let catalog = try loadCatalog()

    #expect(catalog.schemaVersion == 1)
    #expect(catalog.supportedRuntimeVersions == ["26.3.1", "26.5"])
    #expect(catalog.categories.count == 15)
    #expect(catalog.services.count == 171)
    #expect(catalog.categories.allSatisfy { containsHanCharacter($0.name) })
    #expect(catalog.categories.allSatisfy { containsHanCharacter($0.summary) })
    #expect(
      Dictionary(
        uniqueKeysWithValues: catalog.categories.compactMap { category in
          category.approximateIdleMemoryMB.map { (category.id, $0) }
        }
      ) == [
        "widgets": 675,
        "siri": 265,
        "search": 50,
        "icloud": 100,
        "store": 80,
        "pim": 80,
        "web": 50,
        "family": 65,
        "health": 135,
        "photos": 60,
        "apps": 90,
        "messaging": 60,
        "connectivity": 65,
        "telemetry": 105,
        "other": 195,
      ]
    )
    #expect(catalog.services.allSatisfy { containsHanCharacter($0.name) })
    #expect(catalog.services.allSatisfy { containsHanCharacter($0.impact) })
  }

  @Test("分类、服务 ID 和 launchd label 全局唯一")
  func identifiersAndLabelsAreUnique() throws {
    let catalog = try loadCatalog()
    let categoryIDs = catalog.categories.map(\.id)
    let serviceIDs = catalog.services.map(\.id)
    let labels = catalog.services.map(\.label)

    #expect(Set(categoryIDs).count == categoryIDs.count)
    #expect(Set(serviceIDs).count == serviceIDs.count)
    #expect(Set(labels).count == labels.count)

    let knownCategoryIDs = Set(categoryIDs)
    for service in catalog.services {
      #expect(knownCategoryIDs.contains(service.categoryID))
      #expect(!service.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!service.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @Test("推荐方案保留常用能力且极致方案覆盖全部可精简服务")
  func profilesFollowCapabilityPolicy() throws {
    let catalog = try loadCatalog()
    let recommended = labels(for: .recommended, in: catalog.services)
    let extreme = labels(for: .extreme, in: catalog.services)
    let mutable = catalog.services.filter {
      !$0.alwaysEnabled && $0.risk != .protected
    }

    #expect(recommended.count == 142)
    #expect(extreme.count == 170)
    #expect(recommended.isSubset(of: extreme))
    #expect(extreme == Set(mutable.map(\.label)))

    let recommendedKeptCategoryIDs: Set<String> = [
      "store",
      "web",
      "photos",
    ]
    for service in catalog.services {
      if service.alwaysEnabled || service.risk == .protected {
        #expect(service.profiles.isEmpty)
      } else {
        #expect(service.profiles.contains(.extreme))
        let shouldRemainEnabled =
          recommendedKeptCategoryIDs.contains(service.categoryID)
          || service.label == "com.apple.devicecheckd"
        #expect(service.profiles.contains(.recommended) == !shouldRemainEnabled)
      }
      #expect(!service.profiles.contains(.custom))
      #expect(!service.profiles.contains(.enableAllServices))
    }
  }

  @Test("必须开启服务隐藏在可精简集合之外")
  func alwaysEnabledServicesAreProtected() throws {
    let catalog = try loadCatalog()
    let protectedServices = catalog.services.filter(\.alwaysEnabled)
    let protectedLabels = Set(protectedServices.map(\.label))
    let optimizationCandidates = catalog.services.filter {
      !$0.alwaysEnabled && $0.risk != .protected
    }

    #expect(protectedLabels == ["com.apple.sharingd"])
    #expect(optimizationCandidates.count == 170)
    #expect(!catalog.services.contains { $0.label == "com.apple.SpringBoard" })
    #expect(!catalog.services.contains { $0.label == "com.apple.backboardd" })

    for service in catalog.services {
      if service.alwaysEnabled {
        #expect(service.risk == .protected)
        #expect(service.profiles.isEmpty)
      }
      if service.risk == .protected {
        #expect(service.alwaysEnabled)
      }
    }
  }

  @Test("已知会阻塞模拟器的服务永不进入目录")
  func deadlockProneServicesAreNeverManaged() throws {
    let catalog = try loadCatalog()
    let labels = Set(catalog.services.map(\.label))
    let forbiddenLabels: Set<String> = [
      "com.apple.nanoregistryd",
      "com.apple.nanoregistrylaunchd",
      "com.apple.nanoprefsyncd.2",
      "com.apple.nanotimekitcompaniond",
      "com.apple.nanobackupd",
      "com.apple.sleepd",
      "com.apple.appprotectiond",
      "com.apple.ManagedSettingsAgent",
      "com.apple.managedconfiguration.profiled",
      "com.apple.mobiletimerd",
      "com.apple.routined",
      "com.apple.biomed",
      "com.apple.biomesyncd",
      "com.apple.dmd",
      "com.apple.donotdisturbd",
    ]

    #expect(labels.isDisjoint(with: forbiddenLabels))
  }

  @Test("每项规则都显式限定在已验证的 iOS 26 Runtime")
  func everyServiceHasAnExplicitRuntimeRange() throws {
    let catalog = try loadCatalog()

    for service in catalog.services {
      let minimum = try #require(service.minimumRuntimeMajor)
      let maximum = try #require(service.maximumRuntimeMajor)
      #expect(minimum <= maximum)
      #expect(minimum == 26)
      #expect(maximum == 26)
    }
  }

  private func loadCatalog() throws -> CatalogDocument {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot =
      testDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url =
      repositoryRoot
      .appendingPathComponent("Sources", isDirectory: true)
      .appendingPathComponent("SimulatorSlimmerCore", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("ServiceCatalog.json", isDirectory: false)

    return try JSONDecoder().decode(
      CatalogDocument.self,
      from: Data(contentsOf: url)
    )
  }

  private func labels(
    for profile: OptimizationProfile,
    in services: [ManagedService]
  ) -> Set<String> {
    Set(
      services
        .filter { $0.profiles.contains(profile) }
        .map(\.label)
    )
  }

  private func containsHanCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      (0x3400...0x4DBF).contains($0.value)
        || (0x4E00...0x9FFF).contains($0.value)
    }
  }
}

private struct CatalogDocument: Decodable {
  let schemaVersion: Int
  let supportedRuntimeVersions: Set<String>
  let categories: [ServiceCategory]
  let services: [ManagedService]
}
