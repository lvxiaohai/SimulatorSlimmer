#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/mkdir -p "$repo_root/.build"
tmp_dir="$(/usr/bin/mktemp -d "$repo_root/.build/release-app-script-test.XXXXXX")"
trap '/bin/rm -rf -- "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
/bin/mkdir -p "$fake_bin"
xcodebuild_log="$tmp_dir/xcodebuild.log"
ditto_log="$tmp_dir/ditto.log"
codesign_log="$tmp_dir/codesign.log"
strip_log="$tmp_dir/strip.log"
: > "$xcodebuild_log"
: > "$ditto_log"
: > "$codesign_log"
: > "$strip_log"

cat > "$fake_bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XCODEBUILD_LOG"

configuration=""
derived_data_path=""
current_project_version="7"
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-configuration" ]]; then
    configuration="$argument"
  elif [[ "$previous" == "-derivedDataPath" ]]; then
    derived_data_path="$argument"
  elif [[ "$argument" == CURRENT_PROJECT_VERSION=* ]]; then
    current_project_version="${argument#CURRENT_PROJECT_VERSION=}"
  fi
  previous="$argument"
done
if [[ -z "$configuration" || -z "$derived_data_path" ]]; then
  echo "测试替身未收到构建配置或 DerivedData 路径。" >&2
  exit 1
fi

app="$derived_data_path/Build/Products/$configuration/SimulatorSlimmer.app"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p \
  "$app/Contents/MacOS" \
  "$app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS" \
  "$sparkle/Updater.app/Contents/MacOS" \
  "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS" \
  "$sparkle/XPCServices/Installer.xpc/Contents/MacOS"
ln -s B "$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${FAKE_BUNDLE_ID:-com.neolabsapp.simulatorslimmer}</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$current_project_version</string>
</dict></plist>
PLIST
: > "$app/Contents/MacOS/SimulatorSlimmer"
chmod +x "$app/Contents/MacOS/SimulatorSlimmer"
: > "$app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
chmod +x "$app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
: > "$sparkle/Autoupdate"
: > "$sparkle/Updater.app/Contents/MacOS/Updater"
: > "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
: > "$sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer"
chmod +x \
  "$sparkle/Autoupdate" \
  "$sparkle/Updater.app/Contents/MacOS/Updater" \
  "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer"
if [[ "$configuration" == "Release" ]]; then
  dsym="$derived_data_path/Build/Products/$configuration/SimulatorSlimmer.app.dSYM"
  mkdir -p "$dsym/Contents/Resources/DWARF"
  : > "$dsym/Contents/Resources/DWARF/SimulatorSlimmer"
  helper_dsym="$derived_data_path/Build/Products/$configuration/SimulatorSlimmerMenu.app.dSYM"
  mkdir -p "$helper_dsym/Contents/Resources/DWARF"
  : > "$helper_dsym/Contents/Resources/DWARF/SimulatorSlimmerMenu"
fi
FAKE_XCODEBUILD

cat > "$fake_bin/ditto" <<'FAKE_DITTO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DITTO_LOG"
if [[ " $* " == *" -c "* ]]; then
  : > "${!#}"
else
  cp -R "$1" "$2"
fi
FAKE_DITTO

cat > "$fake_bin/codesign" <<'FAKE_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CODESIGN_LOG"
if [[ " $* " == *" -dvv "* ]]; then
  printf '%s\n' \
    'Authority=Developer ID Application: 测试签名 (TESTTEAM01)' \
    'Timestamp=Aug 3, 2026 at 12:00:00'
fi
FAKE_CODESIGN

cat > "$fake_bin/strip" <<'FAKE_STRIP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STRIP_LOG"
FAKE_STRIP

cat > "$fake_bin/lipo" <<'FAKE_LIPO'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != "-archs" ]]; then
  echo "测试 lipo 只支持 -archs。" >&2
  exit 1
fi
printf '%s\n' "${FAKE_ARCHS:-arm64}"
FAKE_LIPO

cat > "$fake_bin/dwarfdump" <<'FAKE_DWARFDUMP'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
uuid="${FAKE_BINARY_UUID:-11111111-2222-3333-4444-555555555555}"
if [[ "$target" == *.dSYM ]]; then
  uuid="${FAKE_DSYM_UUID:-$uuid}"
