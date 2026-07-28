#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/mkdir -p "$repo_root/.build"
tmp_dir="$(/usr/bin/mktemp -d "$repo_root/.build/release-smoke-script-test.XXXXXX")"
trap '/bin/rm -rf -- "$tmp_dir"' EXIT

fake_app="$tmp_dir/SimulatorSlimmer.app"
/bin/mkdir -p "$fake_app/Contents/MacOS" "$fake_app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS"
cat > "$fake_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.neolabsapp.simulatorslimmer</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
PLIST
: > "$fake_app/Contents/MacOS/SimulatorSlimmer"
/bin/chmod +x "$fake_app/Contents/MacOS/SimulatorSlimmer"
: > "$fake_app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
/bin/chmod +x "$fake_app/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"

fake_open="$tmp_dir/open"
fake_pgrep="$tmp_dir/pgrep"
fake_kill="$tmp_dir/kill"
fake_window_check="$tmp_dir/window-check"
open_log="$tmp_dir/open.log"
pgrep_log="$tmp_dir/pgrep.log"
kill_log="$tmp_dir/kill.log"
window_check_log="$tmp_dir/window-check.log"
pgrep_state="$tmp_dir/pgrep-state"
helper_pgrep_state="$tmp_dir/helper-pgrep-state"

cat > "$fake_open" <<'FAKE_OPEN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$OPEN_LOG"
FAKE_OPEN

write_default_pgrep() {
  cat > "$fake_pgrep" <<'FAKE_PGREP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PGREP_LOG"
if [[ "${!#}" == "SimulatorSlimmerMenu" ]]; then
  count=0
  if [[ -f "$HELPER_PGREP_STATE" ]]; then
    count="$(cat "$HELPER_PGREP_STATE")"
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$HELPER_PGREP_STATE"
  if ((count >= 2)); then
    echo "54321"
  fi
  exit 0
fi
count=0
if [[ -f "$PGREP_STATE" ]]; then
  count="$(cat "$PGREP_STATE")"
fi
count=$((count + 1))
printf '%s' "$count" > "$PGREP_STATE"
if ((count >= 2)); then
  echo "43210"
fi
FAKE_PGREP
}
write_default_pgrep

cat > "$fake_kill" <<'FAKE_KILL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$KILL_LOG"
FAKE_KILL

cat > "$fake_window_check" <<'FAKE_WINDOW'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WINDOW_CHECK_LOG"
if [[ "${FAKE_WINDOW_FAIL:-0}" == "1" ]]; then
  exit 1
fi
FAKE_WINDOW
/bin/chmod +x "$fake_open" "$fake_pgrep" "$fake_kill" "$fake_window_check"

reset_logs() {
  /bin/rm -f "$open_log" "$pgrep_log" "$kill_log" "$window_check_log" "$pgrep_state" "$helper_pgrep_state"
}

run_smoke() {
  OPEN_LOG="$open_log" \
    PGREP_LOG="$pgrep_log" \
    KILL_LOG="$kill_log" \
    WINDOW_CHECK_LOG="$window_check_log" \
    PGREP_STATE="$pgrep_state" \
    HELPER_PGREP_STATE="$helper_pgrep_state" \
    FAKE_WINDOW_FAIL="${FAKE_WINDOW_FAIL:-0}" \
    OPEN="$fake_open" \
    PGREP="$fake_pgrep" \
    KILL="$fake_kill" \
    WINDOW_CHECK="$fake_window_check" \
    SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
    SIMULATOR_SLIMMER_RELEASE_APP_PATH="$fake_app" \
    "$repo_root/scripts/smoke-release-app.sh" "$@"
}

