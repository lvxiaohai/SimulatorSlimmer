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
  if [[ -n "${DITTO+x}${PLUTIL+x}${SWIFT+x}${GENERATE_APPCAST+x}${SIMULATOR_SLIMMER_RELEASE_APP_PATH+x}${SIMULATOR_SLIMMER_DIST_DIR+x}" ]]; then
    echo "命令和输出路径覆盖只能在脚本测试模式使用。" >&2
    exit 2
  fi
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  ditto_cmd="/usr/bin/ditto"
  plutil_cmd="/usr/bin/plutil"
  swift_cmd="/usr/bin/swift"
  generate_appcast_cmd="$repo_root/.build/release-app/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  app_path="$repo_root/dist/SimulatorSlimmer.app"
  dist_dir="$repo_root/dist"
else
  ditto_cmd="${DITTO:-/usr/bin/ditto}"
  plutil_cmd="${PLUTIL:-/usr/bin/plutil}"
  swift_cmd="${SWIFT:-/usr/bin/swift}"
  generate_appcast_cmd="${GENERATE_APPCAST:-$repo_root/.build/release-app/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
  app_path="${SIMULATOR_SLIMMER_RELEASE_APP_PATH:-$repo_root/dist/SimulatorSlimmer.app}"
  dist_dir="${SIMULATOR_SLIMMER_DIST_DIR:-$repo_root/dist}"
fi

repository="${GITHUB_REPOSITORY:-}"
tag="${GITHUB_REF_NAME:-}"
private_key="${SPARKLE_ED_PRIVATE_KEY:-}"

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "GITHUB_REPOSITORY 必须形如 owner/repository。" >&2
  exit 2
}
[[ -n "$private_key" ]] || { echo "缺少 SPARKLE_ED_PRIVATE_KEY。" >&2; exit 2; }
[[ -x "$ditto_cmd" && -x "$plutil_cmd" && -x "$swift_cmd" && -x "$generate_appcast_cmd" ]] || {
  echo "生成 appcast 所需命令不完整。" >&2
  exit 1
}
[[ -d "$app_path" ]] || { echo "未找到 Release App：$app_path" >&2; exit 1; }

info_plist="$app_path/Contents/Info.plist"
version="$($plutil_cmd -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_number="$($plutil_cmd -extract CFBundleVersion raw -o - "$info_plist")"
public_key="$($plutil_cmd -extract SUPublicEDKey raw -o - "$info_plist")"
[[ "$tag" == "v$version" ]] || {
  echo "Tag $tag 与 App 版本 $version 不一致。" >&2
  exit 2
}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo "App 构建号不是正整数。" >&2; exit 2; }

derived_public_key="$({ printf '%s\n' "$private_key" | "$swift_cmd" -e 'import CryptoKit
import Foundation
guard let line = readLine(), let raw = Data(base64Encoded: line),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())'; } 2>/dev/null)" || {
  echo "SPARKLE_ED_PRIVATE_KEY 无效。" >&2
  exit 2
}
[[ "$derived_public_key" == "$public_key" ]] || {
  echo "Sparkle 私钥与 App 内公钥不匹配。" >&2
  exit 2
}

/bin/mkdir -p "$dist_dir" "$repo_root/.build"
stage_dir="$(/usr/bin/mktemp -d "$repo_root/.build/appcast.XXXXXX")"
trap '/bin/rm -rf -- "$stage_dir"' EXIT

zip_name="SimulatorSlimmer-$version-$build_number.zip"
zip_path="$dist_dir/$zip_name"
appcast_path="$dist_dir/appcast.xml"
download_prefix="https://github.com/$repository/releases/download/$tag/"

/bin/rm -f -- "$zip_path" "$appcast_path"
"$ditto_cmd" -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
/bin/cp "$zip_path" "$stage_dir/$zip_name"
printf '%s\n' "$private_key" | "$generate_appcast_cmd" \
  --ed-key-file - \
  --download-url-prefix "$download_prefix" \
  --maximum-deltas 0 \
  -o "$stage_dir/appcast.xml" \
  "$stage_dir"
/bin/mv "$stage_dir/appcast.xml" "$appcast_path"

/usr/bin/grep -Fq "$download_prefix$zip_name" "$appcast_path" || {
  echo "appcast 未引用本次 GitHub Release ZIP。" >&2
  exit 1
}
/usr/bin/grep -Fq 'sparkle:edSignature=' "$appcast_path" || {
  echo "appcast 缺少 Sparkle EdDSA 签名。" >&2
  exit 1
}

echo "更新 ZIP：$zip_path"
echo "Appcast：$appcast_path"
