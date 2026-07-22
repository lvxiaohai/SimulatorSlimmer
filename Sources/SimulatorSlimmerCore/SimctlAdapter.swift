import Foundation

protocol SimulatorControlling: Sendable {
  func inventory() async throws -> SimulatorInventory
  func validatedDevice(_ id: SimulatorID) async throws -> SimulatorDevice
  func disabledLabels(for id: SimulatorID) async throws -> Set<String>
  func presentServiceLabels(
    _ labels: Set<String>,
    for id: SimulatorID
  ) async throws -> Set<String>
  func setService(
    _ label: String,
    transition: ServiceTransition,
    deviceID: SimulatorID
  ) async throws
  func boot(_ id: SimulatorID) async throws
  func shutdown(_ id: SimulatorID) async throws
  func erase(_ id: SimulatorID) async throws
  func delete(_ id: SimulatorID) async throws
  func clone(_ id: SimulatorID, name: String) async throws -> SimulatorID
  func openSimulator(_ id: SimulatorID) async throws
}

struct SimctlAdapter: SimulatorControlling, Sendable {
  private let runner: any CommandRunning
  private let decoder: JSONDecoder
  private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  private let openURL = URL(fileURLWithPath: "/usr/bin/open")

  init(runner: any CommandRunning = FoundationCommandRunner()) {
    self.runner = runner
    self.decoder = JSONDecoder()
  }

