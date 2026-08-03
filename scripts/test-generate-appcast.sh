#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/mkdir -p "$repo_root/.build"
tmp_dir="$(/usr/bin/mktemp -d "$repo_root/.build/appcast-script-test.XXXXXX")"
trap '/bin/rm -rf -- "$tmp_dir"' EXIT

keypair="$(/usr/bin/swift -e 'import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString() + "|" + key.publicKey.rawRepresentation.base64EncodedString())')"
private_key="${keypair%%|*}"
public_key="${keypair#*|}"
app_path="$tmp_dir/SimulatorSlimmer.app"
dist_dir="$tmp_dir/dist"
/bin/mkdir -p "$app_path/Contents" "$dist_dir"

/usr/bin/plutil -create xml1 "$app_path/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.2.3 "$app_path/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 42 "$app_path/Contents/Info.plist"
/usr/bin/plutil -insert SUPublicEDKey -string "$public_key" "$app_path/Contents/Info.plist"

fake_ditto="$tmp_dir/ditto"
fake_generate_appcast="$tmp_dir/generate_appcast"
cat > "$fake_ditto" <<'FAKE_DITTO'
#!/usr/bin/env bash
set -euo pipefail
: > "${!#}"
FAKE_DITTO
cat > "$fake_generate_appcast" <<'FAKE_GENERATE_APPCAST'
#!/usr/bin/env bash
set -euo pipefail
output=""
prefix=""
stage="${!#}"
while (($# > 0)); do
  case "$1" in
    --ed-key-file|--maximum-deltas) shift 2 ;;
    --download-url-prefix) prefix="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
zip_path="$(find "$stage" -type f -name '*.zip' -print -quit)"
zip_name="$(basename "$zip_path")"
cat > "$output" <<XML
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="$prefix$zip_name" sparkle:edSignature="test" /></item></channel></rss>
XML
FAKE_GENERATE_APPCAST
/bin/chmod +x "$fake_ditto" "$fake_generate_appcast"

run_script() {
  DITTO="$fake_ditto" \
    GENERATE_APPCAST="$fake_generate_appcast" \
    SIMULATOR_SLIMMER_SCRIPT_TESTING=1 \
    SIMULATOR_SLIMMER_RELEASE_APP_PATH="$app_path" \
    SIMULATOR_SLIMMER_DIST_DIR="$dist_dir" \
    GITHUB_REPOSITORY=lvxiaohai/SimulatorSlimmer \
    GITHUB_REF_NAME="${TEST_TAG:-v1.2.3}" \
    SPARKLE_ED_PRIVATE_KEY="$private_key" \
    "$repo_root/scripts/generate-appcast.sh"
}

run_script >/dev/null
test -f "$dist_dir/SimulatorSlimmer-1.2.3-42.zip"
/usr/bin/grep -Fq \
  'https://github.com/lvxiaohai/SimulatorSlimmer/releases/download/v1.2.3/SimulatorSlimmer-1.2.3-42.zip' \
  "$dist_dir/appcast.xml"
/usr/bin/grep -Fq 'sparkle:edSignature=' "$dist_dir/appcast.xml"

if TEST_TAG=v9.9.9 run_script >"$tmp_dir/wrong-tag.out" 2>&1; then
  echo "版本不匹配的 Tag 不应生成 appcast。" >&2
  exit 1
fi
/usr/bin/grep -Fq '与 App 版本 1.2.3 不一致' "$tmp_dir/wrong-tag.out"

echo "GitHub Release appcast 生成测试通过。"
