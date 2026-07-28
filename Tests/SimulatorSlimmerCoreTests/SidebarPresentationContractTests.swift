import Foundation
import Testing

@Suite("侧边栏呈现契约")
struct SidebarPresentationContractTests {
  @Test("顶部操作按钮不会自动获得键盘焦点")
  func headerButtonsAreExcludedFromKeyboardFocus() throws {
    let source = try sidebarSource()
    let headerButton = try #require(
      source.range(of: "private struct SidebarHeaderButton: View")
    )
    let headerButtonStyle = try #require(
      source.range(of: "private struct SidebarHeaderButtonStyle: ButtonStyle")
    )
    let definition = source[headerButton.lowerBound..<headerButtonStyle.lowerBound]

    #expect(definition.contains(".focusable(false)"))
  }

  private func sidebarSource() throws -> String {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot =
      testDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repositoryRoot
      .appendingPathComponent("App", isDirectory: true)
      .appendingPathComponent("SimulatorSlimmer", isDirectory: true)
      .appendingPathComponent("Features", isDirectory: true)
      .appendingPathComponent("Sidebar", isDirectory: true)
      .appendingPathComponent("SimulatorSidebar.swift", isDirectory: false)

    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