  func inventory() async throws -> SimulatorInventory {
    async let runtimeOutput = runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "list", "runtimes", "-j"]
      )
    )
    async let deviceOutput = runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "list", "devices", "-j"]
      )
    )

    let (runtimeResult, deviceResult) = try await (runtimeOutput, deviceOutput)
    let runtimeDocument: RuntimeDocument
    let deviceDocument: DeviceDocument

    do {
      runtimeDocument = try decoder.decode(
        RuntimeDocument.self,
        from: Data(runtimeResult.standardOutput.utf8)
      )
      deviceDocument = try decoder.decode(
        DeviceDocument.self,
        from: Data(deviceResult.standardOutput.utf8)
      )
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(error.localizedDescription)
    }

    let iOSRuntimeRecords = runtimeDocument.runtimes.filter {
      $0.identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")
    }
    let runtimes = iOSRuntimeRecords.map {
      SimulatorRuntime(
        id: $0.identifier,
        name: $0.name,
        version: $0.version,
        build: $0.buildversion,
        isAvailable: $0.isAvailable
      )
    }
    let runtimeNames = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, $0.name) })
    let runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, $0) })

    let devices: [SimulatorDevice] = deviceDocument.devices.flatMap {
      entry -> [SimulatorDevice] in
      let runtimeIdentifier = entry.key
      guard runtimesByID[runtimeIdentifier] != nil else { return [] }
      return entry.value.map { device in
        let isAvailable =
          device.isAvailable && (runtimesByID[runtimeIdentifier]?.isAvailable ?? false)
        return SimulatorDevice(
          id: SimulatorID(rawValue: device.udid),
          name: device.name,
          runtimeIdentifier: runtimeIdentifier,
          runtimeName: runtimeNames[runtimeIdentifier]
            ?? Self.readableRuntimeName(runtimeIdentifier),
          deviceTypeIdentifier: device.deviceTypeIdentifier,
          state: Self.mapState(device.state, isAvailable: isAvailable),
          isAvailable: isAvailable,
          availabilityError: device.availabilityError,
          dataPath: device.dataPath.map(URL.init(fileURLWithPath:)),
          logPath: device.logPath.map(URL.init(fileURLWithPath:)),
          dataSize: device.dataPathSize,
          logSize: device.logPathSize,
          lastBootedAt: device.lastBootedAt.flatMap(Self.parseDate)
        )
      }
    }
    .sorted {
      if $0.runtimeName != $1.runtimeName { return $0.runtimeName > $1.runtimeName }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    return SimulatorInventory(runtimes: runtimes, devices: devices)
  }

  func validatedDevice(_ id: SimulatorID) async throws -> SimulatorDevice {
    guard Self.isValidUDID(id.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    guard let device = try await inventory().devices.first(where: { $0.id == id }) else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    guard device.isAvailable else {
      throw SimulatorWorkspaceError.deviceUnavailable(
        device.availabilityError ?? "模拟器 \(device.name) 当前不可用"
      )
    }
    return device
  }

  func disabledLabels(for id: SimulatorID) async throws -> Set<String> {
    guard Self.isValidUDID(id.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }

    let output = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: [
          "simctl", "spawn", id.rawValue,
          "launchctl", "print-disabled", "system",
        ]
      )
    )
    return Self.parseDisabledLabels(output.standardOutput)
  }

  func presentServiceLabels(
    _ labels: Set<String>,
    for id: SimulatorID
  ) async throws -> Set<String> {
    guard Self.isValidUDID(id.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(id)
    }
    for label in labels where !Self.isValidLaunchdLabel(label) {
      throw SimulatorWorkspaceError.invalidOperation("无效的 launchd 服务标签")
    }

    let orderedLabels = labels.sorted()
    var present = Set<String>()
    let batchSize = 8
    for offset in stride(from: 0, to: orderedLabels.count, by: batchSize) {
      try Task.checkCancellation()
      let upperBound = min(offset + batchSize, orderedLabels.count)
      let batch = orderedLabels[offset..<upperBound]
      let results = try await withThrowingTaskGroup(of: ServicePresenceResult.self) { group in
        for label in batch {
          group.addTask {
            do {
              _ = try await runner.run(
                Command(
                  executable: xcrunURL,
                  arguments: [
                    "simctl", "spawn", id.rawValue,
                    "launchctl", "print", "system/\(label)",
                  ],
                  timeout: .seconds(10),
                  outputLimit: 2 * 1_024 * 1_024
                )
              )
              return ServicePresenceResult(label: label, isPresent: true)
            } catch SimulatorWorkspaceError.commandFailed(_, let code, let message)
              where code == 113
              || message.localizedCaseInsensitiveContains("could not find service")
            {
              return ServicePresenceResult(label: label, isPresent: false)
            }
          }
        }

        var batchResults: [ServicePresenceResult] = []
        for try await result in group {
          batchResults.append(result)
        }
        return batchResults
      }
      present.formUnion(results.filter(\.isPresent).map(\.label))
    }
    return present
  }

  func setService(
    _ label: String,
    transition: ServiceTransition,
    deviceID: SimulatorID
  ) async throws {
    guard Self.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    guard Self.isValidLaunchdLabel(label) else {
      throw SimulatorWorkspaceError.invalidOperation("无效的 launchd 服务标签")
    }

    let action = transition == .disable ? "disable" : "enable"
    _ = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: [
          "simctl", "spawn", deviceID.rawValue,
          "launchctl", action, "system/\(label)",
        ]
      )
    )
  }

  func boot(_ id: SimulatorID) async throws {
    let device = try await validatedDevice(id)
    if device.state != .booted {
      _ = try await runner.run(
        Command(
          executable: xcrunURL,
          arguments: ["simctl", "boot", id.rawValue],
          timeout: .seconds(60)
        )
      )
    }
    _ = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "bootstatus", id.rawValue, "-b"],
        timeout: .seconds(120)
      )
    )
  }

  func shutdown(_ id: SimulatorID) async throws {
    let device = try await validatedDevice(id)
    guard device.state != .shutdown else { return }
    _ = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "shutdown", id.rawValue],
        timeout: .seconds(60)
      )
    )
  }

  func erase(_ id: SimulatorID) async throws {
    _ = try await validatedDevice(id)
    _ = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "erase", id.rawValue],
        timeout: .seconds(180)
      )
    )
  }

  func delete(_ id: SimulatorID) async throws {
    _ = try await validatedDevice(id)
    _ = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "delete", id.rawValue],
        timeout: .seconds(180)
      )
    )
  }

  func clone(_ id: SimulatorID, name: String) async throws -> SimulatorID {
    _ = try await validatedDevice(id)
    let trimmedName = try Self.validatedCloneName(name)

    let output = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "clone", id.rawValue, trimmedName],
        timeout: .seconds(180)
      )
    )
    let candidate = output.standardOutput
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .first(where: Self.isValidUDID)
    guard let candidate else {
      throw SimulatorWorkspaceError.malformedOutput("克隆成功但未返回新设备 UDID")
    }
    return SimulatorID(rawValue: candidate.uppercased())
  }

  func openSimulator(_ id: SimulatorID) async throws {
    _ = try await validatedDevice(id)
    try await boot(id)
    _ = try await runner.run(
      Command(
        executable: openURL,
        arguments: [
          "-a", "Simulator", "--args", "-CurrentDeviceUDID", id.rawValue,
        ],
        timeout: .seconds(20)
      )
    )
  }

  static func parseDisabledLabels(_ output: String) -> Set<String> {
    var result = Set<String>()
    for line in output.split(whereSeparator: \.isNewline) {
      guard let quoteStart = line.firstIndex(of: "\"") else { continue }
      let labelStart = line.index(after: quoteStart)
      guard let quoteEnd = line[labelStart...].firstIndex(of: "\"") else { continue }
      let label = String(line[labelStart..<quoteEnd])
      let value = line[line.index(after: quoteEnd)...].lowercased()
      if value.contains("=> disabled") || value.contains("=> true") {
        result.insert(label)
      }
    }
    return result
  }

  static func isValidUDID(_ rawValue: String) -> Bool {
    guard rawValue.count == 36, let uuid = UUID(uuidString: rawValue) else { return false }
    return uuid.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame
  }

  static func isValidLaunchdLabel(_ label: String) -> Bool {
    guard !label.isEmpty, label.count <= 255 else { return false }
    return label.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
    }
  }

  static func validatedCloneName(_ name: String) throws -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName.count <= 128,
      !trimmedName.contains(where: { $0.isNewline })
    else {
      throw SimulatorWorkspaceError.invalidOperation(
        "克隆名称不能为空、不能超过 128 个字符，且不能包含换行符"
      )
    }
    return trimmedName
  }

  private static func mapState(_ state: String, isAvailable: Bool) -> SimulatorState {
    guard isAvailable else { return .unavailable }
    switch state.lowercased() {
    case "booted": return .booted
    case "shutdown": return .shutdown
    case "creating": return .creating
    case "shutting down": return .shuttingDown
    default: return .unknown
    }
  }

  private static func readableRuntimeName(_ identifier: String) -> String {
    identifier
      .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
      .replacingOccurrences(of: "-", with: " ")
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

private struct ServicePresenceResult: Sendable {
  let label: String
  let isPresent: Bool
}

private struct RuntimeDocument: Decodable {
  let runtimes: [RuntimeRecord]
}

private struct RuntimeRecord: Decodable {
  let identifier: String
  let name: String
  let version: String
  let buildversion: String?
  let isAvailable: Bool
  let platformIdentifier: String?
}

private struct DeviceDocument: Decodable {
  let devices: [String: [DeviceRecord]]
}

private struct DeviceRecord: Decodable {
  let udid: String
  let name: String
  let state: String
  let isAvailable: Bool
  let availabilityError: String?
  let deviceTypeIdentifier: String
  let dataPath: String?
  let dataPathSize: Int64?
  let logPath: String?
  let logPathSize: Int64?
  let lastBootedAt: String?
}
