import Darwin
import Foundation

protocol StorageManaging: Sendable {
  func scan(device: SimulatorDevice) async throws -> StoragePlan
  func latestPlan(for deviceID: SimulatorID) async -> StoragePlan?
  func clean(
    device: SimulatorDevice,
    planID: UUID,
    categoryIDs: Set<String>
  ) async throws -> AsyncThrowingStream<StorageCleanupProgress, Error>
}

enum StorageCleanupStage: Sendable {
  case pending
  case completed
}

struct StorageCleanupProgress: Sendable {
  let stage: StorageCleanupStage
  let relativePath: String
  let targetRelativePath: String
  let targetReclaimedBytes: Int64
  let reclaimedBytes: Int64
  let completedTargetCount: Int
  let totalTargetCount: Int
  private let acknowledgment: StorageProgressAcknowledgment?

  init(
    stage: StorageCleanupStage = .completed,
    relativePath: String,
    targetRelativePath: String? = nil,
    targetReclaimedBytes: Int64,
    reclaimedBytes: Int64,
    completedTargetCount: Int,
    totalTargetCount: Int
  ) {
    self.stage = stage
    self.relativePath = relativePath
    self.targetRelativePath = targetRelativePath ?? relativePath
    self.targetReclaimedBytes = targetReclaimedBytes
    self.reclaimedBytes = reclaimedBytes
    self.completedTargetCount = completedTargetCount
    self.totalTargetCount = totalTargetCount
    self.acknowledgment = nil
  }

  fileprivate init(
    stage: StorageCleanupStage,
    relativePath: String,
    targetRelativePath: String,
    targetReclaimedBytes: Int64,
    reclaimedBytes: Int64,
    completedTargetCount: Int,
    totalTargetCount: Int,
    acknowledgment: StorageProgressAcknowledgment
  ) {
    self.stage = stage
    self.relativePath = relativePath
    self.targetRelativePath = targetRelativePath
    self.targetReclaimedBytes = targetReclaimedBytes
    self.reclaimedBytes = reclaimedBytes
    self.completedTargetCount = completedTargetCount
    self.totalTargetCount = totalTargetCount
    self.acknowledgment = acknowledgment
  }

  func acknowledgePersistence() {
    acknowledgment?.acknowledge()
  }
}

