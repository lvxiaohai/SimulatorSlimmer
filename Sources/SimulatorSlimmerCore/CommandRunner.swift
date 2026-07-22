import Darwin
import Foundation

struct Command: Sendable {
  let executable: URL
  let arguments: [String]
  let environment: [String: String]
  let timeout: Duration
  let outputLimit: Int

  init(
    executable: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    timeout: Duration = .seconds(30),
    outputLimit: Int = 8 * 1_024 * 1_024
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.timeout = timeout
    self.outputLimit = outputLimit
  }

  var displayName: String {
    ([executable.lastPathComponent] + arguments).joined(separator: " ")
  }
}

struct CommandOutput: Sendable {
  let standardOutput: String
  let standardError: String
  let exitCode: Int32
}

protocol CommandRunning: Sendable {
  func run(_ command: Command) async throws -> CommandOutput
}

final class FoundationCommandRunner: CommandRunning, @unchecked Sendable {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func run(_ command: Command) async throws -> CommandOutput {
    let task = Task.detached(priority: .userInitiated) { [fileManager] in
      try Self.runSynchronously(command, fileManager: fileManager)
    }

    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func runSynchronously(
    _ command: Command,
    fileManager: FileManager
  ) throws -> CommandOutput {
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("SimulatorSlimmer-\(UUID().uuidString)", isDirectory: true)
    let standardOutputURL = temporaryDirectory.appendingPathComponent("stdout")
    let standardErrorURL = temporaryDirectory.appendingPathComponent("stderr")

    try fileManager.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    guard fileManager.createFile(atPath: standardOutputURL.path, contents: nil),
      fileManager.createFile(atPath: standardErrorURL.path, contents: nil)
    else {
      throw SimulatorWorkspaceError.invalidOperation("无法创建命令输出缓冲区")
    }

    let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
    let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
    defer {
      try? standardOutputHandle.close()
      try? standardErrorHandle.close()
    }

    let process = Process()
    process.executableURL = command.executable
    process.arguments = command.arguments
    if !command.environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(
        command.environment,
        uniquingKeysWith: { _, replacement in replacement }
      )
    }
    process.standardOutput = standardOutputHandle
    process.standardError = standardErrorHandle
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw SimulatorWorkspaceError.xcodeToolsUnavailable(
        "无法启动 \(command.executable.path)：\(error.localizedDescription)"
      )
    }

    let deadline = ContinuousClock.now.advanced(by: command.timeout)
    var stopReason: StopReason?

    while process.isRunning {
      if Task.isCancelled {
        stopReason = .cancelled
        break
      }
      if ContinuousClock.now >= deadline {
        stopReason = .timedOut
        break
      }
      Thread.sleep(forTimeInterval: 0.04)
    }

    if let stopReason {
      terminate(process)
      switch stopReason {
      case .cancelled:
        throw CancellationError()
      case .timedOut:
        throw SimulatorWorkspaceError.commandTimedOut(command.displayName)
      }
    }

    process.waitUntilExit()
    try standardOutputHandle.close()
    try standardErrorHandle.close()

    let standardOutput = try readOutput(
      at: standardOutputURL,
      limit: command.outputLimit,
      command: command.displayName
    )
    let standardError = try readOutput(
      at: standardErrorURL,
      limit: command.outputLimit,
      command: command.displayName
    )

    guard process.terminationStatus == 0 else {
      let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw SimulatorWorkspaceError.commandFailed(
        command: command.displayName,
        code: process.terminationStatus,
        message: message.isEmpty ? standardOutput : message
      )
    }

    return CommandOutput(
      standardOutput: standardOutput,
      standardError: standardError,
      exitCode: process.terminationStatus
    )
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()

    let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
    while process.isRunning, ContinuousClock.now < graceDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }

    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
  }

  private static func readOutput(
    at url: URL,
    limit: Int,
    command: String
  ) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else {
      throw SimulatorWorkspaceError.malformedOutput(
        "命令 \(command) 的输出超过 \(limit) 字节安全上限"
      )
    }
    return String(decoding: data, as: UTF8.self)
  }

  private enum StopReason {
    case cancelled
    case timedOut
  }
}
