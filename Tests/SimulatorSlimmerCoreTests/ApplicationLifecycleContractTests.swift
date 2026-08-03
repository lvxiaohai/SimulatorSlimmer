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

  @Test("主应用使用 GitHub Release 检查 Sparkle 更新")
  func appChecksGitHubReleasesForSparkleUpdates() throws {
    let appSource = try source(
      "App/SimulatorSlimmer/App/SimulatorSlimmerApp.swift"
    )
    let commandSource = try source(
      "App/SimulatorSlimmer/App/Commands.swift"
    )
    let infoPlist = try source("App/SimulatorSlimmer/Info.plist")
    let workflow = try source(".github/workflows/release.yml")

    #expect(appSource.contains("SPUStandardUpdaterController"))
    #expect(appSource.contains("checkForUpdatesInBackground()"))
    #expect(appSource.contains("userDriverDelegate: self"))
    #expect(
      appSource.contains(
        "standardUserDriverShouldHandleShowingScheduledUpdate"
      )
    )
    #expect(appSource.contains("controller.checkForUpdates(nil)"))
    #expect(commandSource.contains("checkForUpdates(nil)"))
    #expect(
      infoPlist.contains(
        "https://github.com/lvxiaohai/SimulatorSlimmer/releases/latest/download/appcast.xml"
      )
    )
    #expect(infoPlist.contains("SUPublicEDKey"))
    #expect(
      infoPlist.contains(
        "<key>SUAutomaticallyUpdate</key>\n\t<false/>"
      )
    )
    #expect(
      infoPlist.contains(
        "<key>SUAllowsAutomaticUpdates</key>\n\t<false/>"
      )
    )
    #expect(workflow.contains("gh release create"))
    #expect(workflow.contains("SPARKLE_ED_PRIVATE_KEY"))
    #expect(!workflow.localizedCaseInsensitiveContains("cloudflare"))
  }

  @Test("应用菜单与菜单栏 Helper 跟随应用语言")
  func menusFollowSelectedApplicationLanguage() throws {
    let appSource = try source(
      "App/SimulatorSlimmer/App/SimulatorSlimmerApp.swift"
    )
    let commandSource = try source(
      "App/SimulatorSlimmer/App/Commands.swift"
    )
    let helperSource = try source(
      "App/SimulatorSlimmerMenuHelper/MenuHelperMain.swift"
    )
    let project = try source("SimulatorSlimmer.xcodeproj/project.pbxproj")

    #expect(commandSource.contains("@AppStorage(\"appLanguage\")"))
    #expect(commandSource.contains("Button(L10n.text(\"command.settings\"))"))
    #expect(appSource.contains("language: selectedLanguage"))
    #expect(appSource.contains("process.arguments = [\"--language\", language.identifier]"))
    #expect(helperSource.contains("MenuL10n.text(\"menu-bar.show-main-window\")"))
    #expect(project.contains("Localizable.xcstrings in Menu Resources"))
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

  @Test("设备图标不改变顶层菜单文字对齐")
  func deviceIconDoesNotCreateTopLevelMenuImageColumn() throws {
    let source = try source(
      "App/SimulatorSlimmerMenuHelper/MenuHelperMain.swift"
    )
    let makeDeviceItem = try #require(
      source.range(of: "private func makeDeviceItem")
    )
    let buildDeviceMenu = try #require(
      source.range(of: "private func buildUnloadedDeviceMenu")
    )
    let deviceItemSource = source[
      makeDeviceItem.lowerBound..<buildDeviceMenu.lowerBound
    ]

    #expect(deviceItemSource.contains("item.attributedTitle = menuTitle"))
    #expect(!deviceItemSource.contains("item.image = symbolImage"))
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
