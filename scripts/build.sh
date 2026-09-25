#!/usr/bin/env bash
# Verify Rememoru: build, run the tests, and on macOS assemble the app.
# Usage: scripts/build.sh [--clean]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPOSITORY_ROOT"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf .build dist
fi

echo "== build"
swift build

echo "== tests"
swift test

# The core library builds and tests anywhere; the app needs macOS.
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== app bundle"
  "$SCRIPT_DIR/build-app.sh"
fi
