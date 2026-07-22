# Simulator Slimmer

Simulator Slimmer 是一款原生 macOS SwiftUI 工具，用于观察、精简和恢复 iOS Simulator 的后台服务，并安全管理模拟器存储。

## 开发环境

- macOS 14 或更高版本
- Xcode 26.5 或兼容版本
- Swift 6

## 验证

```bash
swift test
xcodebuild \
  -project SimulatorSlimmer.xcodeproj \
  -scheme SimulatorSlimmer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

完整产品与架构规划见 [`docs/产品与技术规划.md`](docs/产品与技术规划.md)。
