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
  if [[ -n "${XCODEBUILD+x}${DITTO+x}${CODESIGN+x}${SIMULATOR_SLIMMER_DERIVED_DATA_PATH+x}${SIMULATOR_SLIMMER_DIST_DIR+x}" ]]; then
    echo "命令和输出路径覆盖只能在脚本测试模式使用；正式构建固定使用受信命令和仓库输出目录。" >&2
    exit 2
  fi
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  xcodebuild_cmd="/usr/bin/xcodebuild"
  ditto_cmd="/usr/bin/ditto"
  codesign_cmd="/usr/bin/codesign"
  derived_data_path="$repo_root/.build/release-app"
  dist_dir="$repo_root/dist"
else
  xcodebuild_cmd="${XCODEBUILD:-/usr/bin/xcodebuild}"
  ditto_cmd="${DITTO:-/usr/bin/ditto}"
  codesign_cmd="${CODESIGN:-/usr/bin/codesign}"
  derived_data_path="${SIMULATOR_SLIMMER_DERIVED_DATA_PATH:-$repo_root/.build/release-app}"
  dist_dir="${SIMULATOR_SLIMMER_DIST_DIR:-$repo_root/dist}"
fi

project="$repo_root/SimulatorSlimmer.xcodeproj"
scheme="SimulatorSlimmer"
app_name="SimulatorSlimmer.app"
bundle_id="com.neolabsapp.simulatorslimmer"
mode="debug"
configuration="Debug"
developer_id_application="${DEVELOPER_ID_APPLICATION:-}"
development_team="${DEVELOPMENT_TEAM:-}"
skip_zip=0
clean=0
temporary_app=""

usage() {
  cat <<'USAGE'
用法：scripts/build-release-app.sh [选项]

构建并导出 Simulator Slimmer macOS App。默认生成无需发布证书的 Debug 未签名版本。

模式：
  --debug-unsigned        构建 Debug 未签名版本（默认）
  --release-developer-id 构建 Developer ID 签名的 Release 版本

选项：
  --clean                 构建前清理 DerivedData 和对应旧产物
  --skip-zip              只输出 .app，不生成 zip
  -h, --help              显示帮助

输出：
  dist/SimulatorSlimmer.app
  dist/SimulatorSlimmer-Debug-macOS.zip   Debug 模式
  dist/SimulatorSlimmer-macOS.zip         Release 模式

Release 模式必需环境变量：
  DEVELOPER_ID_APPLICATION  完整的 Developer ID Application 签名身份
  DEVELOPMENT_TEAM          Apple Developer Team ID

脚本测试模式：
  SIMULATOR_SLIMMER_SCRIPT_TESTING=1 时，才允许通过 XCODEBUILD、DITTO、
  CODESIGN、SIMULATOR_SLIMMER_DERIVED_DATA_PATH 和
  SIMULATOR_SLIMMER_DIST_DIR 注入测试替身。正式模式拒绝这些覆盖。
USAGE
}

while (($# > 0)); do
  case "$1" in
    --debug-unsigned)
      mode="debug"
      configuration="Debug"
      shift
      ;;
    --release-developer-id)
      mode="release"
      configuration="Release"
      shift
      ;;
    --clean)
      clean=1
      shift
      ;;
    --skip-zip)
      skip_zip=1
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

require_safe_absolute_path() {
  local path="$1"
  local label="$2"
  local current="/"
  local remainder=""
  local component=""

  if [[ -z "$path" || "$path" != /* || "$path" == "/" || "$path" == */ || "$path" == "$repo_root" ]]; then
    echo "$label 不是安全的绝对路径：$path" >&2
    exit 2
  fi

  remainder="${path#/}"
  while [[ -n "$remainder" ]]; do
    if [[ "$remainder" == */* ]]; then
      component="${remainder%%/*}"
      remainder="${remainder#*/}"
    else
      component="$remainder"
      remainder=""
    fi

    case "$component" in
      ""|.|..)
        echo "$label 包含不安全的路径组件：$path" >&2
        exit 2
        ;;
    esac

    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [[ -L "$current" ]]; then
      echo "$label 路径组件不允许使用符号链接：$current" >&2
      exit 2
    fi
  done
}

