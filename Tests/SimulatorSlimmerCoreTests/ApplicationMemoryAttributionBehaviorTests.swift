import Foundation
import Testing

@testable import SimulatorSlimmerCore

@Suite("应用内存归属行为")
struct ApplicationMemoryAttributionBehaviorTests {
  @Test("只汇总应用包目录内的主进程和扩展进程")
  func attributesBundleProcessesWithoutUsingStringPrefixes() throws {
    let root = URL(fileURLWithPath: "/tmp/SimulatorSlimmer-Memory")
    let demoBundle = root.appendingPathComponent("Demo.app", isDirectory: true)
    let secondBundle = root.appendingPathComponent("Second.app", isDirectory: true)
    let applications = [
      makeApplication(identifier: "com.example.demo", bundleURL: demoBundle),
      makeApplication(identifier: "com.example.second", bundleURL: secondBundle),
      makeApplication(identifier: "com.example.no-bundle", bundleURL: nil),
    ]
    let samples = [
      ApplicationProcessMemorySample(
        executableURL: demoBundle.appendingPathComponent("Demo"),
        bytes: 100
      ),
      ApplicationProcessMemorySample(
        executableURL: demoBundle.appendingPathComponent(
          "PlugIns/Share.appex/Share",
          isDirectory: false
        ),
        bytes: 50
      ),
      ApplicationProcessMemorySample(
        executableURL: root.appendingPathComponent("Demo.app-copy/Helper"),
        bytes: 900
      ),
      ApplicationProcessMemorySample(
        executableURL: secondBundle.appendingPathComponent("Second"),
        bytes: 75
      ),
      ApplicationProcessMemorySample(
        executableURL: root.appendingPathComponent("Shared/WebKit"),
        bytes: 1_000
      ),
    ]
    let collectedAt = Date(timeIntervalSince1970: 1_234)

    let snapshots = LibprocMemoryInspector.attributeApplicationMemory(
      samples: samples,
      applications: applications,
      collectedAt: collectedAt
    )

    let demo = try #require(snapshots["com.example.demo"])
    #expect(demo.bytes == 150)
    #expect(demo.processCount == 2)
    #expect(demo.collectedAt == collectedAt)
    #expect(snapshots["com.example.second"]?.bytes == 75)
    #expect(snapshots["com.example.no-bundle"] == nil)
  }

  @Test("应用内存求和溢出时饱和到 Int64 最大值")
  func saturatesOverflowingApplicationMemory() throws {
    let bundle = URL(fileURLWithPath: "/tmp/Overflow.app", isDirectory: true)
    let application = makeApplication(
      identifier: "com.example.overflow",
      bundleURL: bundle
    )

    let snapshots = LibprocMemoryInspector.attributeApplicationMemory(
      samples: [
        ApplicationProcessMemorySample(
          executableURL: bundle.appendingPathComponent("One"),
          bytes: UInt64.max
        ),
        ApplicationProcessMemorySample(
          executableURL: bundle.appendingPathComponent("Two"),
          bytes: UInt64.max
        ),
      ],
      applications: [application],
      collectedAt: Date(timeIntervalSince1970: 0)
    )

    let snapshot = try #require(snapshots[application.bundleIdentifier])
    #expect(snapshot.bytes == Int64.max)
    #expect(snapshot.processCount == 2)
  }

  @Test("嵌套应用包优先归属到最深层 Bundle")
  func attributesNestedBundleToMostSpecificApplication() throws {
    let hostBundle = URL(fileURLWithPath: "/tmp/Host.app", isDirectory: true)
    let nestedBundle = hostBundle.appendingPathComponent(
      "Watch/Nested.app",
      isDirectory: true
    )
    let host = makeApplication(
      identifier: "com.example.host",
      bundleURL: hostBundle
    )
    let nested = makeApplication(
      identifier: "com.example.nested",
      bundleURL: nestedBundle
    )

    let snapshots = LibprocMemoryInspector.attributeApplicationMemory(
      samples: [
        ApplicationProcessMemorySample(
          executableURL: nestedBundle.appendingPathComponent("Nested"),
          bytes: 256
        )
      ],
      applications: [host, nested]
    )

    #expect(snapshots[host.bundleIdentifier] == nil)
    #expect(snapshots[nested.bundleIdentifier]?.bytes == 256)
  }

  private func makeApplication(
    identifier: String,
    bundleURL: URL?
  ) -> SimulatorApplication {
    SimulatorApplication(
      kind: .user,
      displayName: identifier,
      bundleIdentifier: identifier,
      bundleURL: bundleURL,
      dataContainerURL: nil,
      marketingVersion: nil,
      buildVersion: nil,
      icon: SimulatorApplicationIcon()
    )
  }
}
