# Simulator Slimmer

Simulator Slimmer is a native macOS app for inspecting, reducing, and restoring background services in iOS Simulator devices. It also provides guarded tools for managing simulator storage and common device operations.

The app is written in Swift and SwiftUI. Its interface is available in Simplified Chinese and English, with an in-app language selector.

> [!WARNING]
> Disabling simulator services changes system behavior. Use this app only with disposable or recoverable simulator devices, review every preview, and restore the original state when you finish testing.

## Features

- Lists installed iOS runtimes and simulator devices.
- Shows device state, managed service state, and process memory snapshots.
- Provides conservative, extreme, custom, and restore-all service profiles.
- Previews every service or storage change before execution.
- Records transaction receipts so managed services can be restored to their previous state.
- Serializes operations per device and supports interruption recovery.
- Cleans caches, logs, and temporary files only from known simulator paths.
- Starts, shuts down, reveals, erases, clones, and deletes simulator devices with explicit confirmation.
- Runs a lightweight menu bar helper independently from the main window.
- Exports diagnostic bundles for troubleshooting.

The bundled service catalog currently supports iOS 26.3.1 and iOS 26.5. Unknown or unsupported runtime versions are read-only.

## Safety model

- Uses public command-line tools instead of private `CoreSimulator.framework` APIs.
- Does not require administrator privileges or modify host macOS services.
- Never silently boots, erases, or deletes a simulator.
- Rejects stale previews, changed inputs, duplicate confirmations, and concurrent changes to the same device.
- Restores only services recorded in a transaction receipt and previously touched by Simulator Slimmer.
- Requires a shut-down device before scanning or cleaning storage.
- Rejects symbolic links, escaped paths, app bundles, and application data roots during cleanup.

## Requirements

- macOS 14 or later
- Xcode 26.5 or a compatible version
- Swift 6

## Build and test

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

Simulator integration tests are skipped by default. Run them only against a dedicated simulator that can be discarded:

```bash
SIMULATOR_SLIMMER_INTEGRATION_UDID='<disposable simulator UDID>' swift test
```

The integration test previews, applies, verifies, restores, and re-verifies service changes, then returns the device to its original power state.

## Releases and updates

Release builds target Apple Silicon and use Developer ID signing and Apple notarization. Tagged versions are published directly to [GitHub Releases](https://github.com/lvxiaohai/SimulatorSlimmer/releases).

Simulator Slimmer uses Sparkle to check the latest GitHub Release automatically. The application menu also provides **Check for Updates…**. Update archives are verified with an EdDSA signature before installation.

Validate the release scripts and build an unsigned local app with:

```bash
scripts/test-release-scripts.sh
scripts/build-release-app.sh --debug-unsigned --clean
scripts/smoke-release-app.sh
```

A notarized DMG requires a Developer ID Application certificate, `create-dmg`, and Apple notarization credentials supplied through environment variables. Creating and pushing a `v<version>` tag runs the GitHub Actions release workflow and publishes the DMG, signed update ZIP, and `appcast.xml` as GitHub Release assets. Credentials and generated artifacts must never be committed.

## Background

The background-service optimization idea was inspired in part by [simslim](https://github.com/MobAI-App/simslim). Simulator Slimmer is an independent Swift implementation.

## License

Simulator Slimmer is available under the [MIT License](LICENSE).
