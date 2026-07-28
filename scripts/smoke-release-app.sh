#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

script_testing="${SIMULATOR_SLIMMER_SCRIPT_TESTING:-0}"
if [[ "$script_testing" != "0" && "$script_testing" != "1" ]]; then
  echo "SIMULATOR_SLIMMER_SCRIPT_TESTING 只接受 0 或 1。" >&2
  exit 2
fi

if [[ "$script_testing" != "1" ]]; then
  if [[ -n "${OPEN+x}${PGREP+x}${KILL+x}${PLUTIL+x}${SWIFT+x}${WINDOW_CHECK+x}${SIMULATOR_SLIMMER_RELEASE_APP_PATH+x}" ]]; then
    echo "命令和 App 路径覆盖只能在脚本测试模式使用；正式烟测固定使用受信系统命令。" >&2
    exit 2
  fi
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  open_cmd="/usr/bin/open"
  pgrep_cmd="/usr/bin/pgrep"
  kill_cmd="/bin/kill"
  plutil_cmd="/usr/bin/plutil"
  swift_cmd="/usr/bin/swift"
  window_check_cmd=""
  app_path="$repo_root/dist/SimulatorSlimmer.app"
else
  open_cmd="${OPEN:-/usr/bin/open}"
  pgrep_cmd="${PGREP:-/usr/bin/pgrep}"
  kill_cmd="${KILL:-/bin/kill}"
  plutil_cmd="${PLUTIL:-/usr/bin/plutil}"
  swift_cmd="${SWIFT:-/usr/bin/swift}"
  window_check_cmd="${WINDOW_CHECK:-}"
  app_path="${SIMULATOR_SLIMMER_RELEASE_APP_PATH:-$repo_root/dist/SimulatorSlimmer.app}"
fi

bundle_id="com.neolabsapp.simulatorslimmer"
process_name="SimulatorSlimmer"
helper_process_name="SimulatorSlimmerMenu"
timeout_seconds=10
keep_running=0
min_window_width=920
min_window_height=620
launched_pid=""
launched_helper_pid=""

usage() {
  cat <<'USAGE'
用法：scripts/smoke-release-app.sh [选项]

验证导出的 SimulatorSlimmer.app 能脱离 Xcode 启动，并显示可见主窗口。

选项：
  --app <path>                       指定要测试的 .app，默认 dist/SimulatorSlimmer.app
  --timeout <sec>                    等待进程和窗口的秒数，默认 10
  --min-window-size <width>x<height> 主窗口最小可见尺寸，默认 920x620
  --keep-running                     验证后保留本次启动的 App 进程
  -h, --help                         显示帮助

脚本测试模式：
  SIMULATOR_SLIMMER_SCRIPT_TESTING=1 时才允许通过 OPEN、PGREP、KILL、
  PLUTIL、SWIFT、WINDOW_CHECK 和 SIMULATOR_SLIMMER_RELEASE_APP_PATH
  注入测试替身。正式模式固定使用系统命令。
USAGE
}

