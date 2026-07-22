import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("命令运行器行为")
struct CommandRunnerBehaviorTests {
  @Test("并发命令使用相互隔离的输出缓冲区")
  func concurrentCommandsRemainIsolated() async throws {
    let runner = FoundationCommandRunner()
    let outputs = try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0..<24 {
        group.addTask {
          try await runner.run(
            Command(
              executable: URL(fileURLWithPath: "/usr/bin/printf"),
              arguments: ["token-%02d", "\(index)"],
              timeout: .seconds(5)
            )
          ).standardOutput
        }
      }

      var values: [String] = []
      for try await value in group {
        values.append(value)
      }
      return values
    }

    #expect(Set(outputs) == Set((0..<24).map { String(format: "token-%02d", $0) }))
  }

  @Test("标准输出与错误输出分离且参数不会被 Shell 解释")
  func separatesStreamsAndPassesLiteralArguments() async throws {
    let runner = FoundationCommandRunner()
    let literal = "; touch /tmp/SimulatorSlimmer-should-not-exist"
    try? FileManager.default.removeItem(atPath: "/tmp/SimulatorSlimmer-should-not-exist")

    let output = try await runner.run(
      Command(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf stdout; printf stderr >&2", "--", literal]
      )
    )
    #expect(output.standardOutput == "stdout")
    #expect(output.standardError == "stderr")

    let literalOutput = try await runner.run(
      Command(
        executable: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["%s", literal]
      )
    )
    #expect(literalOutput.standardOutput == literal)
    #expect(!FileManager.default.fileExists(atPath: "/tmp/SimulatorSlimmer-should-not-exist"))
  }

  @Test("超时会终止子进程")
  func timeoutTerminatesProcess() async {
    let runner = FoundationCommandRunner()

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await runner.run(
        Command(
          executable: URL(fileURLWithPath: "/bin/sleep"),
          arguments: ["5"],
          timeout: .milliseconds(50)
        )
      )
    }
  }

  @Test("输出超过安全上限时拒绝返回截断数据")
  func outputLimitIsEnforced() async {
    let runner = FoundationCommandRunner()

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await runner.run(
        Command(
          executable: URL(fileURLWithPath: "/usr/bin/printf"),
          arguments: ["123456789"],
          outputLimit: 8
        )
      )
    }
  }

  @Test("长时间输出会在进程退出前触发上限并被终止")
  func streamingOutputLimitTerminatesProducerEarly() async {
    let runner = FoundationCommandRunner()
    let startedAt = ContinuousClock.now

    await #expect(throws: SimulatorWorkspaceError.self) {
      _ = try await runner.run(
        Command(
          executable: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "while :; do printf 12345678901234567890; done"],
          timeout: .seconds(5),
          outputLimit: 1_024
        )
      )
    }

    #expect(startedAt.duration(to: .now) < .seconds(2))
  }
}
