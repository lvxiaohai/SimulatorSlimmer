import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("存储安全边界")
struct StorageManagerBehaviorTests {
  @Test("拒绝根目录外路径和直接校验的符号链接路径")
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

      #expect(throws: SimulatorWorkspaceError.self) {
        try StorageManager.validatePath(
          caches,
          inside: fixture.root,
          allowRoot: false
        )
      }
    }
  }

  @Test("真实 CoreSimulator 日志符号链接会作为受保护项跳过")
  func skipsCoreSimulatorHostLogsSymlinkAsProtected() async throws {
    try await withStorageFixture { fixture in
      let hostLogs = fixture.container
        .appendingPathComponent("Library/Logs/CoreSimulator", isDirectory: true)
        .appendingPathComponent(fixture.device.id.rawValue, isDirectory: true)
      let hostLogFile = hostLogs.appendingPathComponent("system.log")
      try writeFixtureFile(at: hostLogFile)

      let simulatorLogs = fixture.root
        .appendingPathComponent("Library/Logs", isDirectory: true)
      try FileManager.default.createDirectory(
        at: simulatorLogs.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        at: simulatorLogs,
        withDestinationURL: hostLogs
      )
      let simulatorCache = fixture.root
        .appendingPathComponent("Library/Caches/cache.bin")
      try writeFixtureFile(at: simulatorCache)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let protected = try #require(plan.categories.first { $0.id == "unknown" })

      #expect(protected.targetCount == 1)
      #expect(
        plan.items.contains {
          $0.categoryID == "unknown" && $0.relativePath == "Library/Logs"
            && $0.bytes == 0
        }
      )
      #expect(!plan.items.contains { $0.categoryID == "logs" })

      _ = try await collectCleanup(
        manager,
        device: fixture.device,
        planID: plan.id,
        categoryIDs: ["cache", "logs"]
      )
      #expect(FileManager.default.fileExists(atPath: hostLogFile.path))
      #expect(!FileManager.default.fileExists(atPath: simulatorCache.path))
    }
  }

  @Test("所有结构化候选中的符号链接都会安全跳过")
  func skipsEveryStructuredTargetSymlink() async throws {
    try await withStorageFixture { fixture in
      let appID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
      let linkedAppID = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
      let appRoot = fixture.root
        .appendingPathComponent("Containers/Data/Application", isDirectory: true)
        .appendingPathComponent(appID, isDirectory: true)
      try FileManager.default.createDirectory(
        at: appRoot,
        withIntermediateDirectories: true
      )

      var relativePaths = [
        "Library/Caches",
        "Library/Logs",
        "private/var/log",
        "private/var/db/diagnostics",
        "private/var/db/uuidtext",
        "tmp",
        "private/tmp",
        "private/var/tmp",
        "Containers/Data/Application/\(appID)/Library/Caches",
        "Containers/Data/Application/\(appID)/Library/Logs",
        "Containers/Data/Application/\(appID)/tmp",
      ]
      let outsideRoot = fixture.container.appendingPathComponent(
        "host-targets",
        isDirectory: true
      )
      var hostFiles: [URL] = []
      for (index, relativePath) in relativePaths.enumerated() {
        let destination = outsideRoot.appendingPathComponent(
          "target-\(index)",
          isDirectory: true
        )
        let hostFile = destination.appendingPathComponent("host.log")
        try writeFixtureFile(at: hostFile)
        hostFiles.append(hostFile)

        let link = fixture.root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
          at: link.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
          at: link,
          withDestinationURL: destination
        )
      }

      let linkedContainerDestination = outsideRoot.appendingPathComponent(
        "linked-container",
        isDirectory: true
      )
      let linkedContainerHostFile = linkedContainerDestination.appendingPathComponent(
        "Documents/database.sqlite"
      )
      try writeFixtureFile(at: linkedContainerHostFile)
      hostFiles.append(linkedContainerHostFile)
      let linkedContainerRelativePath = "Containers/Data/Application/\(linkedAppID)"
      relativePaths.append(linkedContainerRelativePath)
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent(linkedContainerRelativePath, isDirectory: true),
        withDestinationURL: linkedContainerDestination
      )

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let protected = try #require(plan.categories.first { $0.id == "unknown" })
      let protectedPaths = Set(
        plan.items.filter { $0.categoryID == "unknown" }.map(\.relativePath)
      )

      #expect(protected.targetCount == relativePaths.count)
      #expect(protectedPaths == Set(relativePaths))
      #expect(plan.cleanableBytes == 0)
      for hostFile in hostFiles {
        #expect(FileManager.default.fileExists(atPath: hostFile.path))
      }
    }
  }

  @Test("受保护数据根目录的符号链接不会终止扫描")
  func skipsProtectedRootSymlinks() async throws {
    try await withStorageFixture { fixture in
      let outsideRoot = fixture.container.appendingPathComponent(
        "host-protected-roots",
        isDirectory: true
      )
      let roots = [
        "Containers/Data/Application",
        "Containers/Bundle/Application",
      ]
      var hostFiles: [URL] = []
      for (index, relativePath) in roots.enumerated() {
        let destination = outsideRoot.appendingPathComponent(
          "target-\(index)",
          isDirectory: true
        )
        let hostFile = destination.appendingPathComponent("host.data")
        try writeFixtureFile(at: hostFile)
        hostFiles.append(hostFile)

        let link = fixture.root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
          at: link.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
          at: link,
          withDestinationURL: destination
        )
      }

      let plan = try await StorageManager().scan(device: fixture.device)
      let protected = try #require(plan.categories.first { $0.id == "unknown" })
      let protectedPaths = Set(
        plan.items.filter { $0.categoryID == "unknown" }.map(\.relativePath)
      )

      #expect(protected.targetCount == roots.count)
      #expect(protectedPaths == Set(roots))
      for hostFile in hostFiles {
        #expect(FileManager.default.fileExists(atPath: hostFile.path))
      }
    }
  }

  @Test("清理目录中的符号链接子项不会被跟随或删除")
  func skipsSymbolicLinkChildrenDuringCleanup() async throws {
    try await withStorageFixture { fixture in
      let cacheDirectory = fixture.root
        .appendingPathComponent("Library/Caches", isDirectory: true)
      let localCache = cacheDirectory.appendingPathComponent("local.cache")
      try writeFixtureFile(at: localCache)

      let hostDirectory = fixture.container.appendingPathComponent(
        "host-cache",
        isDirectory: true
      )
      let hostFile = hostDirectory.appendingPathComponent("host.cache")
      try writeFixtureFile(at: hostFile)
      let hostLink = cacheDirectory.appendingPathComponent("host-link", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        at: hostLink,
        withDestinationURL: hostDirectory
      )

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let reclaimed = try await collectCleanup(
        manager,
        device: fixture.device,
        planID: plan.id,
        categoryIDs: ["cache"]
      )

      #expect(reclaimed > 0)
      #expect(!FileManager.default.fileExists(atPath: localCache.path))
      #expect(FileManager.default.fileExists(atPath: hostLink.path))
      #expect(FileManager.default.fileExists(atPath: hostFile.path))
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
      #expect(plan.items.contains { $0.relativePath.hasSuffix("Library/Caches") })
      #expect(!plan.items.contains { $0.relativePath.contains("Containers/Bundle/Application") })

      let reclaimed = try await collectCleanup(
        manager,
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

  @Test("扫描后新增直接子项会让计划失效且不会删除任何项目")
  func rejectsAddedDirectChildBeforeDeleting() async throws {
    try await withStorageFixture { fixture in
      let cacheDirectory = fixture.root
        .appendingPathComponent("Library/Caches", isDirectory: true)
      let scannedFile = cacheDirectory.appendingPathComponent("scanned.cache")
      let addedFile = cacheDirectory.appendingPathComponent("added.cache")
      try writeFixtureFile(at: scannedFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      try writeFixtureFile(at: addedFile)

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: scannedFile.path))
      #expect(FileManager.default.fileExists(atPath: addedFile.path))
    }
  }

  @Test("扫描后设备变为已启动时拒绝清理")
  func rejectsBootedDeviceAfterShutdownScan() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root.appendingPathComponent("Library/Caches/cache.bin")
      try writeFixtureFile(at: cacheFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let bootedDevice = SimulatorDevice(
        id: fixture.device.id,
        name: fixture.device.name,
        runtimeIdentifier: fixture.device.runtimeIdentifier,
        runtimeName: fixture.device.runtimeName,
        deviceTypeIdentifier: fixture.device.deviceTypeIdentifier,
        state: .booted,
        isAvailable: true,
        dataPath: fixture.device.dataPath
      )

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: bootedDevice,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }
  }

  @Test("持久化确认前不会开始删除下一个目标")
  func waitsForPersistenceAcknowledgmentBeforeNextTarget() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root
        .appendingPathComponent("Library/Caches/cache.bin")
      let logFile = fixture.root
        .appendingPathComponent("Library/Logs/system.log")
      try writeFixtureFile(at: cacheFile)
      try writeFixtureFile(at: logFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      let stream = try await manager.clean(
        device: fixture.device,
        planID: plan.id,
        categoryIDs: ["cache", "logs"]
      )
      var iterator = stream.makeAsyncIterator()

      let firstPending = try #require(try await iterator.next())
      #expect(firstPending.stage == .pending)
      #expect(firstPending.relativePath == "Library/Caches/cache.bin")
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
      try await Task.sleep(for: .milliseconds(30))
      #expect(FileManager.default.fileExists(atPath: logFile.path))

      firstPending.acknowledgePersistence()
      let firstCompleted = try #require(try await iterator.next())
      #expect(firstCompleted.stage == .completed)
      #expect(firstCompleted.relativePath == "Library/Caches/cache.bin")
      #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
      #expect(FileManager.default.fileExists(atPath: logFile.path))

      firstCompleted.acknowledgePersistence()
      let secondPending = try #require(try await iterator.next())
      #expect(secondPending.stage == .pending)
      #expect(secondPending.relativePath == "Library/Logs/system.log")
      #expect(FileManager.default.fileExists(atPath: logFile.path))

      secondPending.acknowledgePersistence()
      let secondCompleted = try #require(try await iterator.next())
      #expect(secondCompleted.stage == .completed)
      #expect(!FileManager.default.fileExists(atPath: logFile.path))

      secondCompleted.acknowledgePersistence()
      #expect(try await iterator.next() == nil)
    }
  }

  @Test("扫描后同名子项被替换会让计划失效")
  func rejectsReplacedDirectChild() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root
        .appendingPathComponent("Library/Caches/replaced.cache")
      try writeFixtureFile(at: cacheFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      try FileManager.default.removeItem(at: cacheFile)
      try writeFixtureFile(at: cacheFile, byteCount: 32 * 1_024)

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }
  }

  @Test("扫描后目录内部新增项目会让计划失效")
  func rejectsNestedAddedItem() async throws {
    try await withStorageFixture { fixture in
      let nestedDirectory = fixture.root
        .appendingPathComponent("Library/Caches/tree", isDirectory: true)
      let scannedFile = nestedDirectory.appendingPathComponent("scanned.cache")
      let addedFile = nestedDirectory.appendingPathComponent("added.cache")
      try writeFixtureFile(at: scannedFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      try writeFixtureFile(at: addedFile)

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: scannedFile.path))
      #expect(FileManager.default.fileExists(atPath: addedFile.path))
    }
  }

  @Test("扫描后同 inode 同大小内容变化会让计划失效")
  func rejectsSameIdentityContentChange() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root
        .appendingPathComponent("Library/Caches/mutable.cache")
      try writeFixtureFile(at: cacheFile)
      let inodeBefore = try #require(
        FileManager.default.attributesOfItem(atPath: cacheFile.path)[.systemFileNumber]
          as? NSNumber
      )

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      try await Task.sleep(for: .milliseconds(2))
      let handle = try FileHandle(forWritingTo: cacheFile)
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: Data(repeating: 0xA5, count: 16 * 1_024))
      try handle.synchronize()
      try handle.close()
      let inodeAfter = try #require(
        FileManager.default.attributesOfItem(atPath: cacheFile.path)[.systemFileNumber]
          as? NSNumber
      )
      #expect(inodeAfter == inodeBefore)

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }
  }

  @Test("多目标会全部预检后再开始删除")
  func preflightsEveryTargetBeforeDeletingAnyTarget() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root
        .appendingPathComponent("Library/Caches/cache.bin")
      let logDirectory = fixture.root
        .appendingPathComponent("Library/Logs", isDirectory: true)
      let logFile = logDirectory.appendingPathComponent("system.log")
      let addedLogFile = logDirectory.appendingPathComponent("added.log")
      try writeFixtureFile(at: cacheFile)
      try writeFixtureFile(at: logFile)

      let manager = StorageManager()
      let plan = try await manager.scan(device: fixture.device)
      try writeFixtureFile(at: addedLogFile)

      await #expect(throws: SimulatorWorkspaceError.self) {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache", "logs"]
        )
      }
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
      #expect(FileManager.default.fileExists(atPath: logFile.path))
      #expect(FileManager.default.fileExists(atPath: addedLogFile.path))
    }
  }

  @Test("取消调用方会停止 detached 清理任务")
  func cancellationStopsDetachedCleanup() async throws {
    try await withStorageFixture { fixture in
      let cacheFile = fixture.root
        .appendingPathComponent("Library/Caches/cache.bin")
      try writeFixtureFile(at: cacheFile)

      let checkpoint = BlockingStorageCheckpoint()
      let manager = StorageManager(
        deletionCheckpoint: { try await checkpoint.pause() }
      )
      let plan = try await manager.scan(device: fixture.device)
      let cleanup = Task {
        try await collectCleanup(
          manager,
          device: fixture.device,
          planID: plan.id,
          categoryIDs: ["cache"]
        )
      }

      await checkpoint.waitUntilEntered()
      cleanup.cancel()
      await #expect(throws: CancellationError.self) {
        try await cleanup.value
      }
      #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }
  }

  @Test("取消调用方会停止 detached 扫描任务")
  func cancellationStopsDetachedScan() async throws {
    try await withStorageFixture { fixture in
      let checkpoint = BlockingStorageCheckpoint()
      let manager = StorageManager(
        scanCheckpoint: { try await checkpoint.pause() }
      )
      let scan = Task {
        try await manager.scan(device: fixture.device)
      }

      await checkpoint.waitUntilEntered()
      scan.cancel()
      await #expect(throws: CancellationError.self) {
        try await scan.value
      }
      #expect(await manager.latestPlan(for: fixture.device.id) == nil)
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
        try await collectCleanup(
          expiredManager,
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
        try await collectCleanup(
          manager,
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

private func collectCleanup(
  _ manager: StorageManager,
  device: SimulatorDevice,
  planID: UUID,
  categoryIDs: Set<String>
) async throws -> Int64 {
  let progress = try await manager.clean(
    device: device,
    planID: planID,
    categoryIDs: categoryIDs
  )
  var reclaimed: Int64 = 0
  for try await item in progress {
    reclaimed = item.reclaimedBytes
    item.acknowledgePersistence()
  }
  try Task.checkCancellation()
  return reclaimed
}

private actor BlockingStorageCheckpoint {
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func pause() async throws {
    entered = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters { waiter.resume() }
    try await Task.sleep(for: .seconds(30))
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
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
