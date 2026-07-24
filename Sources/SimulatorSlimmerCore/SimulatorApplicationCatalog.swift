import Foundation

public enum SimulatorApplicationKind: String, Codable, CaseIterable, Hashable, Sendable {
  case user
  case system
  case unknown
}

public struct SimulatorApplicationIcon: Hashable, Sendable {
  public let declaredName: String?
  public let fileURL: URL?

  public init(declaredName: String? = nil, fileURL: URL? = nil) {
    self.declaredName = declaredName
    self.fileURL = fileURL
  }
}

public struct SimulatorApplication: Identifiable, Hashable, Sendable {
  public let kind: SimulatorApplicationKind
  public let displayName: String
  public let bundleIdentifier: String
  public let bundleURL: URL?
  public let dataContainerURL: URL?
  public let marketingVersion: String?
  public let buildVersion: String?
  public let icon: SimulatorApplicationIcon

  public init(
    kind: SimulatorApplicationKind,
    displayName: String,
    bundleIdentifier: String,
    bundleURL: URL?,
    dataContainerURL: URL?,
    marketingVersion: String?,
    buildVersion: String?,
    icon: SimulatorApplicationIcon
  ) {
    self.kind = kind
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.bundleURL = bundleURL
    self.dataContainerURL = dataContainerURL
    self.marketingVersion = marketingVersion
    self.buildVersion = buildVersion
    self.icon = icon
  }

  public var id: String { bundleIdentifier }
}

public struct SimulatorApplicationCatalog: Sendable {
  private let runner: any CommandRunning
  private let devicesRootURL: URL
  private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

  public init() {
    self.runner = FoundationCommandRunner()
    self.devicesRootURL = Self.defaultDevicesRootURL
  }

  init(
    runner: any CommandRunning,
    devicesRootURL: URL = Self.defaultDevicesRootURL
  ) {
    self.runner = runner
    self.devicesRootURL = devicesRootURL.standardizedFileURL
  }

  public func applications(for deviceID: SimulatorID) async throws
    -> [SimulatorApplication]
  {
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }

    let output: CommandOutput
    do {
      output = try await runner.run(
        Command(
          executable: Self.xcrunURL,
          arguments: ["simctl", "listapps", deviceID.rawValue],
          timeout: .seconds(30),
          outputLimit: 16 * 1_024 * 1_024
        )
      )
    } catch SimulatorWorkspaceError.commandFailed(_, let code, let message)
      where Self.isDeviceNotBootedFailure(code: code, message: message)
    {
      throw SimulatorWorkspaceError.deviceNotBooted(deviceID)
    }

