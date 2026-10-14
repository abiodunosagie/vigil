#!/bin/sh
# Compiles and runs the Swift tests for the app's pure logic.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun swiftc -parse-as-library -o "$OUT/tests" "$ROOT/mac/Announcer.swift" "$ROOT/mac/DailyLog.swift" \
  "$ROOT/mac/Format.swift" "$ROOT/mac/Settings.swift" "$ROOT/tests/swift/AnnouncerTests.swift"
"$OUT/tests"