cleanup() {
  if [[ -n "$temporary_app" && -e "$temporary_app" ]]; then
    /bin/rm -rf -- "$temporary_app"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

section "检查构建参数"
if [[ ! -d "$project" ]]; then
  echo "未找到 Xcode 工程：$project" >&2
  exit 1
fi
require_executable "$xcodebuild_cmd" "xcodebuild"
require_executable "$ditto_cmd" "ditto"
require_safe_absolute_path "$derived_data_path" "DerivedData 目录"
require_safe_absolute_path "$dist_dir" "发布目录"
if [[ "$derived_data_path" == "$dist_dir" || "$dist_dir" == "$derived_data_path/"* ]]; then
  echo "发布目录不能位于会被清理的 DerivedData 目录内。" >&2
  exit 2
fi

if [[ "$mode" == "release" ]]; then
  require_executable "$codesign_cmd" "codesign"
  if [[ -z "$developer_id_application" || "$developer_id_application" != "Developer ID Application:"* ]]; then
    echo "Release 模式必须提供以 Developer ID Application: 开头的 DEVELOPER_ID_APPLICATION。" >&2
    exit 2
  fi
  if [[ -z "$development_team" ]]; then
    echo "Release 模式必须提供 DEVELOPMENT_TEAM。" >&2
    exit 2
  fi
fi

zip_name="SimulatorSlimmer-Debug-macOS.zip"
if [[ "$mode" == "release" ]]; then
  zip_name="SimulatorSlimmer-macOS.zip"
fi
built_app="$derived_data_path/Build/Products/$configuration/$app_name"
output_app="$dist_dir/$app_name"
output_zip="$dist_dir/$zip_name"

if ((clean == 1)); then
  section "清理旧构建"
  /bin/rm -rf -- "$derived_data_path"
  /bin/rm -rf -- "$output_app"
  /bin/rm -f -- "$output_zip"
fi
/bin/mkdir -p "$derived_data_path" "$dist_dir"

section "构建 $configuration App"
xcode_arguments=(
  -project "$project"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "generic/platform=macOS"
  -derivedDataPath "$derived_data_path"
)

if [[ "$mode" == "debug" ]]; then
  "$xcodebuild_cmd" "${xcode_arguments[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  "$xcodebuild_cmd" "${xcode_arguments[@]}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$developer_id_application" \
    DEVELOPMENT_TEAM="$development_team" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    build
fi

if [[ ! -d "$built_app" ]]; then
  echo "构建未生成 App：$built_app" >&2
  exit 1
fi
info_plist="$built_app/Contents/Info.plist"
main_executable="$built_app/Contents/MacOS/SimulatorSlimmer"
if [[ ! -f "$info_plist" ]]; then
  echo "构建产物缺少 Info.plist：$info_plist" >&2
  exit 1
fi
if [[ ! -f "$main_executable" || ! -x "$main_executable" ]]; then
  echo "构建产物缺少可执行主程序：$main_executable" >&2
  exit 1
fi
actual_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
if [[ "$actual_bundle_id" != "$bundle_id" ]]; then
  echo "Bundle ID 不匹配：期望 ${bundle_id}，实际 ${actual_bundle_id}" >&2
  exit 1
fi
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")"
if [[ -z "$version" || -z "$build_number" ]]; then
  echo "构建产物的版本号或构建号为空。" >&2
  exit 1
fi
if [[ "$mode" == "release" ]]; then
  "$codesign_cmd" --verify --deep --strict --verbose=4 "$built_app"
fi

section "导出 App"
temporary_app="$dist_dir/.SimulatorSlimmer.app.tmp.$$"
/bin/rm -rf -- "$temporary_app"
"$ditto_cmd" "$built_app" "$temporary_app"
/bin/rm -rf -- "$output_app"
/bin/mv "$temporary_app" "$output_app"
temporary_app=""

if [[ "$mode" == "release" ]]; then
  "$codesign_cmd" --verify --deep --strict --verbose=4 "$output_app"
fi

if ((skip_zip == 0)); then
  section "生成 App zip"
  /bin/rm -f -- "$output_zip"
  "$ditto_cmd" -c -k --keepParent "$output_app" "$output_zip"
  if [[ ! -f "$output_zip" ]]; then
    echo "未生成 App zip：$output_zip" >&2
    exit 1
  fi
fi

section "App 导出完成"
echo "模式：$configuration ($([[ "$mode" == "release" ]] && echo 'Developer ID' || echo '未签名'))"
echo "版本：$version ($build_number)"
echo "App：$output_app"
if ((skip_zip == 0)); then
  echo "Zip：$output_zip"
fi
