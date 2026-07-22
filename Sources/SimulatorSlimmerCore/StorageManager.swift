import Darwin
import Foundation

protocol StorageManaging: Sendable {
  func scan(device: SimulatorDevice) async throws -> StoragePlan
  func latestPlan(for deviceID: SimulatorID) async -> StoragePlan?
  func clean(
    device: SimulatorDevice,
    planID: UUID,
    categoryIDs: Set<String>
  ) async throws -> Int64
}

actor StorageManager: StorageManaging {
  private var records: [UUID: StoragePlanRecord] = [:]
  private var latestPlanIDs: [SimulatorID: UUID] = [:]
  private let planLifetime: Duration

  init(planLifetime: Duration = .seconds(10 * 60)) {
    self.planLifetime = planLifetime
  }

  func scan(device: SimulatorDevice) async throws -> StoragePlan {
    guard let rootURL = device.dataPath else {
      throw SimulatorWorkspaceError.invalidOperation("模拟器没有可读取的数据目录")
    }

    let record = try await Task.detached(priority: .userInitiated) {
      try Self.buildRecord(device: device, rootURL: rootURL)
    }.value
    records[record.plan.id] = record
    latestPlanIDs[device.id] = record.plan.id
    purgeExpiredRecords()
    return record.plan
  }

  func latestPlan(for deviceID: SimulatorID) async -> StoragePlan? {
    guard let id = latestPlanIDs[deviceID], let record = records[id],
      !isExpired(record)
    else { return nil }
    return record.plan
  }

  func clean(
    device: SimulatorDevice,
    planID: UUID,
    categoryIDs: Set<String>
  ) async throws -> Int64 {
    guard let record = records[planID], record.plan.deviceID == device.id,
      !isExpired(record)
    else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }
    guard !categoryIDs.isEmpty else { return 0 }

    let allowedCategoryIDs = Set(
      record.plan.categories.filter(\.canClean).map(\.id)
    )
    guard categoryIDs.isSubset(of: allowedCategoryIDs) else {
      throw SimulatorWorkspaceError.invalidOperation("清理请求包含受保护类别")
    }
    guard let currentRoot = device.dataPath else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }

    let selectedTargets = record.targets.filter { categoryIDs.contains($0.categoryID) }
    let reclaimed = try await Task.detached(priority: .userInitiated) {
      try Self.deleteContents(
        targets: selectedTargets,
        expectedRoot: record.canonicalRoot,
        currentRoot: currentRoot
      )
    }.value
    records.removeValue(forKey: planID)
    if latestPlanIDs[device.id] == planID {
      latestPlanIDs.removeValue(forKey: device.id)
    }
    return reclaimed
  }

  private func purgeExpiredRecords() {
    let expired = records.filter { isExpired($0.value) }.map(\.key)
    for id in expired { records.removeValue(forKey: id) }
    latestPlanIDs = latestPlanIDs.filter { _, planID in records[planID] != nil }
  }

  private func isExpired(_ record: StoragePlanRecord) -> Bool {
    ContinuousClock.now - record.createdAt > planLifetime
  }

  private static func buildRecord(
    device: SimulatorDevice,
    rootURL: URL
  ) throws -> StoragePlanRecord {
    let fileManager = FileManager()
    let canonicalRoot = try canonicalDataRoot(rootURL)
    let candidates = try structuredTargets(
      canonicalRoot: canonicalRoot,
      fileManager: fileManager
    )

    var targets: [StorageTarget] = []
    for candidate in candidates {
      try Task.checkCancellation()
      guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
      try validatePath(candidate.url, inside: canonicalRoot, allowRoot: false)
      guard let identity = fileIdentity(at: candidate.url) else { continue }
      let bytes = try allocatedSize(of: candidate.url, inside: canonicalRoot)
      targets.append(
        StorageTarget(
          categoryID: candidate.categoryID,
          url: candidate.url,
          identity: identity,
          scannedBytes: bytes
        )
      )
    }

    let cacheBytes = sum(targets, categoryID: StorageCategory.cache.id)
    let logBytes = sum(targets, categoryID: StorageCategory.logs.id)
    let temporaryBytes = sum(targets, categoryID: StorageCategory.temporary.id)
    let safeBytes = cacheBytes + logBytes + temporaryBytes

    let appContainersURL =
      canonicalRoot
      .appendingPathComponent("Containers/Data/Application", isDirectory: true)
    let appContainersBytes = try safeAllocatedSize(
      of: appContainersURL,
      inside: canonicalRoot
    )
    let appSafeBytes =
      targets
      .filter { target in
        Self.isDescendant(target.url, of: appContainersURL)
      }
      .reduce(Int64(0)) { $0 + $1.scannedBytes }
    let appDataBytes = max(0, appContainersBytes - appSafeBytes)

    let appBundlesURL =
      canonicalRoot
      .appendingPathComponent("Containers/Bundle/Application", isDirectory: true)
    let appBundleBytes = try safeAllocatedSize(
      of: appBundlesURL,
      inside: canonicalRoot
    )
    let totalBytes = max(device.dataSize ?? 0, safeBytes + appDataBytes + appBundleBytes)
    let unknownBytes = max(0, totalBytes - safeBytes - appDataBytes - appBundleBytes)

    let summaries = [
      StorageCategory.cache.summary(bytes: cacheBytes, targets: targets),
      StorageCategory.logs.summary(bytes: logBytes, targets: targets),
      StorageCategory.temporary.summary(bytes: temporaryBytes, targets: targets),
      StorageCategory.appData.summary(bytes: appDataBytes, targets: targets),
      StorageCategory.appBundles.summary(bytes: appBundleBytes, targets: targets),
      StorageCategory.unknown.summary(bytes: unknownBytes, targets: targets),
    ]

    let plan = StoragePlan(
      deviceID: device.id,
      totalBytes: totalBytes,
      cleanableBytes: safeBytes,
      categories: summaries,
      items: targets.map { target in
        StorageItemSummary(
          categoryID: target.categoryID,
          relativePath: relativePath(target.url, inside: canonicalRoot),
          bytes: target.scannedBytes
        )
      }.sorted {
        if $0.categoryID != $1.categoryID { return $0.categoryID < $1.categoryID }
        return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
      }
    )
    return StoragePlanRecord(
      plan: plan,
      canonicalRoot: canonicalRoot,
      targets: targets,
      createdAt: ContinuousClock.now
    )
  }

  private static func structuredTargets(
    canonicalRoot: URL,
    fileManager: FileManager
  ) throws -> [StorageTargetCandidate] {
    var candidates: [StorageTargetCandidate] = [
      .init(
        categoryID: StorageCategory.cache.id, relativePath: "Library/Caches", root: canonicalRoot),
      .init(categoryID: StorageCategory.logs.id, relativePath: "Library/Logs", root: canonicalRoot),
      .init(
        categoryID: StorageCategory.logs.id, relativePath: "private/var/log", root: canonicalRoot),
      .init(
        categoryID: StorageCategory.logs.id, relativePath: "private/var/db/diagnostics",
        root: canonicalRoot),
      .init(
        categoryID: StorageCategory.logs.id, relativePath: "private/var/db/uuidtext",
        root: canonicalRoot),
      .init(categoryID: StorageCategory.temporary.id, relativePath: "tmp", root: canonicalRoot),
      .init(
        categoryID: StorageCategory.temporary.id, relativePath: "private/tmp", root: canonicalRoot),
      .init(
        categoryID: StorageCategory.temporary.id, relativePath: "private/var/tmp",
        root: canonicalRoot),
    ]

    let applicationRoot =
      canonicalRoot
      .appendingPathComponent("Containers/Data/Application", isDirectory: true)
    if fileManager.fileExists(atPath: applicationRoot.path) {
      try validatePath(applicationRoot, inside: canonicalRoot, allowRoot: false)
      let containers = try fileManager.contentsOfDirectory(
        at: applicationRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      for container in containers {
        let values = try container.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
          UUID(uuidString: container.lastPathComponent) != nil
        else { continue }
        candidates.append(
          .init(
            categoryID: StorageCategory.cache.id, relativePath: "Library/Caches", root: container)
        )
        candidates.append(
          .init(categoryID: StorageCategory.logs.id, relativePath: "Library/Logs", root: container)
        )
        candidates.append(
          .init(categoryID: StorageCategory.temporary.id, relativePath: "tmp", root: container)
        )
      }
    }

    return candidates
  }

  private static func deleteContents(
    targets: [StorageTarget],
    expectedRoot: URL,
    currentRoot: URL
  ) throws -> Int64 {
    let fileManager = FileManager()
    let currentCanonicalRoot = try canonicalDataRoot(currentRoot)
    guard currentCanonicalRoot.path == expectedRoot.path else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }

    var reclaimed: Int64 = 0
    for target in targets {
      try Task.checkCancellation()
      try validatePath(target.url, inside: expectedRoot, allowRoot: false)
      guard fileIdentity(at: target.url) == target.identity else {
        throw SimulatorWorkspaceError.staleStoragePlan
      }

      let children = try fileManager.contentsOfDirectory(
        at: target.url,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      )
      for child in children {
        try Task.checkCancellation()
        try validatePath(child, inside: expectedRoot, allowRoot: false)
        let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { continue }
        let before = try allocatedSize(of: child, inside: expectedRoot)
        try fileManager.removeItem(at: child)
        reclaimed += before
      }
    }
    return reclaimed
  }

  private static func canonicalDataRoot(_ rootURL: URL) throws -> URL {
    let root = rootURL.standardizedFileURL
    var info = stat()
    guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      (info.st_mode & S_IFMT) != S_IFLNK
    else {
      throw SimulatorWorkspaceError.unsafePath(root.path)
    }
    let resolved = root.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path == root.path else {
      throw SimulatorWorkspaceError.unsafePath(root.path)
    }
    return root
  }

  static func validatePath(_ candidate: URL, inside root: URL, allowRoot: Bool) throws {
    let normalized = candidate.standardizedFileURL
    let normalizedRoot = root.standardizedFileURL
    guard
      (allowRoot && normalized.path == normalizedRoot.path)
        || isDescendant(normalized, of: normalizedRoot)
    else {
      throw SimulatorWorkspaceError.unsafePath(candidate.path)
    }

    let relative = normalized.path.dropFirst(normalizedRoot.path.count)
      .split(separator: "/")
    var current = normalizedRoot
    for component in relative {
      current.appendPathComponent(String(component))
      var info = stat()
      guard lstat(current.path, &info) == 0,
        (info.st_mode & S_IFMT) != S_IFLNK
      else {
        throw SimulatorWorkspaceError.unsafePath(current.path)
      }
    }
  }

  static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
  }

  private static func relativePath(_ candidate: URL, inside root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    guard candidatePath.hasPrefix(rootPath) else { return candidate.lastPathComponent }
    return String(candidatePath.dropFirst(rootPath.count)).trimmingCharacters(
      in: CharacterSet(charactersIn: "/")
    )
  }

  private static func allocatedSize(of url: URL, inside root: URL) throws -> Int64 {
    try validatePath(url, inside: root, allowRoot: false)
    let fileManager = FileManager()
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey,
    ]
    let rootValues = try url.resourceValues(forKeys: keys)
    guard rootValues.isSymbolicLink != true else {
      throw SimulatorWorkspaceError.unsafePath(url.path)
    }
    if rootValues.isDirectory != true {
      return Int64(rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0)
    }

    var total: Int64 = 0
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { _, _ in true }
      )
    else { return 0 }

    for case let child as URL in enumerator {
      try Task.checkCancellation()
      let values = try child.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      try validatePath(child, inside: root, allowRoot: false)
      if values.isDirectory != true {
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }
    return total
  }

  private static func safeAllocatedSize(of url: URL, inside root: URL) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    return try allocatedSize(of: url, inside: root)
  }

  private static func fileIdentity(at url: URL) -> FileIdentity? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
  }

  private static func sum(_ targets: [StorageTarget], categoryID: String) -> Int64 {
    targets.lazy.filter { $0.categoryID == categoryID }.reduce(0) {
      $0 + $1.scannedBytes
    }
  }
}

