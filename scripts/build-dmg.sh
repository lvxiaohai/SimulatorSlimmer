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
  if [[ -n "${BUILD_RELEASE_APP+x}${XCODEBUILD+x}${DITTO+x}${NOTARYTOOL+x}${STAPLER+x}${CREATE_DMG+x}${CODESIGN+x}${SPCTL+x}${HDIUTIL+x}${SIMULATOR_SLIMMER_DMG_BUILD_ROOT+x}${SIMULATOR_SLIMMER_DMG_DIST_DIR+x}${SIMULATOR_SLIMMER_DERIVED_DATA_PATH+x}${SIMULATOR_SLIMMER_DIST_DIR+x}" ]]; then
    echo "命令和输出路径覆盖只能在脚本测试模式使用；正式发布固定使用受信命令和仓库输出目录。" >&2
    exit 2
  fi
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  build_release_app_cmd="$repo_root/scripts/build-release-app.sh"
  ditto_cmd="/usr/bin/ditto"
  notarytool_cmd="$(/usr/bin/xcrun --find notarytool)"
  stapler_cmd="$(/usr/bin/xcrun --find stapler)"
  create_dmg_cmd="/opt/homebrew/bin/create-dmg"
  codesign_cmd="/usr/bin/codesign"
  spctl_cmd="/usr/sbin/spctl"
  hdiutil_cmd="/usr/bin/hdiutil"
  build_root="$repo_root/.build/dmg-release"
  dist_dir="$repo_root/dist"
else
  build_release_app_cmd="${BUILD_RELEASE_APP:-$repo_root/scripts/build-release-app.sh}"
  ditto_cmd="${DITTO:-/usr/bin/ditto}"
  notarytool_cmd="${NOTARYTOOL:-$(/usr/bin/xcrun --find notarytool)}"
  stapler_cmd="${STAPLER:-$(/usr/bin/xcrun --find stapler)}"
  create_dmg_cmd="${CREATE_DMG:-$(command -v create-dmg || true)}"
  codesign_cmd="${CODESIGN:-/usr/bin/codesign}"
  spctl_cmd="${SPCTL:-/usr/sbin/spctl}"
  hdiutil_cmd="${HDIUTIL:-/usr/bin/hdiutil}"
  build_root="${SIMULATOR_SLIMMER_DMG_BUILD_ROOT:-$repo_root/.build/dmg-release}"
  dist_dir="${SIMULATOR_SLIMMER_DMG_DIST_DIR:-$repo_root/dist}"
fi

developer_id_application="${DEVELOPER_ID_APPLICATION:-}"
development_team="${DEVELOPMENT_TEAM:-}"
api_key_id="${APP_STORE_API_KEY_ID:-}"
api_issuer_id="${APP_STORE_API_ISSUER_ID:-}"
api_key_file="${APP_STORE_API_KEY_FILEPATH:-}"
app_path="$dist_dir/SimulatorSlimmer.app"
mount_dir="$build_root/mount"
mounted=0
build_root_cleanup_allowed=0

usage() {
  cat <<'USAGE'
用法：scripts/build-dmg.sh

构建 Developer ID Release App，依次完成 App zip 公证、App staple、DMG 制作、
DMG 签名与公证，并严格验证最终产物。

最终输出：
  dist/SimulatorSlimmer-<version>.dmg

必需环境变量：
  DEVELOPER_ID_APPLICATION    完整的 Developer ID Application 签名身份
  DEVELOPMENT_TEAM            Apple Developer Team ID
  APP_STORE_API_KEY_ID        App Store Connect API Key ID
  APP_STORE_API_ISSUER_ID     App Store Connect Issuer ID
  APP_STORE_API_KEY_FILEPATH  P8 私钥的绝对路径；必须是普通 .p8 文件、不可为
                              符号链接，且权限必须为 400 或 600

依赖：
  brew install create-dmg

脚本测试模式：
  SIMULATOR_SLIMMER_SCRIPT_TESTING=1 时才允许注入命令替身和临时输出目录。
  正式模式固定使用系统命令及 /opt/homebrew/bin/create-dmg。
USAGE
}