actor StorageManager: StorageManaging {
  private var records: [UUID: StoragePlanRecord] = [:]
  private var latestPlanIDs: [SimulatorID: UUID] = [:]
  private let planLifetime: Duration
  private let scanCheckpoint: @Sendable () async throws -> Void
  private let deletionCheckpoint: @Sendable () async throws -> Void

  init(
    planLifetime: Duration = .seconds(10 * 60),
    scanCheckpoint: @escaping @Sendable () async throws -> Void = {
      try Task.checkCancellation()
    },
    deletionCheckpoint: @escaping @Sendable () async throws -> Void = {
      try Task.checkCancellation()
    }
  ) {
    self.planLifetime = planLifetime
    self.scanCheckpoint = scanCheckpoint
    self.deletionCheckpoint = deletionCheckpoint
  }

  func scan(device: SimulatorDevice) async throws -> StoragePlan {
    guard device.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "请先关闭模拟器，再重新扫描存储并确认清理范围"
      )
    }
    guard let rootURL = device.dataPath else {
      throw SimulatorWorkspaceError.invalidOperation("模拟器没有可读取的数据目录")
    }

    let checkpoint = scanCheckpoint
    let scanTask = Task.detached(priority: .userInitiated) {
      try await Self.buildRecord(
        device: device,
        rootURL: rootURL,
        checkpoint: checkpoint
      )
    }
    let record = try await withTaskCancellationHandler {
      try await scanTask.value
    } onCancel: {
      scanTask.cancel()
    }
    try Task.checkCancellation()
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
  ) async throws -> AsyncThrowingStream<StorageCleanupProgress, Error> {
    guard device.state == .shutdown else {
      throw SimulatorWorkspaceError.invalidOperation(
        "请先关闭模拟器，再重新扫描存储并确认清理范围"
      )
    }
    guard let record = records[planID], record.plan.deviceID == device.id,
      !isExpired(record)
    else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }
    guard !categoryIDs.isEmpty else {
      return AsyncThrowingStream { $0.finish() }
    }

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
    let expectedRoot = record.canonicalRoot
    let checkpoint = deletionCheckpoint
    return AsyncThrowingStream { continuation in
      let coordinator = Task { [weak self] in
        let deletionTask = Task.detached(priority: .userInitiated) {
          try await Self.deleteContents(
            targets: selectedTargets,
            expectedRoot: expectedRoot,
            currentRoot: currentRoot,
            checkpoint: checkpoint,
            progress: { continuation.yield($0) }
          )
        }
        do {
          _ = try await withTaskCancellationHandler {
            try await deletionTask.value
          } onCancel: {
            deletionTask.cancel()
          }
          await self?.discardPlan(planID, deviceID: device.id)
          continuation.finish()
        } catch {
          await self?.discardPlan(planID, deviceID: device.id)
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in coordinator.cancel() }
    }
  }

  private func discardPlan(_ planID: UUID, deviceID: SimulatorID) {
    records.removeValue(forKey: planID)
    if latestPlanIDs[deviceID] == planID {
      latestPlanIDs.removeValue(forKey: deviceID)
    }
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
    rootURL: URL,
    checkpoint: @escaping @Sendable () async throws -> Void
  ) async throws -> StoragePlanRecord {
    try await checkpoint()
    let fileManager = FileManager()
    let canonicalRoot = try canonicalDataRoot(rootURL)
    let structured = try structuredTargets(
      canonicalRoot: canonicalRoot,
      fileManager: fileManager
    )

    var targets: [StorageTarget] = []
    var protectedItems = structured.protectedItems
    for candidate in structured.candidates {
      try await checkpoint()
      try Task.checkCancellation()
      switch try candidatePathStatus(candidate.url, inside: canonicalRoot) {
      case .missing:
        continue
      case .symbolicLink:
        protectedItems.append(protectedItem(for: candidate.url, inside: canonicalRoot))
        continue
      case .concrete:
        break
      }
      try validatePath(candidate.url, inside: canonicalRoot, allowRoot: false)
      guard let identity = fileIdentity(at: candidate.url) else { continue }
      let manifestBeforeSizeScan = try recursiveManifest(
        of: candidate.url,
        inside: canonicalRoot
      )
      let bytes = try allocatedSize(of: candidate.url, inside: canonicalRoot)
      let manifestAfterSizeScan = try recursiveManifest(
        of: candidate.url,
        inside: canonicalRoot
      )
      guard fileIdentity(at: candidate.url) == identity,
        manifestBeforeSizeScan == manifestAfterSizeScan
      else {
        throw SimulatorWorkspaceError.staleStoragePlan
      }
      targets.append(
        StorageTarget(
          categoryID: candidate.categoryID,
          url: candidate.url,
          identity: identity,
          scannedBytes: bytes,
          manifest: manifestAfterSizeScan
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
    if try candidatePathStatus(appBundlesURL, inside: canonicalRoot) == .symbolicLink {
      protectedItems.append(protectedItem(for: appBundlesURL, inside: canonicalRoot))
    }
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
      StorageCategory.unknown.summary(
        bytes: unknownBytes,
        targets: targets,
        protectedTargetCount: Set(protectedItems).count
      ),
    ]

    let cleanableItems = targets.map { target in
      StorageItemSummary(
        categoryID: target.categoryID,
        relativePath: relativePath(target.url, inside: canonicalRoot),
        bytes: target.scannedBytes
      )
    }
    let plan = StoragePlan(
      deviceID: device.id,
      totalBytes: totalBytes,
      cleanableBytes: safeBytes,
      categories: summaries,
      items: Array(Set(cleanableItems + protectedItems)).sorted {
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
  ) throws -> StructuredTargets {
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
    var protectedItems: [StorageItemSummary] = []

    let applicationRoot =
      canonicalRoot
      .appendingPathComponent("Containers/Data/Application", isDirectory: true)
    switch try candidatePathStatus(applicationRoot, inside: canonicalRoot) {
    case .missing:
      break
    case .symbolicLink:
      protectedItems.append(protectedItem(for: applicationRoot, inside: canonicalRoot))
    case .concrete:
      try validatePath(applicationRoot, inside: canonicalRoot, allowRoot: false)
      let containers = try fileManager.contentsOfDirectory(
        at: applicationRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      for container in containers {
        try Task.checkCancellation()
        let values = try container.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let identifier = container.lastPathComponent
        guard UUID(uuidString: identifier) != nil else { continue }
        let relativeContainerPath = "Containers/Data/Application/\(identifier)"
        let lexicalContainer = canonicalRoot.appendingPathComponent(
          relativeContainerPath,
          isDirectory: true
        )
        if values.isSymbolicLink == true {
          protectedItems.append(protectedItem(for: lexicalContainer, inside: canonicalRoot))
          continue
        }
        guard values.isDirectory == true else { continue }
        candidates.append(
          .init(
            categoryID: StorageCategory.cache.id,
            relativePath: "\(relativeContainerPath)/Library/Caches",
            root: canonicalRoot
          )
        )
        candidates.append(
          .init(
            categoryID: StorageCategory.logs.id,
            relativePath: "\(relativeContainerPath)/Library/Logs",
            root: canonicalRoot
          )
        )
        candidates.append(
          .init(
            categoryID: StorageCategory.temporary.id,
            relativePath: "\(relativeContainerPath)/tmp",
            root: canonicalRoot
          )
        )
      }
    }

    return StructuredTargets(candidates: candidates, protectedItems: protectedItems)
  }

  private static func deleteContents(
    targets: [StorageTarget],
    expectedRoot: URL,
    currentRoot: URL,
    checkpoint: @escaping @Sendable () async throws -> Void,
    progress: @escaping @Sendable (StorageCleanupProgress) -> Void
  ) async throws -> Int64 {
    try await checkpoint()
    let fileManager = FileManager()
    let currentCanonicalRoot = try canonicalDataRoot(currentRoot)
    guard currentCanonicalRoot.path == expectedRoot.path else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }

    try await checkpoint()
    for target in targets {
      try validateTargetIsUnchanged(target, inside: expectedRoot)
    }

    let totalChildCount = targets.reduce(into: 0) { count, target in
      count +=
        target.manifest.filter {
          !$0.relativePath.contains("/") && $0.kind != .symbolicLink
        }.count
    }
    var reclaimed: Int64 = 0
    var completedChildCount = 0
    for target in targets {
      try await checkpoint()
      try Task.checkCancellation()
      try validateTargetIsUnchanged(target, inside: expectedRoot)
      let children = try fileManager.contentsOfDirectory(
        at: target.url,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      )
      let expectedEntries = Dictionary(
        uniqueKeysWithValues: target.manifest
          .filter { !$0.relativePath.contains("/") }
          .map { ($0.relativePath, $0) }
      )
      for child in children.sorted(by: { $0.path < $1.path }) {
        try await checkpoint()
        try Task.checkCancellation()
        guard
          let expected = expectedEntries[child.lastPathComponent],
          try manifestEntry(at: child, relativePath: child.lastPathComponent) == expected
        else {
          throw SimulatorWorkspaceError.staleStoragePlan
        }
        guard expected.kind != .symbolicLink else { continue }
        try validatePath(child, inside: expectedRoot, allowRoot: false)
        let targetRelativePath = relativePath(target.url, inside: expectedRoot)
        let childRelativePath = relativePath(child, inside: expectedRoot)
        let pendingAcknowledgment = StorageProgressAcknowledgment()
        progress(
          StorageCleanupProgress(
            stage: .pending,
            relativePath: childRelativePath,
            targetRelativePath: targetRelativePath,
            targetReclaimedBytes: 0,
            reclaimedBytes: reclaimed,
            completedTargetCount: completedChildCount,
            totalTargetCount: totalChildCount,
            acknowledgment: pendingAcknowledgment
          )
        )
        try pendingAcknowledgment.wait()
        try await checkpoint()
        try Task.checkCancellation()
        guard
          try manifestEntry(at: child, relativePath: child.lastPathComponent) == expected
        else {
          throw SimulatorWorkspaceError.staleStoragePlan
        }
        try validatePath(child, inside: expectedRoot, allowRoot: false)
        let before = try allocatedSize(of: child, inside: expectedRoot)
        try fileManager.removeItem(at: child)
        reclaimed += before
        completedChildCount += 1
        let completedAcknowledgment = StorageProgressAcknowledgment()
        progress(
          StorageCleanupProgress(
            stage: .completed,
            relativePath: childRelativePath,
            targetRelativePath: targetRelativePath,
            targetReclaimedBytes: before,
            reclaimedBytes: reclaimed,
            completedTargetCount: completedChildCount,
            totalTargetCount: totalChildCount,
            acknowledgment: completedAcknowledgment
          )
        )
        try completedAcknowledgment.wait()
      }
    }
    return reclaimed
  }

  private static func validateTargetIsUnchanged(
    _ target: StorageTarget,
    inside root: URL
  ) throws {
    try validatePath(target.url, inside: root, allowRoot: false)
    guard
      fileIdentity(at: target.url) == target.identity,
      try allocatedSize(of: target.url, inside: root) == target.scannedBytes,
      try recursiveManifest(of: target.url, inside: root) == target.manifest
    else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }
  }

  private static func recursiveManifest(
    of directory: URL,
    inside root: URL
  ) throws -> [StorageManifestEntry] {
    try validatePath(directory, inside: root, allowRoot: false)
    var entries: [StorageManifestEntry] = []
    try appendManifestEntries(
      in: directory,
      relativePrefix: "",
      root: root,
      entries: &entries
    )
    return entries.sorted {
      $0.relativePath < $1.relativePath
    }
  }

  private static func appendManifestEntries(
    in directory: URL,
    relativePrefix: String,
    root: URL,
    entries: inout [StorageManifestEntry]
  ) throws {
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )
    for child in children {
      try Task.checkCancellation()
      guard isDescendant(child, of: directory) else {
        throw SimulatorWorkspaceError.unsafePath(child.path)
      }
      let relativePath =
        relativePrefix.isEmpty
        ? child.lastPathComponent
        : "\(relativePrefix)/\(child.lastPathComponent)"
      let entry = try manifestEntry(at: child, relativePath: relativePath)
      entries.append(entry)
      if entry.kind == .directory {
        try validatePath(child, inside: root, allowRoot: false)
        try appendManifestEntries(
          in: child,
          relativePrefix: relativePath,
          root: root,
          entries: &entries
        )
      }
    }
  }

  private static func manifestEntry(
    at url: URL,
    relativePath: String
  ) throws -> StorageManifestEntry {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw SimulatorWorkspaceError.staleStoragePlan
    }
    let kind: StorageManifestEntry.Kind
    switch info.st_mode & S_IFMT {
    case S_IFREG: kind = .regularFile
    case S_IFDIR: kind = .directory
    case S_IFLNK: kind = .symbolicLink
    default: kind = .other
    }
    return StorageManifestEntry(
      relativePath: relativePath,
      kind: kind,
      identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
      size: Int64(info.st_size),
      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
      statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
    )
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

  private static func candidatePathStatus(
    _ candidate: URL,
    inside root: URL
  ) throws -> CandidatePathStatus {
    let normalized = candidate.standardizedFileURL
    let normalizedRoot = root.standardizedFileURL
    guard isDescendant(normalized, of: normalizedRoot) else {
      throw SimulatorWorkspaceError.unsafePath(candidate.path)
    }

    let relative = normalized.path.dropFirst(normalizedRoot.path.count)
      .split(separator: "/")
    var current = normalizedRoot
    for component in relative {
      current.appendPathComponent(String(component))
      var info = stat()
      guard lstat(current.path, &info) == 0 else { return .missing }
      if (info.st_mode & S_IFMT) == S_IFLNK { return .symbolicLink }
    }
    return .concrete
  }

  private static func protectedItem(
    for candidate: URL,
    inside root: URL
  ) -> StorageItemSummary {
    StorageItemSummary(
      categoryID: StorageCategory.unknown.id,
      relativePath: relativePath(candidate, inside: root),
      bytes: 0
    )
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
    switch try candidatePathStatus(url, inside: root) {
    case .missing, .symbolicLink:
      return 0
    case .concrete:
      return try allocatedSize(of: url, inside: root)
    }
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
  let manifest: [StorageManifestEntry]
}

private struct FileIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

private struct StorageManifestEntry: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
  }

  let relativePath: String
  let kind: Kind
  let identity: FileIdentity
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let statusChangeSeconds: Int64
  let statusChangeNanoseconds: Int64
}

