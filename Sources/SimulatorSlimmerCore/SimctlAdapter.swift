import Foundation

protocol SimulatorControlling: Sendable {
  func inventory() async throws -> SimulatorInventory
  func availableDeviceTypes() async throws -> [SimulatorDeviceType]
  func create(_ request: SimulatorCreationRequest) async throws -> SimulatorID
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

extension SimulatorControlling {
  func availableDeviceTypes() async throws -> [SimulatorDeviceType] {
    throw SimulatorWorkspaceError.invalidOperation("当前模拟器控制器不支持读取设备类型")
  }

  func create(_ request: SimulatorCreationRequest) async throws -> SimulatorID {
    throw SimulatorWorkspaceError.invalidOperation("当前模拟器控制器不支持创建模拟器")
  }
}

struct SimctlAdapter: SimulatorControlling, Sendable {
  private let runner: any CommandRunning
  private let decoder: JSONDecoder
  private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  private let openURL = URL(fileURLWithPath: "/usr/bin/open")
  private static let launchdDomain = "user/foreground"

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
    let runtimes =
      iOSRuntimeRecords
      .map {
        SimulatorRuntime(
          id: $0.identifier,
          name: $0.name,
          version: $0.version,
          build: $0.buildversion,
          isAvailable: $0.isAvailable
        )
      }
      .sorted(by: Self.runtimeComesBefore)
    let runtimeNames = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, $0.name) })
    let runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, $0) })
    let runtimeRanks = Dictionary(
      uniqueKeysWithValues: runtimes.enumerated().map { ($0.element.id, $0.offset) }
    )

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
      let leftRank = runtimeRanks[$0.runtimeIdentifier] ?? Int.max
      let rightRank = runtimeRanks[$1.runtimeIdentifier] ?? Int.max
      if leftRank != rightRank { return leftRank < rightRank }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    return SimulatorInventory(runtimes: runtimes, devices: devices)
  }

  func availableDeviceTypes() async throws -> [SimulatorDeviceType] {
    let output = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: ["simctl", "list", "devicetypes", "-j"]
      )
    )
    let document: DeviceTypeDocument
    do {
      document = try decoder.decode(
        DeviceTypeDocument.self,
        from: Data(output.standardOutput.utf8)
      )
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(error.localizedDescription)
    }

    return document.devicetypes
      .filter { $0.productFamily == "iPhone" || $0.productFamily == "iPad" }
      .map {
        SimulatorDeviceType(
          id: $0.identifier,
          name: $0.name,
          productFamily: $0.productFamily,
          modelIdentifier: $0.modelIdentifier,
          minimumRuntimeVersion: $0.minRuntimeVersionString,
          maximumRuntimeVersion: $0.maxRuntimeVersionString
        )
      }
  }

  func create(_ request: SimulatorCreationRequest) async throws -> SimulatorID {
    let name = try Self.validatedDeviceName(request.name)
    guard request.deviceTypeID.hasPrefix("com.apple.CoreSimulator.SimDeviceType."),
      request.runtimeID.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")
    else {
      throw SimulatorWorkspaceError.invalidOperation("设备类型或系统运行时无效")
    }

    let output = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: [
          "simctl", "create", name, request.deviceTypeID, request.runtimeID,
        ],
        timeout: .seconds(180)
      )
    )
    let candidate = output.standardOutput
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .first(where: Self.isValidUDID)
    guard let candidate else {
      throw SimulatorWorkspaceError.malformedOutput("创建成功但未返回新设备 UDID")
    }
    return SimulatorID(rawValue: candidate.uppercased())
  }

  private static func runtimeComesBefore(
    _ lhs: SimulatorRuntime,
    _ rhs: SimulatorRuntime
  ) -> Bool {
    let versionOrder = lhs.version.compare(rhs.version, options: .numeric)
    if versionOrder != .orderedSame {
      return versionOrder == .orderedDescending
    }

    let buildOrder = (lhs.build ?? "").compare(rhs.build ?? "", options: .numeric)
    if buildOrder != .orderedSame {
      return buildOrder == .orderedDescending
    }
    return lhs.id < rhs.id
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
          "launchctl", "print-disabled", Self.launchdDomain,
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

    let output = try await runner.run(
      Command(
        executable: xcrunURL,
        arguments: [
          "simctl", "spawn", id.rawValue,
          "launchctl", "print", Self.launchdDomain,
        ],
        timeout: .seconds(10),
        outputLimit: 8 * 1_024 * 1_024
      )
    )
    let configuredLabels = Self.parseLaunchdDomainLabels(output.standardOutput)
    return labels.intersection(configuredLabels)
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
          "launchctl", action, "\(Self.launchdDomain)/\(label)",
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
    let device = try await validatedDevice(id)
    guard device.state == .booted else {
      throw SimulatorWorkspaceError.deviceNotBooted(id)
    }
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

  static func parseLaunchdDomainLabels(_ output: String) -> Set<String> {
    enum Section {
      case none
      case services
      case disabledServices
    }

    var result = Set<String>()
    let punctuation = CharacterSet(charactersIn: "\"'(){}[],;")
    var section = Section.none

    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      switch trimmed {
      case "services = {":
        section = .services
        continue
      case "disabled services = {":
        section = .disabledServices
        continue
      case "}":
        section = .none
        continue
      default:
        break
      }

      if section == .disabledServices, let quoteStart = line.firstIndex(of: "\"") {
        let labelStart = line.index(after: quoteStart)
        if let quoteEnd = line[labelStart...].firstIndex(of: "\"") {
          let label = String(line[labelStart..<quoteEnd])
          if label.contains("."), isValidLaunchdLabel(label) {
            result.insert(label)
          }
        }
      }

      guard section == .services else { continue }
      guard let lastToken = line.split(whereSeparator: \.isWhitespace).last else {
        continue
      }
      let label = String(lastToken).trimmingCharacters(in: punctuation)
      if label.contains("."), isValidLaunchdLabel(label) {
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

  static func validatedDeviceName(_ name: String) throws -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName.count <= 128,
      !trimmedName.contains(where: { $0.isNewline })
    else {
      throw SimulatorWorkspaceError.invalidOperation(
        "设备名称不能为空、不能超过 128 个字符，且不能包含换行符"
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

private struct DeviceTypeDocument: Decodable {
  let devicetypes: [DeviceTypeRecord]
}

private struct DeviceTypeRecord: Decodable {
  let identifier: String
  let name: String
  let productFamily: String
  let modelIdentifier: String?
  let minRuntimeVersionString: String
  let maxRuntimeVersionString: String
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
