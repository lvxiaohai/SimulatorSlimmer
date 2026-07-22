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
    case opaqueReceipts

    var launchArgument: String? {
      switch self {
      case .ready: nil
      case .empty: "--ui-testing-empty"
      case .error: "--ui-testing-error"
      case .partial: "--ui-testing-partial"
      case .interrupted: "--ui-testing-interrupted"
      case .unsupported: "--ui-testing-unsupported"
      case .opaqueReceipts: "--ui-testing-opaque-receipts"
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

  func testBootedDeviceRequiresShutdownBeforeStorageOperations() {
    let app = launch(.ready)

    XCTAssertTrue(app.buttons["存储"].waitForExistence(timeout: 5))
    app.buttons["存储"].click()

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

  func testInterruptedReceiptShowsRecoveryPrompt() {
    let app = launch(.interrupted)

    XCTAssertTrue(element(identifier: "optimization.page", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["发现未完成操作"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["继续验证"].exists)

    app.buttons["查看回执"].click()
    XCTAssertTrue(app.staticTexts["待确认步骤"].waitForExistence(timeout: 3))
    let pendingChange = element(
      identifier: "service-change.com.apple.suggestionsd",
      in: app
    )
    XCTAssertTrue(pendingChange.waitForExistence(timeout: 3))
    XCTAssertTrue(pendingChange.label.contains("系统建议"))
    XCTAssertEqual(pendingChange.value as? String, "运行 → 暂停")
    XCTAssertTrue(app.buttons["继续验证"].exists)
    XCTAssertTrue(app.buttons["恢复基线"].exists)
  }

  func testUnsupportedRuntimeKeepsOnlyBasicDeviceControls() {
    let app = launch(.unsupported)

    XCTAssertTrue(
      element(identifier: "runtime-unsupported.page", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["此运行时尚未验证"].exists)
    XCTAssertTrue(app.buttons["打开 Apple 模拟器"].exists)
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

  func testOpaqueReceiptsRemainReadOnlyAndExplainFailure() {
    let app = launch(.opaqueReceipts)

    let historyNavigation = element(identifier: "sidebar.history", in: app)
    XCTAssertTrue(historyNavigation.waitForExistence(timeout: 5))
    historyNavigation.click()
    XCTAssertTrue(element(identifier: "history.page", in: app).waitForExistence(timeout: 5))

    let unsupportedReceipt = element(
      identifier: "history.receipt.2AF81128-F810-465B-9C9F-F9C702CC3752",
      in: app
    )
    XCTAssertTrue(unsupportedReceipt.waitForExistence(timeout: 3))
    XCTAssertTrue(unsupportedReceipt.label.contains("只读回执"))
    unsupportedReceipt.click()
    XCTAssertTrue(
      element(identifier: "receipt.opaque.unsupportedSchema", in: app)
        .waitForExistence(timeout: 3)
    )
    XCTAssertFalse(app.buttons["继续验证"].exists)
    XCTAssertFalse(app.buttons["恢复基线"].exists)

    let corruptedReceipt = element(
      identifier: "history.receipt.A94AA544-95B3-4663-A31D-D78E2A1E139E",
      in: app
    )
    XCTAssertTrue(corruptedReceipt.waitForExistence(timeout: 3))
    XCTAssertTrue(corruptedReceipt.label.contains("回执损坏"))
    corruptedReceipt.click()
    XCTAssertTrue(
      element(identifier: "receipt.opaque.corrupted", in: app).waitForExistence(timeout: 3)
    )
    XCTAssertFalse(app.buttons["继续验证"].exists)
    XCTAssertFalse(app.buttons["恢复基线"].exists)
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
