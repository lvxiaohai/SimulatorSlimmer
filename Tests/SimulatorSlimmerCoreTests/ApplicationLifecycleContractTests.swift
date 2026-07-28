import Foundation
import Testing

@Suite("应用生命周期契约")
struct ApplicationLifecycleContractTests {
  @Test("关闭主窗口会退出主进程")
  func closingMainWindowTerminatesMainApplication() throws {
    let source = try source(
      "App/SimulatorSlimmer/App/SimulatorSlimmerApp.swift"
    )

    #expect(
      source.contains(
        "func applicationShouldTerminateAfterLastWindowClosed"
      )
    )
    #expect(source.contains("true"))
    #expect(!source.contains("setActivationPolicy(.accessory)"))
  }

  @Test("菜单栏开关管理独立 Helper")
  func menuBarSettingControlsEmbeddedHelper() throws {
    let source = try source(
      "App/SimulatorSlimmer/App/SimulatorSlimmerApp.swift"
    )

    #expect(source.contains("Contents"))
    #expect(source.contains("Helpers"))
    #expect(source.contains("SimulatorSlimmerMenu"))
    #expect(source.contains("DistributedNotificationCenter.default().post"))
  }

  @Test("Helper 打开主应用且设备子菜单才读取应用")
  func helperOpensMainApplicationAndLazilyLoadsApplications() throws {
    let source = try source(
      "App/SimulatorSlimmerMenuHelper/MenuHelperMain.swift"
    )
    let menuWillOpen = try #require(
      source.range(of: "func menuWillOpen(_ menu: NSMenu)")
    )
    let loadApplications = try #require(
      source.range(of: "loadApplications(for: device, in: menu)")
    )

    #expect(menuWillOpen.lowerBound < loadApplications.lowerBound)
    #expect(source.contains("workspace.menuBarSnapshot()"))
    #expect(source.contains("workspace.applications(for: device.id)"))
    #expect(source.contains("HelperLocation.mainApplicationURL"))
  }

  private func source(_ relativePath: String) throws -> String {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot =
      testDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }
}
