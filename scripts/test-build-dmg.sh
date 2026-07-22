#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/mkdir -p "$repo_root/.build"
tmp_dir="$(/usr/bin/mktemp -d "$repo_root/.build/dmg-script-test.XXXXXX")"
trap '/bin/rm -rf -- "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
/bin/mkdir -p "$fake_bin"
command_log="$tmp_dir/commands.log"
notary_count="$tmp_dir/notary-count"
: > "$command_log"
: > "$notary_count"

cat > "$fake_bin/build-release-app" <<'FAKE_BUILD'
#!/usr/bin/env bash
set -euo pipefail
printf 'build-release %s\n' "$*" >> "$COMMAND_LOG"
if [[ " $* " != *" --release-developer-id "* || " $* " != *" --clean "* || " $* " != *" --skip-zip "* ]]; then
  echo "Release 构建参数不完整。" >&2
  exit 1
fi
if [[ "${SIMULATOR_SLIMMER_SCRIPT_TESTING:-}" != "1" ]]; then
  echo "测试模式未传递给 Release 构建脚本。" >&2
  exit 1
fi
if [[ "${DEVELOPER_ID_APPLICATION:-}" != 'Developer ID Application: 测试签名 (TESTTEAM01)' || "${DEVELOPMENT_TEAM:-}" != "TESTTEAM01" ]]; then
  echo "Release 构建缺少预期的 Developer ID 参数。" >&2
  exit 1
fi
if [[ -n "${APP_STORE_API_KEY_ID+x}${APP_STORE_API_ISSUER_ID+x}${APP_STORE_API_KEY_FILEPATH+x}" ]]; then
  echo "Release 构建不应继承公证私钥信息。" >&2
  exit 1
fi

app="$SIMULATOR_SLIMMER_DIST_DIR/SimulatorSlimmer.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.neolabsapp.simulatorslimmer</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
PLIST
: > "$app/Contents/MacOS/SimulatorSlimmer"
chmod +x "$app/Contents/MacOS/SimulatorSlimmer"
FAKE_BUILD

cat > "$fake_bin/ditto" <<'FAKE_DITTO'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "$COMMAND_LOG"
if [[ " $* " == *" -c "* ]]; then
  : > "${!#}"
else
  cp -R "$1" "$2"
fi
FAKE_DITTO

cat > "$fake_bin/notarytool" <<'FAKE_NOTARY'
#!/usr/bin/env bash
set -euo pipefail
printf 'notarytool %s\n' "$*" >> "$COMMAND_LOG"
if [[ "$1" == "log" ]]; then
  printf '{"issues":[{"message":"模拟公证失败"}]}\n'
  exit 0
fi
count="$(cat "$NOTARY_COUNT")"
count="${count:-0}"
count=$((count + 1))
printf '%s' "$count" > "$NOTARY_COUNT"
status="Accepted"
if [[ "${FAKE_NOTARY_FAIL_ON:-0}" == "$count" ]]; then
  status="Invalid"
fi
printf '{"id":"submission-%s","status":"%s"}\n' "$count" "$status"
FAKE_NOTARY

for command_name in stapler codesign spctl; do
  cat > "$fake_bin/$command_name" <<'FAKE_LOGGER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "$COMMAND_LOG"
FAKE_LOGGER
done

