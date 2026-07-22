import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("存储安全边界")
struct StorageManagerBehaviorTests {
  @Test("拒绝根目录外路径和符号链接路径")
  func rejectsEscapedAndSymbolicLinkPaths() async throws {
    try await withStorageFixture { fixture in
      let sibling = fixture.container
        .appendingPathComponent("data-escape", isDirectory: true)
      try FileManager.default.createDirectory(
        at: sibling,
        withIntermediateDirectories: true
      )

      #expect(throws: SimulatorWorkspaceError.self) {
        try StorageManager.validatePath(
          sibling,
          inside: fixture.root,
          allowRoot: false
        )
      }

      let outside = fixture.container
        .appendingPathComponent("outside-cache", isDirectory: true)
      try FileManager.default.createDirectory(
        at: outside,
        withIntermediateDirectories: true
      )
      let caches = fixture.root
        .appendingPathComponent("Library/Caches", isDirectory: true)
      try FileManager.default.createDirectory(
        at: caches.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        at: caches,
        withDestinationURL: outside
      )

      let manager = StorageManager()
      await #expect(throws: SimulatorWorkspaceError.self) {
        try await manager.scan(device: fixture.device)
      }
    }
  }

  @Test("只清理结构化允许路径并保留 App 主数据和 Bundle")
  func cleansAllowlistedTargetsWithoutTouchingProtectedAppContent() async throws {
    try await withStorageFixture { fixture in
      let appID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
      let appRoot = fixture.root
        .appendingPathComponent("Containers/Data/Application", isDirectory: true)
        .appendingPathComponent(appID, isDirectory: true)
      let appCache =
        appRoot
        .appendingPathComponent("Library/Caches/cache.bin", isDirectory: false)
      let appDocument =
        appRoot
        .appendingPathComponent("Documents/database.sqlite", isDirectory: false)
      let systemCache = fixture.root
        .appendingPathComponent("Library/Caches/system.cache", isDirectory: false)
      let appBundle = fixture.root
        .appendingPathComponent("Containers/Bundle/Application", isDirectory: true)
        .appendingPathComponent(appID, isDirectory: true)
        .appendingPathComponent("Fixture.app/Fixture", isDirectory: false)

      try writeFixtureFile(at: appCache)
      try writeFixtureFile(at: appDocument)
      try writeFixtureFile(at: systemCache)
      try writeFixtureFile(at: appBundle)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let categories = Dictionary(
        uniqueKeysWithValues: plan.categories.map { ($0.id, $0) }
      )

      let cache = try #require(categories["cache"])
      let appData = try #require(categories["appData"])
      let bundles = try #require(categories["appBundles"])
      #expect(cache.canClean)
      #expect(cache.targetCount == 2)
      #expect(cache.bytes > 0)
      #expect(!appData.canClean)
      #expect(appData.bytes > 0)
      #expect(!bundles.canClean)
      #expect(bundles.bytes > 0)
      #expect(plan.cleanableBytes == cache.bytes)

      let reclaimed = try await manager.clean(
        device: fixture.device,
        planID: plan.id,
        categoryIDs: ["cache"]
      )

      #expect(reclaimed > 0)
      #expect(!FileManager.default.fileExists(atPath: appCache.path))
      #expect(!FileManager.default.fileExists(atPath: systemCache.path))
      #expect(FileManager.default.fileExists(atPath: appDocument.path))
      #expect(FileManager.default.fileExists(atPath: appBundle.path))
    }
  }

  @Test("过期计划和目标目录身份变化都会拒绝清理")
  func rejectsExpiredPlanAndChangedTargetIdentity() async throws {
    try await withStorageFixture { fixture in
      let cacheDirectory = fixture.root
        .appendingPathComponent("Library/Caches", isDirectory: true)
      try writeFixtureFile(
        at: cacheDirectory.appendingPathComponent("old.cache")
      )

      let expiredManager = StorageManager(planLifetime: .zero)
      let expiredPlan = try await expiredManager.scan(device: fixture.device)
      await #expect(throws: SimulatorWorkspaceError.self) {
        try await expiredManager.clean(
          device: fixture.device,
          planID: expiredPlan.id,
          categoryIDs: ["cache"]
        )
      }

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let movedDirectory =
        cacheDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("Caches-before-scan", isDirectory: true)
      try FileManager.default.moveItem(
        at: cacheDirectory,
        to: movedDirectory
      )
      try FileManager.default.createDirectory(
        at: cacheDirectory,
        withIntermediateDirectories: true
      )
      try writeFixtureFile(
        at: cacheDirectory.appendingPathComponent("replacement.cache")
      )

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await manager.clean(
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(
        FileManager.default.fileExists(
          atPath: cacheDirectory.appendingPathComponent("replacement.cache").path
        )
      )
    }
  }
}

private struct StorageFixture {
  let container: URL
  let root: URL
  let device: SimulatorDevice
}

private func withStorageFixture<T>(
  _ body: (StorageFixture) async throws -> T
) async throws -> T {
  try await withTemporaryDirectory { container in
    let root = container.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let canonicalRoot = root.resolvingSymlinksInPath()
    let device = SimulatorDevice(
      id: SimulatorID(
        rawValue: "11111111-2222-4333-8444-555555555555"
      ),
      name: "存储测试设备",
      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
      runtimeName: "iOS 26.5",
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      state: .shutdown,
      isAvailable: true,
      dataPath: canonicalRoot
    )
    return try await body(
      StorageFixture(container: container, root: canonicalRoot, device: device)
    )
  }
}

private func writeFixtureFile(at url: URL, byteCount: Int = 16 * 1_024) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(repeating: 0x5A, count: byteCount).write(to: url)
}
