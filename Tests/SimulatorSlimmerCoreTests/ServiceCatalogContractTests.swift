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
    #expect(catalog.categories.count == 14)
    #expect(catalog.services.count == 105)
    #expect(catalog.categories.allSatisfy { containsHanCharacter($0.name) })
    #expect(catalog.categories.allSatisfy { containsHanCharacter($0.summary) })
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

  @Test("三个内置方案按风险逐级扩展")
  func profilesAreNestedAndFollowRiskPolicy() throws {
    let catalog = try loadCatalog()
    let conservative = labels(for: .conservative, in: catalog.services)
    let balanced = labels(for: .balanced, in: catalog.services)
    let efficient = labels(for: .efficient, in: catalog.services)

    #expect(!conservative.isEmpty)
    #expect(!balanced.isEmpty)
    #expect(!efficient.isEmpty)
    #expect(conservative.isSubset(of: balanced))
    #expect(balanced.isSubset(of: efficient))
    #expect(conservative.count == 31)
    #expect(balanced.count == 59)
    #expect(efficient.count == 102)

    for service in catalog.services {
      let expectedProfiles: Set<OptimizationProfile> =
        switch service.risk {
        case .low:
          [.conservative, .balanced, .efficient]
        case .moderate:
          [.balanced, .efficient]
        case .high:
          [.efficient]
        case .protected:
          []
        }
      #expect(service.profiles == expectedProfiles)
      #expect(!service.profiles.contains(.custom))
    }
  }

  @Test("关键服务始终受保护且不会进入禁用方案")
  func alwaysEnabledServicesAreProtected() throws {
    let catalog = try loadCatalog()
    let requiredLabels: Set<String> = [
      "com.apple.sharingd",
      "com.apple.SpringBoard",
      "com.apple.backboardd",
    ]
    let protectedServices = catalog.services.filter(\.alwaysEnabled)
    let protectedLabels = Set(protectedServices.map(\.label))
    let optimizationCandidates = catalog.services.filter {
      !$0.alwaysEnabled && $0.risk != .protected
    }

    #expect(protectedLabels == requiredLabels)
    #expect(optimizationCandidates.count == 102)

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
