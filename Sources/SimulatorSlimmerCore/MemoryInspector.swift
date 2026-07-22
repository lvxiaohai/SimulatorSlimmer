import Darwin
import Foundation

protocol MemoryInspecting: Sendable {
  func snapshot(for deviceID: SimulatorID) async throws -> MemorySnapshot
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
    let pids = allProcessIDs()
    var parents: [pid_t: pid_t] = [:]
    parents.reserveCapacity(pids.count)

    for pid in pids {
      guard let info = bsdInfo(for: pid) else { continue }
      parents[pid] = pid_t(info.pbi_ppid)
    }

    let processTree = descendantPIDs(parents: parents, rootPID: rootPID)
    guard processTree.contains(rootPID) else {
      throw SimulatorWorkspaceError.invalidOperation("模拟器进程在读取内存期间已退出")
    }

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
