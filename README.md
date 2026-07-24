# Simulator Slimmer

Simulator Slimmer 是一款完全使用 Swift 与 SwiftUI 实现的原生 macOS 工具，用于观察、精简和恢复 iOS Simulator 后台服务，并安全管理模拟器存储。界面只提供简体中文，不包含 Go 代码或 Go 运行时。

## 当前能力

- 枚举本机 iOS Runtime 与模拟器，显示启动状态、服务状态和进程内存快照。
- 提供稳妥、均衡、高效三种精简方案；每次修改前展示完整计划，修改后重新验证。
- 通过事务回执、设备文件锁和中断恢复保存操作证据，按原始基线精确恢复。
- 批量预览并串行处理多台模拟器，同一设备不会并发修改。
- 扫描已知安全路径内的缓存、日志和临时文件；删除前复核路径、文件身份和清单。
- 提供诊断包导出，以及启动、关机、打开 Simulator 等设备管理入口。

当前服务目录仅明确支持 iOS 26.3.1 与 iOS 26.5。未知或不可用 Runtime 默认只读，不执行服务修改。

## 安全边界

- 不使用私有 CoreSimulator.framework，不需要管理员权限。
- 不修改宿主 macOS 服务，不自动擦除或删除模拟器。
- 服务变更、存储清理、克隆、抹掉和删除都必须经过一次性预览确认；预览后状态或输入漂移、确认缺失及重复执行都会被拒绝。
- 恢复只处理回执记录且由本工具触达的服务，没有可靠回执时不会盲目全部启用。
- 存储扫描与清理只允许已关机设备；同时拒绝符号链接、路径越界、App Bundle 和 App 主数据目录，扫描结果过期后必须重新扫描。
- 路径安全模型及仍待用目录描述符彻底收口的极窄并发竞态，详见产品与技术规划的“风险与应对”。

## 开发与验证

要求 macOS 14 或更高版本、Xcode 26.5 或兼容版本，以及 Swift 6。

```bash
swift test

xcodebuild \
  -project SimulatorSlimmer.xcodeproj \
  -scheme SimulatorSlimmer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project SimulatorSlimmer.xcodeproj \
  -scheme SimulatorSlimmer \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ui-test-compile \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

上面的命令只编译 UI 测试，不启动界面。XCUIAutomation 会真实控制前台窗口，仅在专门的测试环境中显式运行；日常可见验收优先使用 `Computer Use` 做安全页面巡检，避免阻碍当前操作。

真实模拟器集成测试默认跳过，只能对专用、可丢弃的设备显式启用：

```bash
SIMULATOR_SLIMMER_INTEGRATION_UDID='<专用模拟器 UDID>' swift test
```

该测试会执行“预览 → 精简 → 验证 → 恢复 → 再验证”，并将设备恢复到测试前的电源状态。不要把日常开发设备的 UDID 传给它。

## 独立分发

项目不以 Mac App Store 上架为目标，使用 Developer ID、Apple 公证和 DMG 独立分发。先验证发布脚本，再导出本地 Release App：

```bash
scripts/test-release-scripts.sh
scripts/build-release-app.sh --debug-unsigned --clean
scripts/smoke-release-app.sh
```

正式 DMG 需要本机 Developer ID Application 证书、`create-dmg`，以及通过环境变量传入的 App Store Connect API 凭据：

```bash
DEVELOPER_ID_APPLICATION='Developer ID Application: ...' \
DEVELOPMENT_TEAM='...' \
APP_STORE_API_KEY_ID='...' \
APP_STORE_API_ISSUER_ID='...' \
APP_STORE_API_KEY_FILEPATH='/绝对路径/AuthKey_....p8' \
scripts/build-dmg.sh
```

脚本会依次完成 App 构建与签名、App 公证与装订、DMG 制作与签名、DMG 公证与装订，并验证最终挂载内容。凭据不会写入仓库。

完整产品、界面与架构说明见 [`docs/产品与技术规划.md`](docs/产品与技术规划.md)。项目采用 [MIT 许可证](LICENSE)。
