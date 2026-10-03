#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --scratch-path .build --cache-path .build/cache --disable-sandbox
if [[ "${1:-}" == "--integration" ]]; then
    .build/debug/hearth-smoke --download --extended
fi