while (($# > 0)); do
  case "$1" in
    --app)
      if (($# < 2)); then
        echo "--app 需要路径参数。" >&2
        exit 2
      fi
      app_path="$2"
      shift 2
      ;;
    --timeout)
      if (($# < 2)) || ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "--timeout 需要大于 0 的整数秒数。" >&2
        exit 2
      fi
      timeout_seconds="$2"
      shift 2
      ;;
    --min-window-size)
      if (($# < 2)) || ! [[ "$2" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        echo "--min-window-size 需要形如 920x620 的尺寸。" >&2
        exit 2
      fi
      min_window_width="${BASH_REMATCH[1]}"
      min_window_height="${BASH_REMATCH[2]}"
      if ((min_window_width < 1 || min_window_height < 1)); then
        echo "--min-window-size 的宽高必须大于 0。" >&2
        exit 2
      fi
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知选项：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

section() {
  echo
  echo "== $1 =="
}

require_executable() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" || ! -x "$path" ]]; then
    echo "$label 不存在或不可执行：${path:-未找到}" >&2
    exit 1
  fi
}

cleanup() {
  if [[ "$keep_running" == "0" ]]; then
    if [[ -n "$launched_pid" ]]; then
      "$kill_cmd" "$launched_pid" 2>/dev/null || true
      launched_pid=""
    fi
    if [[ -n "$launched_helper_pid" ]]; then
      "$kill_cmd" "$launched_helper_pid" 2>/dev/null || true
      launched_helper_pid=""
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

find_new_pid() {
  local existing_pids="$1"
  local current_pids="$2"
  local pid=""

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! /usr/bin/grep -qx "$pid" <<<"$existing_pids"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done <<<"$current_pids"
  return 1
}

wait_for_main_window() {
  local pid="$1"
  local timeout="$2"
  local min_width="$3"
  local min_height="$4"

  if [[ -n "$window_check_cmd" ]]; then
    "$window_check_cmd" "$process_name" "$pid" "$timeout" "$min_width" "$min_height"
    return
  fi

  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if WINDOW_OWNER_PID="$pid" WINDOW_MIN_WIDTH="$min_width" WINDOW_MIN_HEIGHT="$min_height" \
      "$swift_cmd" -e 'import CoreGraphics
import Darwin
import Foundation

guard let pidText = ProcessInfo.processInfo.environment["WINDOW_OWNER_PID"],
      let expectedPID = Int(pidText),
      let minWidthText = ProcessInfo.processInfo.environment["WINDOW_MIN_WIDTH"],
      let minHeightText = ProcessInfo.processInfo.environment["WINDOW_MIN_HEIGHT"],
      let minWidth = Double(minWidthText),
      let minHeight = Double(minHeightText),
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
else {
    exit(1)
}

let hasVisibleWindow = windows.contains { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == expectedPID,
          let layer = window[kCGWindowLayer as String] as? Int,
          layer == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double
    else {
        return false
    }
    return width >= minWidth && height >= minHeight
}

exit(hasVisibleWindow ? 0 : 1)' >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.5
  done
  return 1
}

read_required_plist_value() {
  local key="$1"
  local label="$2"
  local value=""
  if ! value="$("$plutil_cmd" -extract "$key" raw -o - "$info_plist" 2>/dev/null)"; then
    echo "Info.plist 缺少 ${label}：${key}" >&2
    exit 2
  fi
  if [[ -z "$value" ]]; then
    echo "Info.plist 的 $label 为空：$key" >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

section "Release App 检查"
require_executable "$open_cmd" "open"
require_executable "$pgrep_cmd" "pgrep"
require_executable "$kill_cmd" "kill"
require_executable "$plutil_cmd" "plutil"
if [[ -n "$window_check_cmd" ]]; then
  require_executable "$window_check_cmd" "窗口检查命令"
else
  require_executable "$swift_cmd" "swift"
fi
if [[ ! -d "$app_path" ]]; then
  echo "未找到 App：${app_path}。请先运行 scripts/build-release-app.sh。" >&2
  exit 2
fi
info_plist="$app_path/Contents/Info.plist"
main_executable="$app_path/Contents/MacOS/SimulatorSlimmer"
helper_executable="$app_path/Contents/Helpers/SimulatorSlimmerMenu.app/Contents/MacOS/SimulatorSlimmerMenu"
if [[ ! -f "$info_plist" || ! -x "$main_executable" || ! -x "$helper_executable" ]]; then
  echo "App 结构不完整：$app_path" >&2
  exit 2
fi

actual_bundle_id="$(read_required_plist_value CFBundleIdentifier "Bundle ID")"
if [[ "$actual_bundle_id" != "$bundle_id" ]]; then
  echo "Bundle ID 不匹配：期望 ${bundle_id}，实际 ${actual_bundle_id}" >&2
  exit 2
fi
short_version="$(read_required_plist_value CFBundleShortVersionString "版本号")"
build_version="$(read_required_plist_value CFBundleVersion "构建号")"
echo "App：$app_path"
echo "Bundle ID：$actual_bundle_id"
echo "版本：$short_version ($build_version)"

section "启动检查"
existing_pids="$("$pgrep_cmd" -x "$process_name" 2>/dev/null || true)"
existing_helper_pids="$("$pgrep_cmd" -x "$helper_process_name" 2>/dev/null || true)"
if [[ -n "$existing_pids" ]]; then
  echo "检测到既有 $process_name 进程；本次烟测只清理新启动进程。"
fi
"$open_cmd" -n "$app_path"

deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
  current_pids="$("$pgrep_cmd" -x "$process_name" 2>/dev/null || true)"
  if launched_pid="$(find_new_pid "$existing_pids" "$current_pids")"; then
    break
  fi
  /bin/sleep 0.5
done

if [[ -z "$launched_pid" ]]; then
  echo "App 未在 ${timeout_seconds}s 内启动进程：$process_name" >&2
  exit 2
fi
echo "已启动 ${process_name}，PID：${launched_pid}"

helper_deadline=$((SECONDS + 2))
while ((SECONDS < helper_deadline)); do
  current_helper_pids="$("$pgrep_cmd" -x "$helper_process_name" 2>/dev/null || true)"
  if launched_helper_pid="$(find_new_pid "$existing_helper_pids" "$current_helper_pids")"; then
    echo "已启动菜单 Helper，PID：${launched_helper_pid}"
    break
  fi
  /bin/sleep 0.2
done

if wait_for_main_window "$launched_pid" "$timeout_seconds" "$min_window_width" "$min_window_height"; then
  echo "主窗口已显示，最小尺寸 ${min_window_width}x${min_window_height}。"
else
  echo "App 未在 ${timeout_seconds}s 内显示满足 ${min_window_width}x${min_window_height} 的主窗口。" >&2
  exit 2
fi

section "清理"
if ((keep_running == 0)); then
  "$kill_cmd" "$launched_pid" 2>/dev/null || true
  echo "已结束烟测进程：$launched_pid"
  launched_pid=""
  if [[ -n "$launched_helper_pid" ]]; then
    "$kill_cmd" "$launched_helper_pid" 2>/dev/null || true
    echo "已结束菜单 Helper：$launched_helper_pid"
    launched_helper_pid=""
  fi
else
  echo "已保留烟测进程：$launched_pid"
  if [[ -n "$launched_helper_pid" ]]; then
    echo "已保留菜单 Helper：$launched_helper_pid"
  fi
  launched_pid=""
  launched_helper_pid=""
fi

section "结果"
echo "Release App 启动烟测通过。"
