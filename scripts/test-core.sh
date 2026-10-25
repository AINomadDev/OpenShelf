#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/core-checks
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swiftc Sources/OpenShelf/Storage.swift Sources/OpenShelf/Insights.swift Sources/OpenShelf/CloudInsights.swift Tests/CoreChecks/main.swift -o .build/core-checks/check
.build/core-checks/check