private struct StoragePlanRecord: Sendable {
  let plan: StoragePlan
  let canonicalRoot: URL
  let targets: [StorageTarget]
  let createdAt: ContinuousClock.Instant
}

private struct StorageTarget: Sendable {
  let categoryID: String
  let url: URL
  let identity: FileIdentity
  let scannedBytes: Int64
}

private struct FileIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

private struct StorageTargetCandidate: Sendable {
  let categoryID: String
  let url: URL

  init(categoryID: String, relativePath: String, root: URL) {
    self.categoryID = categoryID
    self.url = root.appendingPathComponent(relativePath, isDirectory: true)
  }
}

private enum StorageCategory: String, CaseIterable, Sendable {
  case cache
  case logs
  case temporary
  case appData
  case appBundles
  case unknown

  var id: String { rawValue }

  func summary(bytes: Int64, targets: [StorageTarget]) -> StorageCategorySummary {
    switch self {
    case .cache:
      return .init(
        id: id, name: "缓存", summary: "系统及 App 的可重建缓存",
        consequence: "首次重新打开相关功能时可能稍慢",
        recovery: "系统和 App 会按需自动重建", risk: .low,
        isDefaultSelected: true, canClean: true, bytes: bytes,
        targetCount: targets.filter { $0.categoryID == id }.count
      )
    case .logs:
      return .init(
        id: id, name: "日志", summary: "系统及 App 运行日志",
        consequence: "会失去当前模拟器中的历史诊断记录",
        recovery: "后续运行会生成新日志", risk: .low,
        isDefaultSelected: true, canClean: true, bytes: bytes,
        targetCount: targets.filter { $0.categoryID == id }.count
      )
    case .temporary:
      return .init(
        id: id, name: "临时文件", summary: "结构化临时目录中的内容",
        consequence: "未完成的临时任务可能需要重新开始",
        recovery: "需要时会重新生成", risk: .restoredOnDemand,
        isDefaultSelected: true, canClean: true, bytes: bytes,
        targetCount: targets.filter { $0.categoryID == id }.count
      )
    case .appData:
      return .init(
        id: id, name: "App 数据", summary: "文档、数据库及偏好设置",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes, targetCount: 0
      )
    case .appBundles:
      return .init(
        id: id, name: "已安装 App Bundle", summary: "模拟器中安装的应用本体",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes, targetCount: 0
      )
    case .unknown:
      return .init(
        id: id, name: "未知或受保护路径", summary: "未列入安全允许列表的内容",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes, targetCount: 0
      )
    }
  }
}