if (($# > 0)); then
  case "$1" in
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
fi

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
  local preserve_build_root=0
  set +e
  if [[ "$mounted" == "1" ]]; then
    if ! "$hdiutil_cmd" detach "$mount_dir" >/dev/null 2>&1 && \
       ! "$hdiutil_cmd" detach -force "$mount_dir" >/dev/null 2>&1; then
      echo "警告：无法卸载 ${mount_dir}，已保留构建目录供人工处理：${build_root}" >&2
      preserve_build_root=1
    fi
  fi
  if [[ "$preserve_build_root" == "0" && "$build_root_cleanup_allowed" == "1" ]]; then
    /bin/rm -rf -- "$build_root"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

notary_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

submit_for_notarization() {
  local artifact="$1"
  local label="$2"
  local json_path="$3"
  local submission_id=""
  local status=""

  if ! "$notarytool_cmd" submit "$artifact" \
    --key "$api_key_file" \
    --key-id "$api_key_id" \
    --issuer "$api_issuer_id" \
    --wait \
    --output-format json > "$json_path"; then
    submission_id="$(notary_value "$json_path" id 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then
      "$notarytool_cmd" log "$submission_id" \
        --key "$api_key_file" --key-id "$api_key_id" --issuer "$api_issuer_id" >&2 || true
    fi
    echo "$label 公证提交失败。" >&2
    return 1
  fi

  submission_id="$(notary_value "$json_path" id)"
  status="$(notary_value "$json_path" status)"
  if [[ "$status" != "Accepted" ]]; then
    "$notarytool_cmd" log "$submission_id" \
      --key "$api_key_file" --key-id "$api_key_id" --issuer "$api_issuer_id" >&2 || true
    echo "$label 公证未通过：${status}（submission ID：${submission_id}）" >&2
    return 1
  fi
  printf '%s\n' "$submission_id"
}

section "检查发布环境"
require_safe_absolute_path "$build_root" "DMG 构建临时目录"
require_safe_absolute_path "$dist_dir" "发布目录"
if [[ "$dist_dir" == "$build_root" || "$dist_dir" == "$build_root/"* ]]; then
  echo "发布目录不能位于会被清理的 DMG 构建临时目录内。" >&2
  exit 2
fi
build_root_cleanup_allowed=1
for pair in \
  "$build_release_app_cmd|Release 构建脚本" \
  "$ditto_cmd|ditto" \
  "$notarytool_cmd|notarytool" \
  "$stapler_cmd|stapler" \
  "$create_dmg_cmd|create-dmg" \
  "$codesign_cmd|codesign" \
  "$spctl_cmd|spctl" \
  "$hdiutil_cmd|hdiutil"; do
  require_executable "${pair%%|*}" "${pair#*|}"
done

if [[ -z "$developer_id_application" || "$developer_id_application" != "Developer ID Application:"* ]]; then
  echo "必须提供以 Developer ID Application: 开头的 DEVELOPER_ID_APPLICATION。" >&2
  exit 2
fi
if [[ -z "$development_team" ]]; then
  echo "必须提供 DEVELOPMENT_TEAM。" >&2
  exit 2
fi
for pair in \
  "$api_key_id|APP_STORE_API_KEY_ID" \
  "$api_issuer_id|APP_STORE_API_ISSUER_ID" \
  "$api_key_file|APP_STORE_API_KEY_FILEPATH"; do
  if [[ -z "${pair%%|*}" ]]; then
    echo "缺少环境变量：${pair#*|}" >&2
    exit 2
  fi
done
if [[ "$api_key_file" != /* ]]; then
  echo "APP_STORE_API_KEY_FILEPATH 必须是绝对路径：$api_key_file" >&2
  exit 2
fi
if [[ "$api_key_file" != *.p8 ]]; then
  echo "App Store Connect API 私钥必须使用 .p8 扩展名：$api_key_file" >&2
  exit 2
fi
require_safe_absolute_path "$api_key_file" "App Store Connect P8"
if [[ -L "$api_key_file" || ! -f "$api_key_file" || ! -r "$api_key_file" ]]; then
  echo "App Store Connect P8 不存在、不可读、不是普通文件或为符号链接：$api_key_file" >&2
  exit 1
fi
p8_mode="$(/usr/bin/stat -f '%Lp' "$api_key_file")"
if [[ "$p8_mode" != "400" && "$p8_mode" != "600" ]]; then
  echo "App Store Connect P8 权限必须为 400 或 600，实际为 ${p8_mode}：${api_key_file}" >&2
  exit 1
fi

if [[ "$script_testing" != "1" ]]; then
  identity_output="$(/usr/bin/security find-identity -v -p codesigning)"
  if ! /usr/bin/grep -Fq "\"$developer_id_application\"" <<<"$identity_output"; then
    echo "未找到有效签名身份：$developer_id_application" >&2
    exit 1
  fi
fi

/bin/rm -rf -- "$build_root"
/bin/mkdir -p "$build_root" "$dist_dir"

section "构建 Developer ID Release App"
if [[ "$script_testing" == "1" ]]; then
  /usr/bin/env \
    -u APP_STORE_API_KEY_ID \
    -u APP_STORE_API_ISSUER_ID \
    -u APP_STORE_API_KEY_FILEPATH \
    SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
    SIMULATOR_SLIMMER_DERIVED_DATA_PATH="$build_root/DerivedData" \
    SIMULATOR_SLIMMER_DIST_DIR="$dist_dir" \
    DEVELOPER_ID_APPLICATION="$developer_id_application" \
    DEVELOPMENT_TEAM="$development_team" \
    "$build_release_app_cmd" --release-developer-id --clean --skip-zip
else
  /usr/bin/env \
    -u APP_STORE_API_KEY_ID \
    -u APP_STORE_API_ISSUER_ID \
    -u APP_STORE_API_KEY_FILEPATH \
    -u SIMULATOR_SLIMMER_SCRIPT_TESTING \
    DEVELOPER_ID_APPLICATION="$developer_id_application" \
    DEVELOPMENT_TEAM="$development_team" \
    "$build_release_app_cmd" --release-developer-id --clean --skip-zip
fi

if [[ ! -d "$app_path" ]]; then
  echo "Release 构建未生成 App：$app_path" >&2
  exit 1
fi
info_plist="$app_path/Contents/Info.plist"
main_executable="$app_path/Contents/MacOS/SimulatorSlimmer"
if [[ ! -f "$info_plist" || ! -x "$main_executable" ]]; then
  echo "Release App 结构不完整：$app_path" >&2
  exit 1
fi
actual_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
if [[ "$actual_bundle_id" != "com.neolabsapp.simulatorslimmer" ]]; then
  echo "Release App Bundle ID 不匹配：$actual_bundle_id" >&2
  exit 1
fi
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")"
"$codesign_cmd" --verify --deep --strict --verbose=4 "$app_path"

app_zip="$build_root/SimulatorSlimmer-$version-notary.zip"
app_notary_json="$build_root/app-notary.json"
dmg_notary_json="$build_root/dmg-notary.json"
dmg_work_path="$build_root/SimulatorSlimmer-$version.dmg"
final_dmg_path="$dist_dir/SimulatorSlimmer-$version.dmg"

section "公证并 staple App"
"$ditto_cmd" -c -k --keepParent "$app_path" "$app_zip"
if [[ ! -f "$app_zip" ]]; then
  echo "未生成用于公证的 App zip：$app_zip" >&2
  exit 1
fi
app_submission_id="$(submit_for_notarization "$app_zip" "App" "$app_notary_json")"
"$stapler_cmd" staple "$app_path"
"$stapler_cmd" validate "$app_path"
"$spctl_cmd" --assess --type execute --verbose=4 "$app_path"

section "制作并签名 DMG"
staging_dir="$build_root/staging"
/bin/mkdir -p "$staging_dir"
"$ditto_cmd" "$app_path" "$staging_dir/SimulatorSlimmer.app"
/bin/rm -f -- "$dmg_work_path"
set +e
"$create_dmg_cmd" \
  --volname "Simulator Slimmer $version" \
  --window-size 640 400 \
  --icon-size 100 \
  --icon "SimulatorSlimmer.app" 160 200 \
  --app-drop-link 480 200 \
  --no-internet-enable \
  "$dmg_work_path" "$staging_dir"
create_dmg_status=$?
set -e
if [[ ! -f "$dmg_work_path" ]]; then
  echo "create-dmg 未生成 DMG（退出码：${create_dmg_status}）。" >&2
  exit 1
fi
if [[ "$create_dmg_status" != "0" ]]; then
  echo "警告：create-dmg 退出码为 ${create_dmg_status}，但已生成 DMG，继续严格验证。" >&2
fi
"$codesign_cmd" --force --sign "$developer_id_application" --timestamp "$dmg_work_path"
"$codesign_cmd" --verify --strict --verbose=4 "$dmg_work_path"

section "公证并 staple DMG"
dmg_submission_id="$(submit_for_notarization "$dmg_work_path" "DMG" "$dmg_notary_json")"
"$stapler_cmd" staple "$dmg_work_path"
"$stapler_cmd" validate "$dmg_work_path"
"$hdiutil_cmd" verify "$dmg_work_path"
"$spctl_cmd" --assess --type open --context context:primary-signature --verbose=4 "$dmg_work_path"

section "挂载验证 DMG 内容"
/bin/mkdir -p "$mount_dir"
mounted=1
if ! "$hdiutil_cmd" attach "$dmg_work_path" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null; then
  if "$hdiutil_cmd" detach "$mount_dir" >/dev/null 2>&1 || \
     "$hdiutil_cmd" detach -force "$mount_dir" >/dev/null 2>&1; then
    mounted=0
  fi
  echo "DMG 挂载失败：$dmg_work_path" >&2
  exit 1
fi
mounted_app="$mount_dir/SimulatorSlimmer.app"
if [[ ! -d "$mounted_app" ]]; then
  echo "DMG 中缺少 SimulatorSlimmer.app。" >&2
  exit 1
fi
mounted_info_plist="$mounted_app/Contents/Info.plist"
mounted_executable="$mounted_app/Contents/MacOS/SimulatorSlimmer"
if [[ ! -f "$mounted_info_plist" || ! -x "$mounted_executable" ]]; then
  echo "DMG 内 App 结构不完整。" >&2
  exit 1
fi
mounted_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$mounted_info_plist")"
if [[ "$mounted_bundle_id" != "com.neolabsapp.simulatorslimmer" ]]; then
  echo "DMG 内 App Bundle ID 不匹配：$mounted_bundle_id" >&2
  exit 1
fi
"$codesign_cmd" --verify --deep --strict --verbose=4 "$mounted_app"
"$stapler_cmd" validate "$mounted_app"
"$spctl_cmd" --assess --type execute --verbose=4 "$mounted_app"
if ! "$hdiutil_cmd" detach "$mount_dir" >/dev/null && \
   ! "$hdiutil_cmd" detach -force "$mount_dir" >/dev/null; then
  echo "无法卸载 DMG：$mount_dir" >&2
  exit 1
fi
mounted=0

/bin/rm -f -- "$final_dmg_path"
/bin/mv "$dmg_work_path" "$final_dmg_path"
sha256="$(/usr/bin/shasum -a 256 "$final_dmg_path" | /usr/bin/awk '{print $1}')"
size="$(/usr/bin/du -h "$final_dmg_path" | /usr/bin/awk '{print $1}')"

section "发布产物已完成"
echo "版本：$version ($build_number)"
echo "路径：$final_dmg_path"
echo "大小：$size"
echo "SHA-256：$sha256"
echo "App submission ID：$app_submission_id"
echo "DMG submission ID：$dmg_submission_id"