    let records = try Self.parseRecords(output.standardOutput)
    return
      records
      .compactMap(Self.makeApplication)
      .sorted {
        let comparison = $0.displayName.localizedStandardCompare($1.displayName)
        if comparison != .orderedSame {
          return comparison == .orderedAscending
        }
        return $0.bundleIdentifier.localizedStandardCompare($1.bundleIdentifier)
          == .orderedAscending
      }
  }

  public func dataContainer(
    for deviceID: SimulatorID,
    bundleIdentifier: String
  ) async throws -> URL? {
    guard SimctlAdapter.isValidUDID(deviceID.rawValue) else {
      throw SimulatorWorkspaceError.deviceNotFound(deviceID)
    }
    guard Self.isValidBundleIdentifier(bundleIdentifier) else {
      throw SimulatorWorkspaceError.invalidOperation("无效的应用 Bundle ID")
    }

    let output: CommandOutput
    do {
      output = try await runner.run(
        Command(
          executable: Self.xcrunURL,
          arguments: [
            "simctl", "get_app_container", deviceID.rawValue,
            bundleIdentifier, "data",
          ],
          timeout: .seconds(30),
          outputLimit: 1 * 1_024 * 1_024
        )
      )
    } catch SimulatorWorkspaceError.commandFailed(_, let code, let message)
      where Self.isDeviceNotBootedFailure(code: code, message: message)
    {
      throw SimulatorWorkspaceError.deviceNotBooted(deviceID)
    }

    guard let candidate = Self.fileURL(output.standardOutput) else {
      return nil
    }
    return try Self.validatedDataContainer(
      candidate,
      deviceID: deviceID,
      devicesRootURL: devicesRootURL
    )
  }

  private static func parseRecords(_ output: String) throws
    -> [(bundleIdentifier: String, values: [String: Any])]
  {
    let propertyList: Any
    do {
      propertyList = try PropertyListSerialization.propertyList(
        from: Data(output.utf8),
        options: [],
        format: nil
      )
    } catch {
      throw SimulatorWorkspaceError.malformedOutput(error.localizedDescription)
    }

    guard let dictionary = propertyList as? [String: Any] else {
      throw SimulatorWorkspaceError.malformedOutput("应用列表顶层不是字典")
    }

    return dictionary.compactMap { key, value in
      guard let values = value as? [String: Any] else { return nil }
      return (bundleIdentifier: key, values: values)
    }
  }

  private static func makeApplication(
    from record: (bundleIdentifier: String, values: [String: Any])
  ) -> SimulatorApplication? {
    let listedIdentifier = stringValue(record.values["CFBundleIdentifier"])
    let bundleIdentifier = listedIdentifier ?? nonEmpty(record.bundleIdentifier)
    guard let bundleIdentifier else { return nil }

    let bundleURL =
      fileURL(record.values["Bundle"])
      ?? fileURL(record.values["Path"])
    let dataContainerURL = fileURL(record.values["DataContainer"])
    let info = bundleURL.flatMap(readInfoPlist) ?? [:]

    let displayName =
      stringValue(record.values["CFBundleDisplayName"])
      ?? stringValue(record.values["CFBundleName"])
      ?? stringValue(info["CFBundleDisplayName"])
      ?? stringValue(info["CFBundleName"])
      ?? bundleIdentifier
    let marketingVersion =
      stringValue(info["CFBundleShortVersionString"])
      ?? stringValue(record.values["CFBundleShortVersionString"])
    let buildVersion =
      stringValue(info["CFBundleVersion"])
      ?? stringValue(record.values["CFBundleVersion"])
    let icon = iconDescriptor(info: info, bundleURL: bundleURL)

    return SimulatorApplication(
      kind: applicationKind(record.values["ApplicationType"]),
      displayName: displayName,
      bundleIdentifier: bundleIdentifier,
      bundleURL: bundleURL,
      dataContainerURL: dataContainerURL,
      marketingVersion: marketingVersion,
      buildVersion: buildVersion,
      icon: icon
    )
  }

  private static func applicationKind(_ value: Any?) -> SimulatorApplicationKind {
    switch stringValue(value)?.lowercased() {
    case "user": .user
    case "system": .system
    default: .unknown
    }
  }

  private static func readInfoPlist(at bundleURL: URL) -> [String: Any]? {
    guard bundleURL.isFileURL else { return nil }
    let infoURL = bundleURL.appendingPathComponent("Info.plist", isDirectory: false)
    guard let data = try? Data(contentsOf: infoURL, options: [.mappedIfSafe]),
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
    else {
      return nil
    }
    return propertyList as? [String: Any]
  }

  private static func iconDescriptor(
    info: [String: Any],
    bundleURL: URL?
  ) -> SimulatorApplicationIcon {
    let primaryIcon =
      primaryIconDictionary(info["CFBundleIcons"])
      ?? primaryIconDictionary(info["CFBundleIcons~ipad"])
    let declaredName = safeIconName(stringValue(primaryIcon?["CFBundleIconName"]))
    let iconFiles =
      stringArray(primaryIcon?["CFBundleIconFiles"])
      + stringArray(info["CFBundleIconFiles"])
    let safeIconFiles = iconFiles.compactMap(safeIconName)
    let fileDeclarations =
      safeIconFiles
      + (declaredName.map { safeIconFiles.contains($0) ? [] : [$0] } ?? [])
    let fileURL = bundleURL.flatMap {
      resolveIconFile(named: fileDeclarations, inside: $0)
    }

    return SimulatorApplicationIcon(
      declaredName: declaredName ?? safeIconFiles.first,
      fileURL: fileURL
    )
  }

  private static func primaryIconDictionary(_ value: Any?) -> [String: Any]? {
    guard let icons = value as? [String: Any] else { return nil }
    return icons["CFBundlePrimaryIcon"] as? [String: Any]
  }

  private static func resolveIconFile(
    named declaredFiles: [String],
    inside bundleURL: URL
  ) -> URL? {
    guard !declaredFiles.isEmpty, bundleURL.isFileURL else { return nil }
    let fileManager = FileManager.default
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: bundleURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    let resolvedRoot = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let candidates = children.filter { child in
      declaredFiles.contains { iconFileName(child.lastPathComponent, matches: $0) }
    }
    .sorted {
      let leftScore = iconFileScore($0.lastPathComponent)
      let rightScore = iconFileScore($1.lastPathComponent)
      if leftScore != rightScore { return leftScore > rightScore }
      return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
        == .orderedAscending
    }

    for candidate in candidates {
      let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard resolvedCandidate.deletingLastPathComponent() == resolvedRoot else {
        continue
      }
      let values = try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else {
        continue
      }
      return candidate.standardizedFileURL
    }
    return nil
  }

  private static func iconFileName(_ fileName: String, matches declaration: String)
    -> Bool
  {
    let declarationStem =
      declaration.lowercased().hasSuffix(".png")
      ? String(declaration.dropLast(4))
      : declaration
    return fileName == declaration
      || fileName == "\(declaration).png"
      || (fileName.hasPrefix("\(declarationStem)@") && fileName.hasSuffix(".png"))
  }

  private static func iconFileScore(_ name: String) -> Int {
    var score = 0
    if name.contains("@3x") {
      score += 30
    } else if name.contains("@2x") {
      score += 20
    } else {
      score += 10
    }
    if name.contains("~ipad") {
      score -= 1
    }
    return score
  }

  private static func safeIconName(_ value: String?) -> String? {
    guard let value = nonEmpty(value),
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("..")
    else {
      return nil
    }
    return value
  }

  private static func stringArray(_ value: Any?) -> [String] {
    (value as? [Any])?.compactMap(stringValue) ?? []
  }

  private static func fileURL(_ value: Any?) -> URL? {
    guard let value = stringValue(value), value != "(null)" else { return nil }
    if value.hasPrefix("/") {
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    guard let url = URL(string: value), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return nonEmpty(value)
    }
    if let value = value as? NSNumber {
      return nonEmpty(value.stringValue)
    }
    return nil
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isDeviceNotBootedFailure(code: Int32, message: String) -> Bool {
    code == 149
      || message.localizedCaseInsensitiveContains("current state: Shutdown")
      || message.localizedCaseInsensitiveContains("must be booted")
  }

  private static func isValidBundleIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 255 else { return false }
    return value.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
    }
  }

  private static func validatedDataContainer(
    _ candidate: URL,
    deviceID: SimulatorID,
    devicesRootURL: URL
  ) throws -> URL {
    guard candidate.isFileURL else {
      throw SimulatorWorkspaceError.unsafePath(candidate.absoluteString)
    }

    let expectedRoot =
      devicesRootURL
      .appendingPathComponent(deviceID.rawValue, isDirectory: true)
      .appendingPathComponent(
        "data/Containers/Data/Application",
        isDirectory: true
      )
      .standardizedFileURL
    let normalizedCandidate = candidate.standardizedFileURL
    guard normalizedCandidate.deletingLastPathComponent() == expectedRoot,
      UUID(uuidString: normalizedCandidate.lastPathComponent) != nil
    else {
      throw SimulatorWorkspaceError.unsafePath(candidate.path)
    }

    let resolvedRoot = expectedRoot.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate =
      normalizedCandidate.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedRoot == expectedRoot,
      resolvedCandidate == normalizedCandidate,
      resolvedCandidate.deletingLastPathComponent() == resolvedRoot
    else {
      throw SimulatorWorkspaceError.unsafePath(candidate.path)
    }

    let values = try? resolvedCandidate.resourceValues(forKeys: [.isDirectoryKey])
    guard values?.isDirectory == true else {
      throw SimulatorWorkspaceError.unsafePath(candidate.path)
    }
    return resolvedCandidate
  }

  private static var defaultDevicesRootURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Developer/CoreSimulator/Devices",
        isDirectory: true
      )
      .standardizedFileURL
  }
}
