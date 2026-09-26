#!/usr/bin/env bash
# run-swiftlint.sh —— 运行 SwiftLint（Homebrew 二进制）。
# 集成方式说明：SwiftLint 不进入 SPM 依赖图，避免把 SourceKitten 等编译依赖
# 拖进每次 swift build。CI 上可安装官方预编译 release 后复用本脚本。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint 未安装。安装方式：" >&2
  echo "  brew install swiftlint" >&2
  echo "或下载官方 release：https://github.com/realm/SwiftLint/releases" >&2
  exit 2
fi

echo "SwiftLint 版本：$(swiftlint version)"
echo "配置：$ROOT_DIR/.swiftlint.yml"

if [[ "${1:-}" == "--strict" ]]; then
  swiftlint lint --strict
else
  swiftlint lint --quiet
fi
