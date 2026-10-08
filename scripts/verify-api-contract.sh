#!/bin/bash
# Contract tests without XCTest/Xcode. Never contacts model APIs or uses real keys.
set -euo pipefail
cd "$(dirname "$0")/.."
jot_build="${JOT_CHECK_BUILD:-$PWD/build/api-contract}"
jot_cache="${JOT_CHECK_CACHE:-$PWD/build/api-contract-cache}"
swift build --package-path JotCore --scratch-path "$jot_build" --cache-path "$jot_cache" --disable-sandbox
jot_bin=$(swift build --package-path JotCore --scratch-path "$jot_build" --show-bin-path)
jot_objects=()
while IFS= read -r object; do jot_objects+=("$object"); done < <(
  rg --files --hidden --no-ignore "$jot_bin/JotCore.build" "$jot_bin/GRDB.build" "$jot_bin/Sauce.build" -g '*.o'
)
swiftc -parse-as-library -swift-version 5 \
  -I "$jot_bin/Modules" -I "$jot_build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  JotCore/Tests/JotCoreTests/APIContractChecks.swift scripts/api-contract-main.swift \
  "${jot_objects[@]}" -lsqlite3 -o "$jot_build/api-contract-check"
"$jot_build/api-contract-check"