fi
printf 'UUID: %s (arm64) %s\n' "$uuid" "$target"
FAKE_DWARFDUMP
/bin/chmod +x "$fake_bin"/*

run_build() {
  local derived_data_path="$1"
  local dist_dir="$2"
  shift 2
  XCODEBUILD_LOG="$xcodebuild_log" \
    DITTO_LOG="$ditto_log" \
    CODESIGN_LOG="$codesign_log" \
    STRIP_LOG="$strip_log" \
    FAKE_BUNDLE_ID="${FAKE_BUNDLE_ID:-}" \
    FAKE_ARCHS="${FAKE_ARCHS:-arm64}" \
    FAKE_BINARY_UUID="${FAKE_BINARY_UUID:-}" \
    FAKE_DSYM_UUID="${FAKE_DSYM_UUID:-}" \
    XCODEBUILD="$fake_bin/xcodebuild" \
    DITTO="$fake_bin/ditto" \
    CODESIGN="$fake_bin/codesign" \
    STRIP="$fake_bin/strip" \
    LIPO="$fake_bin/lipo" \
    DWARFDUMP="$fake_bin/dwarfdump" \
    SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
    SIMULATOR_SLIMMER_DERIVED_DATA_PATH="$derived_data_path" \
    SIMULATOR_SLIMMER_DIST_DIR="$dist_dir" \
    "$repo_root/scripts/build-release-app.sh" "$@"
}

debug_derived="$tmp_dir/debug-derived"
debug_dist="$tmp_dir/debug-dist"
debug_output="$(run_build "$debug_derived" "$debug_dist" --debug-unsigned --clean)"
test -d "$debug_dist/SimulatorSlimmer.app"
test -x "$debug_dist/SimulatorSlimmer.app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
test -f "$debug_dist/SimulatorSlimmer-Debug-macOS.zip"
/usr/bin/grep -Fq -- '-configuration Debug' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGNING_ALLOWED=NO' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGNING_REQUIRED=NO' "$xcodebuild_log"
if [[ -s "$codesign_log" ]]; then
  echo "Debug 未签名模式不应调用 codesign。" >&2
  exit 1
fi
/usr/bin/grep -Fq '模式：Debug (未签名)' <<<"$debug_output"
/usr/bin/grep -Fq '版本：0.1.0 (7)' <<<"$debug_output"
echo "build-release-app Debug 未签名模式测试通过。"

: > "$xcodebuild_log"
: > "$ditto_log"
: > "$codesign_log"
: > "$strip_log"
release_derived="$tmp_dir/release-derived"
release_dist="$tmp_dir/release-dist"
release_output="$(
  DEVELOPER_ID_APPLICATION='Developer ID Application: 测试签名 (TESTTEAM01)' \
    DEVELOPMENT_TEAM=TESTTEAM01 \
    run_build "$release_derived" "$release_dist" --release-developer-id --clean
)"
test -d "$release_dist/SimulatorSlimmer.app"
test -x "$release_dist/SimulatorSlimmer.app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
test -f "$release_dist/SimulatorSlimmer-macOS.zip"
test -f "$release_dist/SimulatorSlimmer-0.1.0-dSYM.zip"
/usr/bin/grep -Fq -- '--keepParent' "$ditto_log"
/usr/bin/grep -Fq -- 'SimulatorSlimmer-0.1.0-dSYMs' "$ditto_log"
/usr/bin/grep -Fq -- '-configuration Release' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'ARCHS=arm64' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'ONLY_ACTIVE_ARCH=NO' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGN_STYLE=Manual' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGN_IDENTITY=Developer ID Application: 测试签名 (TESTTEAM01)' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'DEVELOPMENT_TEAM=TESTTEAM01' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGNING_ALLOWED=YES' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO' "$xcodebuild_log"
/usr/bin/grep -Fq -- 'OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime' "$xcodebuild_log"
/usr/bin/grep -Fq -- '-S -x' "$strip_log"
if [[ "$(/usr/bin/grep -Fc -- '-S -x' "$strip_log")" -ne 2 ]]; then
  echo "Release 模式应分别剥离主程序和菜单 Helper。" >&2
  exit 1
fi
/usr/bin/grep -Fq -- '--force --sign Developer ID Application: 测试签名 (TESTTEAM01) --timestamp --options runtime' "$codesign_log"
/usr/bin/grep -Fq -- '--force --sign Developer ID Application: 测试签名 (TESTTEAM01) --timestamp --options runtime --entitlements' "$codesign_log"
for target in \
  'Sparkle.framework/Versions/Current/Autoupdate' \
  'Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc' \
  'Sparkle.framework/Versions/Current/XPCServices/Installer.xpc' \
  'Sparkle.framework/Versions/Current/Updater.app' \
  'Sparkle.framework'; do
  /usr/bin/grep -Fq -- "--options runtime $release_dist/SimulatorSlimmer.app/Contents/Frameworks/$target" "$codesign_log"
done
if [[ "$(/usr/bin/grep -Fc -- '--verify --deep --strict --verbose=4' "$codesign_log")" -ne 2 ]]; then
  echo "Release 模式应校验构建目录和导出目录中的 App 签名。" >&2
  exit 1
fi
if [[ "$(/usr/bin/grep -Fc -- '--verify --strict --verbose=4' "$codesign_log")" -ne 2 ]]; then
  echo "Release 模式应校验构建目录和导出目录中的菜单 Helper 签名。" >&2
  exit 1
fi
/usr/bin/grep -Fq '模式：Release (Developer ID)' <<<"$release_output"
/usr/bin/grep -Fq 'dSYM：' <<<"$release_output"
echo "build-release-app Developer ID Release 模式测试通过。"

: > "$xcodebuild_log"
override_output="$(
  SIMULATOR_SLIMMER_BUILD_NUMBER=99 \
    DEVELOPER_ID_APPLICATION='Developer ID Application: 测试签名 (TESTTEAM01)' \
    DEVELOPMENT_TEAM=TESTTEAM01 \
    run_build "$tmp_dir/build-number-derived" "$tmp_dir/build-number-dist" \
      --release-developer-id --skip-zip
)"
/usr/bin/grep -Fq 'CURRENT_PROJECT_VERSION=99' "$xcodebuild_log"
/usr/bin/grep -Fq '版本：0.1.0 (99)' <<<"$override_output"
echo "build-release-app 构建号覆盖测试通过。"

if SIMULATOR_SLIMMER_BUILD_NUMBER=0 run_build \
  "$tmp_dir/invalid-build-derived" "$tmp_dir/invalid-build-dist" \
  >"$tmp_dir/invalid-build.out" 2>&1; then
  echo "无效构建号不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '必须是正整数' "$tmp_dir/invalid-build.out"

export FAKE_ARCHS="x86_64 arm64"
if DEVELOPER_ID_APPLICATION='Developer ID Application: 测试签名 (TESTTEAM01)' \
  DEVELOPMENT_TEAM=TESTTEAM01 \
  run_build "$tmp_dir/wrong-arch-derived" "$tmp_dir/wrong-arch-dist" \
    --release-developer-id >"$tmp_dir/wrong-arch.out" 2>&1; then
  echo "包含非 arm64 架构的 Release 不应导出。" >&2
  exit 1
fi
unset FAKE_ARCHS
/usr/bin/grep -Fq '必须仅包含 arm64' "$tmp_dir/wrong-arch.out"
echo "build-release-app Release 架构校验测试通过。"

export FAKE_DSYM_UUID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
if DEVELOPER_ID_APPLICATION='Developer ID Application: 测试签名 (TESTTEAM01)' \
  DEVELOPMENT_TEAM=TESTTEAM01 \
  run_build "$tmp_dir/wrong-dsym-derived" "$tmp_dir/wrong-dsym-dist" \
    --release-developer-id >"$tmp_dir/wrong-dsym.out" 2>&1; then
  echo "dSYM UUID 不匹配时 Release 不应导出。" >&2
  exit 1
fi
unset FAKE_DSYM_UUID
/usr/bin/grep -Fq 'dSYM 的 UUID 不匹配' "$tmp_dir/wrong-dsym.out"
echo "build-release-app dSYM 匹配校验测试通过。"

: > "$xcodebuild_log"
if run_build "$tmp_dir/missing-identity-derived" "$tmp_dir/missing-identity-dist" \
  --release-developer-id >"$tmp_dir/missing-identity.out" 2>&1; then
  echo "Release 模式缺少签名身份时不应成功。" >&2
  exit 1
fi
/usr/bin/grep -Fq 'Release 模式必须提供' "$tmp_dir/missing-identity.out"
if [[ -s "$xcodebuild_log" ]]; then
  echo "参数校验失败后不应执行 xcodebuild。" >&2
  exit 1
fi
echo "build-release-app Release 凭据校验测试通过。"

if XCODEBUILD="$fake_bin/xcodebuild" \
  "$repo_root/scripts/build-release-app.sh" --debug-unsigned >"$tmp_dir/non-testing-override.out" 2>&1; then
  echo "正式模式不应接受命令覆盖。" >&2
  exit 1
fi
/usr/bin/grep -Fq '覆盖只能在脚本测试模式使用' "$tmp_dir/non-testing-override.out"

if XCODEBUILD="$fake_bin/xcodebuild" \
  DITTO="$fake_bin/ditto" \
  CODESIGN="$fake_bin/codesign" \
  SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
  SIMULATOR_SLIMMER_DERIVED_DATA_PATH="$tmp_dir/unsafe-derived" \
  SIMULATOR_SLIMMER_DIST_DIR=/ \
  "$repo_root/scripts/build-release-app.sh" >"$tmp_dir/unsafe-path.out" 2>&1; then
  echo "不安全的发布目录不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '不是安全的绝对路径' "$tmp_dir/unsafe-path.out"
echo "build-release-app 正式命令与路径安全测试通过。"

bad_dist="$tmp_dir/bad-bundle-dist"
export FAKE_BUNDLE_ID=com.example.wrong
if run_build "$tmp_dir/bad-bundle-derived" "$bad_dist" \
  --debug-unsigned >"$tmp_dir/bad-bundle.out" 2>&1; then
  echo "Bundle ID 不匹配时不应导出 App。" >&2
  exit 1
fi
unset FAKE_BUNDLE_ID
/usr/bin/grep -Fq 'Bundle ID 不匹配' "$tmp_dir/bad-bundle.out"
test ! -e "$bad_dist/SimulatorSlimmer.app"
echo "build-release-app 产物身份校验测试通过。"