cat > "$fake_bin/create-dmg" <<'FAKE_CREATE_DMG'
#!/usr/bin/env bash
set -euo pipefail
printf 'create-dmg %s\n' "$*" >> "$COMMAND_LOG"
arguments=("$@")
target_index=$((${#arguments[@]} - 2))
: > "${arguments[$target_index]}"
exit "${FAKE_CREATE_DMG_STATUS:-0}"
FAKE_CREATE_DMG

cat > "$fake_bin/hdiutil" <<'FAKE_HDIUTIL'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "$COMMAND_LOG"
case "$1" in
  attach)
    mountpoint="${!#}"
    mkdir -p "$mountpoint"
    cp -R "$FAKE_APP_SOURCE" "$mountpoint/SimulatorSlimmer.app"
    if [[ "${FAKE_MOUNT_REMOVE_EXECUTABLE:-0}" == "1" ]]; then
      rm -f "$mountpoint/SimulatorSlimmer.app/Contents/MacOS/SimulatorSlimmer"
    fi
    ;;
  detach)
    if [[ "${FAKE_DETACH_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    target="$2"
    if [[ "$2" == "-force" ]]; then
      target="$3"
    fi
    rm -rf "$target"
    ;;
  verify)
    ;;
esac
FAKE_HDIUTIL
/bin/chmod +x "$fake_bin"/*

api_key="$tmp_dir/AuthKey_TESTKEY123.p8"
: > "$api_key"
/bin/chmod 600 "$api_key"

run_script() {
  local build_root="$1"
  local dist_dir="$2"
  shift 2
  COMMAND_LOG="$command_log" \
    NOTARY_COUNT="$notary_count" \
    FAKE_NOTARY_FAIL_ON="${FAKE_NOTARY_FAIL_ON:-0}" \
    FAKE_CREATE_DMG_STATUS="${FAKE_CREATE_DMG_STATUS:-0}" \
    FAKE_MOUNT_REMOVE_EXECUTABLE="${FAKE_MOUNT_REMOVE_EXECUTABLE:-0}" \
    FAKE_DETACH_FAIL="${FAKE_DETACH_FAIL:-0}" \
    FAKE_APP_SOURCE="$dist_dir/SimulatorSlimmer.app" \
    SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
    SIMULATOR_SLIMMER_DMG_BUILD_ROOT="$build_root" \
    SIMULATOR_SLIMMER_DMG_DIST_DIR="$dist_dir" \
    BUILD_RELEASE_APP="$fake_bin/build-release-app" \
    DITTO="$fake_bin/ditto" \
    NOTARYTOOL="$fake_bin/notarytool" \
    STAPLER="$fake_bin/stapler" \
    CREATE_DMG="$fake_bin/create-dmg" \
    CODESIGN="$fake_bin/codesign" \
    SPCTL="$fake_bin/spctl" \
    HDIUTIL="$fake_bin/hdiutil" \
    DEVELOPER_ID_APPLICATION='Developer ID Application: 测试签名 (TESTTEAM01)' \
    DEVELOPMENT_TEAM=TESTTEAM01 \
    APP_STORE_API_KEY_ID=TESTKEY123 \
    APP_STORE_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
    APP_STORE_API_KEY_FILEPATH="${TEST_API_KEY_PATH:-$api_key}" \
    "$repo_root/scripts/build-dmg.sh" "$@"
}

success_root="$tmp_dir/success-root"
success_dist="$tmp_dir/success-dist"
success_output="$(run_script "$success_root" "$success_dist")"
test -f "$success_dist/SimulatorSlimmer-0.1.0.dmg"
test "$(cat "$notary_count")" = "2"
/usr/bin/grep -Fq 'build-release --release-developer-id --clean --skip-zip' "$command_log"
/usr/bin/grep -Fq 'notarytool submit' "$command_log"
if [[ "$(/usr/bin/grep -Fc 'stapler staple' "$command_log")" -ne 2 ]]; then
  echo "App 和 DMG 都必须执行 staple。" >&2
  exit 1
fi
if [[ "$(/usr/bin/grep -Fc 'stapler validate' "$command_log")" -lt 3 ]]; then
  echo "必须验证 App、DMG 以及挂载后的 App staple。" >&2
  exit 1
fi
/usr/bin/grep -Fq 'codesign --force --sign Developer ID Application: 测试签名 (TESTTEAM01) --timestamp' "$command_log"
if /usr/bin/grep -F 'codesign --force' "$command_log" | /usr/bin/grep -Fq -- '--deep'; then
  echo "DMG 签名不应使用 --deep。" >&2
  exit 1
fi
/usr/bin/grep -Fq 'hdiutil verify' "$command_log"
/usr/bin/grep -Fq 'spctl --assess --type open --context context:primary-signature' "$command_log"
test ! -d "$success_root"
/usr/bin/grep -Fq 'App submission ID：submission-1' <<<"$success_output"
/usr/bin/grep -Fq 'DMG submission ID：submission-2' <<<"$success_output"
echo "build-dmg 完整成功链路测试通过。"

: > "$command_log"
: > "$notary_count"
failure_root="$tmp_dir/notary-failure-root"
failure_dist="$tmp_dir/notary-failure-dist"
if FAKE_NOTARY_FAIL_ON=2 run_script "$failure_root" "$failure_dist" \
  >"$tmp_dir/notary-failure.out" 2>&1; then
  echo "DMG 公证失败时脚本不应成功。" >&2
  exit 1
fi
/usr/bin/grep -Fq 'notarytool log submission-2' "$command_log"
/usr/bin/grep -Fq '模拟公证失败' "$tmp_dir/notary-failure.out"
test ! -e "$failure_dist/SimulatorSlimmer-0.1.0.dmg"
test ! -d "$failure_root"
echo "build-dmg 公证失败处理测试通过。"

: > "$command_log"
: > "$notary_count"
mount_failure_root="$tmp_dir/mount-failure-root"
mount_failure_dist="$tmp_dir/mount-failure-dist"
if FAKE_MOUNT_REMOVE_EXECUTABLE=1 run_script "$mount_failure_root" "$mount_failure_dist" \
  >"$tmp_dir/mount-failure.out" 2>&1; then
  echo "DMG 内 App 结构损坏时脚本不应成功。" >&2
  exit 1
fi
/usr/bin/grep -Fq 'hdiutil detach' "$command_log"
test ! -d "$mount_failure_root"
echo "build-dmg 异常时卸载和清理测试通过。"

: > "$command_log"
: > "$notary_count"
detach_failure_root="$tmp_dir/detach-failure-root"
detach_failure_dist="$tmp_dir/detach-failure-dist"
if FAKE_DETACH_FAIL=1 run_script "$detach_failure_root" "$detach_failure_dist" \
  >"$tmp_dir/detach-failure.out" 2>&1; then
  echo "DMG 无法卸载时脚本不应成功。" >&2
  exit 1
fi
/usr/bin/grep -Fq '已保留构建目录供人工处理' "$tmp_dir/detach-failure.out"
test -d "$detach_failure_root"
if [[ "$(/usr/bin/grep -Fc 'hdiutil detach' "$command_log")" -lt 4 ]]; then
  echo "卸载失败时应在主流程和 trap 中分别尝试普通及强制卸载。" >&2
  exit 1
fi
echo "build-dmg 无法卸载时保留现场测试通过。"

bad_permissions_key="$tmp_dir/AuthKey_BADMODE.p8"
: > "$bad_permissions_key"
/bin/chmod 644 "$bad_permissions_key"
if TEST_API_KEY_PATH="$bad_permissions_key" \
  run_script "$tmp_dir/bad-mode-root" "$tmp_dir/bad-mode-dist" \
  >"$tmp_dir/bad-mode.out" 2>&1; then
  echo "权限过宽的 P8 不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '权限必须为 400 或 600' "$tmp_dir/bad-mode.out"

symlink_key="$tmp_dir/AuthKey_SYMLINK.p8"
/bin/ln -s "$api_key" "$symlink_key"
if TEST_API_KEY_PATH="$symlink_key" \
  run_script "$tmp_dir/symlink-key-root" "$tmp_dir/symlink-key-dist" \
  >"$tmp_dir/symlink-key.out" 2>&1; then
  echo "符号链接 P8 不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '不允许使用符号链接' "$tmp_dir/symlink-key.out"

if TEST_API_KEY_PATH=AuthKey_RELATIVE.p8 \
  run_script "$tmp_dir/relative-key-root" "$tmp_dir/relative-key-dist" \
  >"$tmp_dir/relative-key.out" 2>&1; then
  echo "相对路径 P8 不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '必须是绝对路径' "$tmp_dir/relative-key.out"
echo "build-dmg P8 路径、权限和符号链接测试通过。"

/bin/mkdir -p "$tmp_dir/victim"
: > "$tmp_dir/victim/sentinel"
if run_script "$tmp_dir/safe-zone/../victim" "$tmp_dir/unsafe-root-dist" \
  >"$tmp_dir/unsafe-root.out" 2>&1; then
  echo "包含 .. 的临时目录不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '包含不安全的路径组件' "$tmp_dir/unsafe-root.out"
test -f "$tmp_dir/victim/sentinel"
echo "build-dmg 临时目录拒绝清理未验证路径测试通过。"

if CODESIGN="$fake_bin/codesign" \
  "$repo_root/scripts/build-dmg.sh" >"$tmp_dir/non-testing-override.out" 2>&1; then
  echo "正式模式不应接受命令覆盖。" >&2
  exit 1
fi
/usr/bin/grep -Fq '覆盖只能在脚本测试模式使用' "$tmp_dir/non-testing-override.out"
echo "build-dmg 正式命令固定测试通过。"
