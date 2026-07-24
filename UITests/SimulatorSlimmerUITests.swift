import XCTest

@MainActor
final class SimulatorSlimmerUITests: XCTestCase {
  private let phoneID = "1B59C381-1963-4384-BC43-8A3EE7E8E61B"
  private let tabletID = "541BD79A-07A9-4EEB-9932-B1B2E019BF9A"

  private enum Fixture {
    case ready
    case empty
    case error
    case partial
    case interrupted
    case unsupported

    var launchArgument: String? {
      switch self {
      case .ready: nil
      case .empty: "--ui-testing-empty"
      case .error: "--ui-testing-error"
      case .partial: "--ui-testing-partial"
      case .interrupted: "--ui-testing-interrupted"
      case .unsupported: "--ui-testing-unsupported"
      }
    }
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testReadyWorkspaceShowsScriptedDevice() {
    let app = launch(.ready)

    XCTAssertTrue(element(identifier: "optimization.page", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["优化此模拟器"].waitForExistence(timeout: 5))
  }

  func testCompletedOptimizationDoesNotRestartAfterSwitchingDevices() {
    let app = launch(.ready)

    XCTAssertTrue(element(identifier: "optimization.page", in: app).waitForExistence(timeout: 5))
    app.buttons["优化此模拟器"].click()

    let previewSheet = element(identifier: "operation-preview.sheet", in: app)
    XCTAssertTrue(previewSheet.waitForExistence(timeout: 3))
    previewSheet.buttons["优化此模拟器"].click()

    let successMessage = app.staticTexts["最终状态已验证，并已保存可恢复基线。"]
    XCTAssertTrue(successMessage.waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["正在优化"].exists)

    app.buttons["iPad Pro 13-inch"].click()
    XCTAssertTrue(app.staticTexts["iPad Pro 13-inch"].waitForExistence(timeout: 3))
    app.buttons["iPhone 17 Pro"].click()

    XCTAssertTrue(successMessage.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["正在优化"].exists)
  }

  func testOptimizationProfileDraftIsScopedToEachDevice() {
    let app = launch(.ready)

    let extremeProfile = app.radioButtons["极致"]
    XCTAssertTrue(extremeProfile.waitForExistence(timeout: 5))
    extremeProfile.click()
    XCTAssertTrue(extremeProfile.isSelected)

    app.buttons["iPad Pro 13-inch"].click()
    let recommendedProfile = app.radioButtons["推荐"]
    XCTAssertTrue(recommendedProfile.waitForExistence(timeout: 3))
    XCTAssertTrue(recommendedProfile.isSelected)

    app.buttons["iPhone 17 Pro"].click()
    XCTAssertTrue(extremeProfile.waitForExistence(timeout: 3))
    XCTAssertTrue(extremeProfile.isSelected)
  }

  func testBootedDeviceRequiresShutdownBeforeStorageOperations() {
    let app = launch(.ready)

    let storageSection = sectionControl("存储", in: app)
    XCTAssertTrue(storageSection.waitForExistence(timeout: 5))
    storageSection.click()

    XCTAssertTrue(app.staticTexts["请先关闭模拟器"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["关机"].exists)
    XCTAssertTrue(app.buttons["扫描存储"].exists)
    XCTAssertFalse(app.buttons["扫描存储"].isEnabled)
  }

  func testEmptyWorkspaceShowsGuidance() {
    let app = launch(.empty)

    XCTAssertTrue(app.staticTexts["没有可用的模拟器"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["刷新"].exists)
  }

  func testWorkspaceErrorShowsRecoveryActions() {
    let app = launch(.error)

    XCTAssertTrue(app.staticTexts["Xcode 工具不可用"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["重试"].exists)
  }

  func testPartialBatchResultRemainsVisible() {
    let app = launch(.partial)
    startBatchOptimization(in: app)

    XCTAssertTrue(app.staticTexts["批量优化已结束"].waitForExistence(timeout: 8))
    assertBatchItem(
      tabletID,
      in: app,
      contains: ["失败", "部分变更未通过最终验证"]
    )
  }

  func testBatchReportsRunningThenSuccess() {
    let app = launch(.ready)
    startBatchOptimization(in: app)

    XCTAssertTrue(app.staticTexts["执行中"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["批量优化已结束"].waitForExistence(timeout: 8))
    assertBatchItem(phoneID, in: app, contains: ["成功", "已完成并通过验证"])
    assertBatchItem(tabletID, in: app, contains: ["成功", "已完成并通过验证"])
  }

  func testBatchDoesNotExecuteBeforeExplicitConfirmation() {
    let app = launch(.ready)
    openBatchPreview(in: app)

    XCTAssertTrue(app.staticTexts["确认批量优化"].exists)
    XCTAssertTrue(app.staticTexts["iPhone 17 Pro"].exists)
    XCTAssertTrue(app.staticTexts["iPad Pro 13-inch"].exists)
    XCTAssertTrue(app.buttons["确认并开始"].exists)
    XCTAssertFalse(app.staticTexts["执行中"].exists)

    app.buttons["取消"].click()
    XCTAssertFalse(element(identifier: "batch-preview.sheet", in: app).exists)
    XCTAssertFalse(app.staticTexts["串行队列"].exists)
  }

  func testBatchOffersEditableCustomProfile() {
    let app = launch(.ready)

    let batchNavigation = element(identifier: "sidebar.batch-optimization", in: app)
    XCTAssertTrue(batchNavigation.waitForExistence(timeout: 5))
    batchNavigation.click()
    XCTAssertTrue(
      element(identifier: "batch-optimization.page", in: app).waitForExistence(timeout: 5)
    )

    let customProfile = app.radioButtons["自定义"]
    XCTAssertTrue(customProfile.waitForExistence(timeout: 3))
    customProfile.click()

    XCTAssertTrue(app.staticTexts["选择要停用的服务"].waitForExistence(timeout: 3))
    XCTAssertTrue(element(identifier: "custom-services.select-all", in: app).exists)
    XCTAssertTrue(element(identifier: "custom-services.clear", in: app).exists)
    let firstGroup = app.disclosureTriangles.firstMatch
    XCTAssertTrue(firstGroup.exists)
    firstGroup.click()
    XCTAssertTrue(
      element(identifier: "custom-services.group.intelligence.select-all", in: app)
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(element(identifier: "custom-services.group.intelligence.clear", in: app).exists)
    XCTAssertTrue(
      app.staticTexts
        .matching(NSPredicate(format: "value BEGINSWITH '已记住 '"))
        .firstMatch
        .exists
    )
  }

  func testInterruptedReceiptKeepsContinuationWithoutSafetyBanner() {
    let app = launch(.interrupted)

    XCTAssertTrue(element(identifier: "optimization.page", in: app).waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["发现未完成操作"].exists)
    XCTAssertTrue(app.buttons["继续验证"].exists)
  }

  func testDestructiveConfirmationIgnoresReturnKey() {
    let app = launch(.ready)

    let deviceSection = sectionControl("设备", in: app)
    XCTAssertTrue(deviceSection.waitForExistence(timeout: 5))
    deviceSection.click()
    XCTAssertTrue(app.buttons["抹掉内容"].waitForExistence(timeout: 3))
    app.buttons["抹掉内容"].click()

    let dangerSheet = element(identifier: "danger-confirmation.sheet", in: app)
    XCTAssertTrue(dangerSheet.waitForExistence(timeout: 3))
    let confirmationField = app.textFields["确认文本"]
    XCTAssertTrue(confirmationField.waitForExistence(timeout: 3))
    confirmationField.click()
    confirmationField.typeText("iPhone 17 Pro")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(dangerSheet.exists)
    XCTAssertFalse(element(identifier: "operation-preview.sheet", in: app).exists)

    let confirmButton = app.buttons["确认抹掉"]
    XCTAssertTrue(confirmButton.isEnabled)
    confirmButton.click()

    let previewSheet = element(identifier: "operation-preview.sheet", in: app)
    XCTAssertTrue(previewSheet.waitForExistence(timeout: 3))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(previewSheet.exists)
  }

  func testUnsupportedRuntimeKeepsOnlyBasicDeviceControls() {
    let app = launch(.unsupported)

    XCTAssertTrue(
      element(identifier: "runtime-unsupported.page", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["此运行时尚未验证"].exists)
    XCTAssertTrue(app.buttons["显示 Apple 模拟器"].exists)
    XCTAssertFalse(app.buttons["优化此模拟器"].exists)
    XCTAssertFalse(app.buttons["扫描存储"].exists)
    XCTAssertFalse(app.buttons["克隆"].exists)
    XCTAssertFalse(app.buttons["抹掉内容"].exists)
    XCTAssertFalse(app.buttons["删除"].exists)

    element(identifier: "sidebar.batch-optimization", in: app).click()
    XCTAssertTrue(
      element(identifier: "batch-optimization.page", in: app).waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      element(identifier: "batch-optimization.empty", in: app).waitForExistence(timeout: 3)
    )
  }

  private func launch(_ fixture: Fixture) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "-AppleLanguages", "(zh-Hans)",
      "-AppleLocale", "zh_CN",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    if let launchArgument = fixture.launchArgument {
      app.launchArguments.append(launchArgument)
    }
    app.launch()
    addTeardownBlock { app.terminate() }

    if !app.windows.firstMatch.waitForExistence(timeout: 5) {
      app.typeKey("n", modifierFlags: .command)
    }
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    return app
  }

  private func element(identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func sectionControl(_ title: String, in app: XCUIApplication) -> XCUIElement {
    app.radioButtons[title].firstMatch
  }

  private func assertBatchItem(
    _ deviceID: String,
    in app: XCUIApplication,
    contains expectedFragments: [String]
  ) {
    let item = element(identifier: "batch.queue.item.\(deviceID)", in: app)
    XCTAssertTrue(item.waitForExistence(timeout: 2))
    let value = item.value as? String ?? ""
    for fragment in expectedFragments {
      XCTAssertTrue(value.contains(fragment), "批量结果“\(value)”缺少“\(fragment)”")
    }
  }

  private func startBatchOptimization(in app: XCUIApplication) {
    openBatchPreview(in: app)
    let confirmButton = app.buttons["确认并开始"].firstMatch
    XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
    confirmButton.click()
  }

  private func openBatchPreview(in app: XCUIApplication) {
    let batchNavigation = element(identifier: "sidebar.batch-optimization", in: app)
    XCTAssertTrue(batchNavigation.waitForExistence(timeout: 5))
    batchNavigation.click()

    XCTAssertTrue(
      element(identifier: "batch-optimization.page", in: app).waitForExistence(timeout: 5)
    )
    let startButton = app.buttons["生成批量预览"].firstMatch
    XCTAssertTrue(startButton.waitForExistence(timeout: 5))
    startButton.click()
    XCTAssertTrue(
      element(identifier: "batch-preview.sheet", in: app).waitForExistence(timeout: 5)
    )
  }
}
