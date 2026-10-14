#!/bin/sh
# Compiles and runs the Swift tests for the app's pure logic.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
printf 'enum LidScript { static let base64 = "%s" }\n' "$(base64 < "$ROOT/lid/vigil-lid.sh" | tr -d '\n')" > "$OUT/LidScript.swift"
xcrun swiftc -parse-as-library -o "$OUT/tests" "$ROOT/mac/Announcer.swift" "$ROOT/mac/DailyLog.swift" \
  "$ROOT/mac/Format.swift" "$ROOT/mac/Settings.swift" "$ROOT/mac/MarkerScanner.swift" "$ROOT/mac/ProcessTree.swift" \
  "$ROOT/mac/LidHelper.swift" "$OUT/LidScript.swift" "$ROOT/tests/swift/AnnouncerTests.swift"
"$OUT/tests"
