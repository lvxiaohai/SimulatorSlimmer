#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts=(
  scripts/build-release-app.sh
  scripts/build-dmg.sh
  scripts/smoke-release-app.sh
  scripts/generate-appcast.sh
  scripts/test-build-release-app.sh
  scripts/test-build-dmg.sh
  scripts/test-smoke-release-app.sh
  scripts/test-generate-appcast.sh
  scripts/test-release-scripts.sh
)

echo "== Bash 语法检查 =="
for script in "${scripts[@]}"; do
  /bin/bash -n "$script"
  echo "通过：$script"
done

echo
echo "== Zsh 语法检查 =="
for script in "${scripts[@]}"; do
  /bin/zsh -n "$script"
  echo "通过：$script"
done

echo
echo "== 发布脚本行为测试 =="
for test_script in \
  scripts/test-build-release-app.sh \
  scripts/test-build-dmg.sh \
  scripts/test-smoke-release-app.sh \
  scripts/test-generate-appcast.sh; do
  echo
  echo "运行：$test_script"
  /bin/bash "$test_script"
done

echo
echo "全部发布脚本语法检查和行为测试通过。"
