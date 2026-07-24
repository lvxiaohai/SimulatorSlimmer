import Darwin
import Foundation

protocol MemoryInspecting: Sendable {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot
  func applicationMemorySnapshots(
    for deviceID: SimulatorID,
    applications: [SimulatorApplication]
  ) async throws -> [String: ApplicationMemorySnapshot]
}

extension MemoryInspecting {
  func applicationMemorySnapshots(
    for deviceID: SimulatorID,
    applications: [SimulatorApplication]
  ) async throws -> [String: ApplicationMemorySnapshot] {
    [:]
  }
}

struct ApplicationProcessMemorySample: Hashable, Sendable {
  let executableURL: URL
  let bytes: UInt64
}

struct LibprocMemoryInspector: MemoryInspecting, Sendable {
  private let runner: any CommandRunning
  private let pgrepURL = URL(fileURLWithPath: "/usr/bin/pgrep")

  init(runner: any CommandRunning = FoundationCommandRunner()) {
    self.runner = runner
  }

  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot {
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }

    let rootPID = try await locateLaunchdSimulator(for: deviceID)
    return try await Task.detached(priority: .userInitiated) {
      try Self.readProcessTree(rootPID: rootPID)
    }.value
  }

  func applicationMemorySnapshots(
    for deviceID: SimulatorID,
    applications: [SimulatorApplication]
  ) async throws -> [String: ApplicationMemorySnapshot] {
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    guard applications.contains(where: { $0.bundleURL != nil }) else {
      return [:]
    }

    let rootPID = try await locateLaunchdSimulator(for: deviceID)
    return try await Task.detached(priority: .userInitiated) {
      let samples = try Self.readApplicationProcessMemory(
        rootPID: rootPID,
        applications: applications
      )
      return Self.attributeApplicationMemory(
        samples: samples,
        applications: applications
      )
    }.value
  }

  private func locateLaunchdSimulator(for deviceID: SimulatorID) async throws -> pid_t {
    let bootstrapSuffix = "\(deviceID.rawValue)/data/var/run/launchd_bootstrap.plist"
    let output = try await runner.run(
      Command(
        executable: pgrepURL,
        arguments: ["-f", bootstrapSuffix],
        timeout: .seconds(5),
        outputLimit: 64 * 1_024
      )
    )
    let candidates = output.standardOutput
      .split(whereSeparator: \.isWhitespace)
      .compactMap { pid_t($0) }
      .filter { $0 > 0 }

    guard
      let rootPID = candidates.first(where: { Self.processName($0) == "launchd_sim" })
        ?? candidates.first
    else {
      throw SimulatorWorkspaceError.invalidOperation(
        "未找到该模拟器的 launchd_sim 进程；请确认设备已经启动"
      )
    }
    return rootPID
  }

  private static func readProcessTree(rootPID: pid_t) throws -> MemorySnapshot {
    let processTree = try processTreePIDs(rootPID: rootPID)

    var total: UInt64 = 0
    var measuredCount = 0
    for pid in processTree {
      guard let bytes = physicalFootprint(for: pid) else { continue }
      let (newTotal, overflowed) = total.addingReportingOverflow(bytes)
      total = overflowed ? UInt64.max : newTotal
      measuredCount += 1
    }

    guard measuredCount > 0 else {
      throw SimulatorWorkspaceError.invalidOperation("系统拒绝读取模拟器进程的物理内存")
    }

    return MemorySnapshot(
      bytes: total > UInt64(Int64.max) ? Int64.max : Int64(total),
      processCount: measuredCount,
      method: "physical-footprint (libproc)"
    )
  }

  private static func processTreePIDs(rootPID: pid_t) throws -> Set<pid_t> {
    let pids = allProcessIDs()
    var parents: [pid_t: pid_t] = [:]
    parents.reserveCapacity(pids.count)

    for pid in pids {
      guard let info = bsdInfo(for: pid) else { continue }
      parents[pid] = pid_t(info.pbi_ppid)
    }

    guard parents[rootPID] != nil else {
      throw SimulatorWorkspaceError.invalidOperation("模拟器进程在读取内存期间已退出")
    }
    return descendantPIDs(parents: parents, rootPID: rootPID)
  }

  private static func readApplicationProcessMemory(
    rootPID: pid_t,
    applications: [SimulatorApplication]
  ) throws -> [ApplicationProcessMemorySample] {
    let processTree = try processTreePIDs(rootPID: rootPID)
    let bundleRoots = applicationBundleRoots(applications)
    guard !bundleRoots.isEmpty else { return [] }

    var readablePathCount = 0
    var matchedPathCount = 0
    var samples: [ApplicationProcessMemorySample] = []
    for pid in processTree {
      guard let executableURL = executableURL(for: pid) else { continue }
      readablePathCount += 1
      guard matchingBundleIdentifier(for: executableURL, roots: bundleRoots) != nil else {
        continue
      }
      matchedPathCount += 1
      guard let bytes = physicalFootprint(for: pid) else { continue }
      samples.append(
        ApplicationProcessMemorySample(
          executableURL: executableURL,
          bytes: bytes
        )
      )
    }

    guard readablePathCount > 0 else {
      throw SimulatorWorkspaceError.invalidOperation("系统拒绝读取模拟器进程的可执行路径")
    }
    guard matchedPathCount == 0 || !samples.isEmpty else {
      throw SimulatorWorkspaceError.invalidOperation("系统拒绝读取模拟器进程的物理内存")
    }
    return samples
  }

  static func attributeApplicationMemory(
    samples: [ApplicationProcessMemorySample],
    applications: [SimulatorApplication],
    collectedAt: Date = Date()
  ) -> [String: ApplicationMemorySnapshot] {
    let roots = applicationBundleRoots(applications)
    var totals: [String: (bytes: UInt64, processCount: Int)] = [:]

    for sample in samples {
      guard
        let bundleIdentifier = matchingBundleIdentifier(
          for: sample.executableURL,
          roots: roots
        )
      else {
        continue
      }
      var total = totals[bundleIdentifier] ?? (bytes: 0, processCount: 0)
      let (newBytes, overflowed) = total.bytes.addingReportingOverflow(sample.bytes)
      total.bytes = overflowed ? UInt64.max : newBytes
      if total.processCount < Int.max {
        total.processCount += 1
      }
      totals[bundleIdentifier] = total
    }

    return totals.mapValues { total in
      ApplicationMemorySnapshot(
        bytes: total.bytes > UInt64(Int64.max) ? Int64.max : Int64(total.bytes),
        processCount: total.processCount,
        collectedAt: collectedAt
      )
    }
  }

  static func descendantPIDs(
    parents: [pid_t: pid_t],
    rootPID: pid_t
  ) -> Set<pid_t> {
    var children: [pid_t: [pid_t]] = [:]
    for (pid, parent) in parents {
      children[parent, default: []].append(pid)
    }

    var result: Set<pid_t> = [rootPID]
    var stack = [rootPID]
    while let parent = stack.popLast() {
      for child in children[parent, default: []] where result.insert(child).inserted {
        stack.append(child)
      }
    }
    return result
  }

  private static func allProcessIDs() -> [pid_t] {
    let requestedCount = max(proc_listallpids(nil, 0), 256)
    var pids = [pid_t](repeating: 0, count: Int(requestedCount) + 128)
    let actualCount = pids.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard actualCount > 0 else { return [] }
    return Array(pids.prefix(Int(actualCount))).filter { $0 > 0 }
  }

  private static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        pointer,
        Int32(MemoryLayout<proc_bsdinfo>.size)
      )
    }
    return size == MemoryLayout<proc_bsdinfo>.size ? info : nil
  }

  private static func physicalFootprint(for pid: pid_t) -> UInt64? {
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
      }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
  }

  private static func executableURL(for pid: pid_t) -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    guard !bytes.isEmpty else { return nil }
    return URL(
      fileURLWithPath: String(decoding: bytes, as: UTF8.self),
      isDirectory: false
    )
    .resolvingSymlinksInPath()
    .standardizedFileURL
  }

  private struct ApplicationBundleRoot {
    let bundleIdentifier: String
    let pathComponents: [String]
  }

  private static func applicationBundleRoots(
    _ applications: [SimulatorApplication]
  ) -> [ApplicationBundleRoot] {
    applications.compactMap { application in
      guard let bundleURL = application.bundleURL, bundleURL.isFileURL else {
        return nil
      }
      let resolvedURL =
        bundleURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
      return ApplicationBundleRoot(
        bundleIdentifier: application.bundleIdentifier,
        pathComponents: resolvedURL.pathComponents
      )
    }
    .sorted { lhs, rhs in
      if lhs.pathComponents.count != rhs.pathComponents.count {
        return lhs.pathComponents.count > rhs.pathComponents.count
      }
      return lhs.bundleIdentifier < rhs.bundleIdentifier
    }
  }

  private static func matchingBundleIdentifier(
    for executableURL: URL,
    roots: [ApplicationBundleRoot]
  ) -> String? {
    guard executableURL.isFileURL else { return nil }
    let executableComponents =
      executableURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .pathComponents

    return roots.first { root in
      executableComponents.count > root.pathComponents.count
        && executableComponents.starts(with: root.pathComponents)
    }?.bundleIdentifier
  }

  private static func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let count = proc_name(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    return String(
      decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }
}
