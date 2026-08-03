# Repository Guidelines

## Project layout

- `App/SimulatorSlimmer`: SwiftUI macOS application.
- `App/SimulatorSlimmerMenuHelper`: lightweight menu bar helper.
- `Sources/SimulatorSlimmerCore`: reusable simulator, service, storage, and safety logic.
- `Tests/SimulatorSlimmerCoreTests`: unit, contract, fixture, and opt-in integration tests.
- `scripts`: release, signing, notarization, packaging, and smoke-test scripts.

## Working rules

- Keep Git commit subjects in English and follow the existing Conventional Commits style.
- Preserve the current Swift 6 concurrency model and two-space Swift indentation.
- Reuse existing core types and safety checks before adding new abstractions.
- Keep user-facing text in `Localizable.xcstrings`; the current interface language is Simplified Chinese.
- Do not copy or vendor code, UI, branding, copy, or assets from third-party projects.
- Do not commit credentials, signing keys, build output, DMGs, ZIP files, or local Xcode state.
- Publish releases only through GitHub Releases; do not add a separate download host.

## Safety invariants

- Do not use private `CoreSimulator.framework` APIs or require administrator privileges.
- Do not silently boot, erase, delete, or mutate a simulator.
- Keep preview validation, one-time confirmation, per-device serialization, receipts, and interruption recovery intact.
- Keep unsupported runtimes read-only.
- Require shut-down devices for storage cleanup and preserve path, identity, and symbolic-link checks.

## Validation

Run the smallest relevant checks, then expand when the touched area requires it:

```bash
swift test
```

For app or Xcode project changes:

```bash
xcodebuild \
  -project SimulatorSlimmer.xcodeproj \
  -scheme SimulatorSlimmer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For release-script changes:

```bash
scripts/test-release-scripts.sh
```

Release tags use `v<MARKETING_VERSION>`. Keep `CFBundleVersion` increasing because Sparkle uses it to order updates.

Never run destructive integration tests against a developer's everyday simulator. Use `SIMULATOR_SLIMMER_INTEGRATION_UDID` only with a dedicated disposable device.