reset_logs
output="$(run_smoke)"
/usr/bin/grep -Fq -- "-n $fake_app" "$open_log"
/usr/bin/grep -Fq -- '-x SimulatorSlimmer' "$pgrep_log"
/usr/bin/grep -Fq -- '-x SimulatorSlimmerMenu' "$pgrep_log"
/usr/bin/grep -Fq 'SimulatorSlimmer 43210 10 920 620' "$window_check_log"
/usr/bin/grep -Fq '43210' "$kill_log"
/usr/bin/grep -Fq '54321' "$kill_log"
/usr/bin/grep -Fq '版本：0.1.0 (7)' <<<"$output"
/usr/bin/grep -Fq '主窗口已显示' <<<"$output"
/usr/bin/grep -Fq 'Release App 启动烟测通过' <<<"$output"
echo "smoke-release-app 默认启动链路测试通过。"

reset_logs
write_default_pgrep
/bin/chmod +x "$fake_pgrep"
custom_output="$(run_smoke --timeout 3 --min-window-size 900x640)"
/usr/bin/grep -Fq 'SimulatorSlimmer 43210 3 900 640' "$window_check_log"
/usr/bin/grep -Fq '最小尺寸 900x640' <<<"$custom_output"
echo "smoke-release-app 自定义窗口与超时参数测试通过。"

reset_logs
cat > "$fake_pgrep" <<'FAKE_PGREP_EXISTING'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PGREP_LOG"
if [[ "${!#}" == "SimulatorSlimmerMenu" ]]; then
  count=0
  if [[ -f "$HELPER_PGREP_STATE" ]]; then
    count="$(cat "$HELPER_PGREP_STATE")"
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$HELPER_PGREP_STATE"
  if ((count >= 2)); then
    echo "54321"
  fi
  exit 0
fi
count=0
if [[ -f "$PGREP_STATE" ]]; then
  count="$(cat "$PGREP_STATE")"
fi
count=$((count + 1))
printf '%s' "$count" > "$PGREP_STATE"
if ((count == 1)); then
  echo "11111"
else
  printf '11111\n43210\n'
fi
FAKE_PGREP_EXISTING
/bin/chmod +x "$fake_pgrep"
existing_output="$(run_smoke)"
if /usr/bin/grep -Fq '11111' "$kill_log"; then
  echo "烟测不应清理启动前已经存在的进程。" >&2
  exit 1
fi
/usr/bin/grep -Fq '43210' "$kill_log"
/usr/bin/grep -Fq '检测到既有 SimulatorSlimmer 进程' <<<"$existing_output"
echo "smoke-release-app 既有进程保护测试通过。"

reset_logs
write_default_pgrep
/bin/chmod +x "$fake_pgrep"
run_smoke --keep-running >"$tmp_dir/keep-running.out"
if [[ -e "$kill_log" && -s "$kill_log" ]]; then
  echo "--keep-running 不应结束本次启动的进程。" >&2
  exit 1
fi
/usr/bin/grep -Fq '已保留烟测进程：43210' "$tmp_dir/keep-running.out"
echo "smoke-release-app 保留进程测试通过。"

reset_logs
write_default_pgrep
/bin/chmod +x "$fake_pgrep"
if FAKE_WINDOW_FAIL=1 run_smoke >"$tmp_dir/window-failure.out" 2>&1; then
  echo "主窗口检查失败时烟测不应成功。" >&2
  exit 1
fi
/usr/bin/grep -Fq '43210' "$kill_log"
/usr/bin/grep -Fq '未在 10s 内显示' "$tmp_dir/window-failure.out"
echo "smoke-release-app 失败时 trap 清理测试通过。"

if OPEN="$fake_open" \
  "$repo_root/scripts/smoke-release-app.sh" >"$tmp_dir/non-testing-override.out" 2>&1; then
  echo "正式模式不应接受命令覆盖。" >&2
  exit 1
fi
/usr/bin/grep -Fq '覆盖只能在脚本测试模式使用' "$tmp_dir/non-testing-override.out"

if run_smoke --min-window-size 0x520 >"$tmp_dir/invalid-size.out" 2>&1; then
  echo "零宽度主窗口约束不应被接受。" >&2
  exit 1
fi
/usr/bin/grep -Fq '宽高必须大于 0' "$tmp_dir/invalid-size.out"
echo "smoke-release-app 正式命令与参数校验测试通过。"
