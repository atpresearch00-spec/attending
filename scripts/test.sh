#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/sdk.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --product attending-bridge
swift run --disable-sandbox --cache-path "$PWD/.build/cache" AttendingCoreChecks
python3 scripts/test-bridge.py

python3 scripts/test-approvals.py
python3 scripts/test-codex-transport.py