private struct StorageTargetCandidate: Sendable {
  let categoryID: String
  let url: URL

  init(categoryID: String, relativePath: String, root: URL) {
    self.categoryID = categoryID
    self.url = root.appendingPathComponent(relativePath, isDirectory: true)
  }
}

private struct StructuredTargets: Sendable {
  let candidates: [StorageTargetCandidate]
  let protectedItems: [StorageItemSummary]
}

private final class StorageProgressAcknowledgment: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var wasAcknowledged = false

  func acknowledge() {
    lock.lock()
    defer { lock.unlock() }
    guard !wasAcknowledged else { return }
    wasAcknowledged = true
    semaphore.signal()
  }

  func wait() throws {
    while semaphore.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
      try Task.checkCancellation()
    }
  }
}

private enum CandidatePathStatus: Equatable, Sendable {
  case missing
  case symbolicLink
  case concrete
}

private enum StorageCategory: String, CaseIterable, Sendable {
  case cache
  case logs
  case temporary
  case appData
  case appBundles
  case unknown

  var id: String { rawValue }

  func summary(
    bytes: Int64,
    targets: [StorageTarget],
    protectedTargetCount: Int = 0
  ) -> StorageCategorySummary {
    switch self {
    case .cache:
      return .init(
        id: id, name: "缓存", summary: "系统及应用的可重建缓存",
        consequence: "首次重新打开相关功能时可能稍慢",
        recovery: "系统和应用会按需自动重建", risk: .low,
        isDefaultSelected: true, canClean: true, bytes: bytes,
        targetCount: targets.filter { $0.categoryID == id }.count
      )
    case .logs:
      return .init(
        id: id, name: "日志", summary: "系统及应用运行日志",
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
        id: id, name: "应用数据", summary: "文档、数据库及偏好设置",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes, targetCount: 0
      )
    case .appBundles:
      return .init(
        id: id, name: "应用安装包", summary: "模拟器中安装的应用本体",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes, targetCount: 0
      )
    case .unknown:
      return .init(
        id: id, name: "未知或受保护路径", summary: "未列入安全允许列表的内容",
        consequence: "不会处理", recovery: "保留原样", risk: .protected,
        isDefaultSelected: false, canClean: false, bytes: bytes,
        targetCount: protectedTargetCount
      )
    }
  }
}
