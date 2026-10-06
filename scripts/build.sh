#!/usr/bin/env bash
# Verify Rememoru: build, run the tests, and on macOS assemble the app.
# Usage: scripts/build.sh [--clean] [--install]
#   --install   on macOS, also copy the app to ~/Applications (see
#               scripts/build-app.sh for signing/identity notes)
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPOSITORY_ROOT"

CLEAN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "!! unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Fail fast: there is no app bundle to install off macOS, so don't build first.
if [[ "$INSTALL" == 1 && "$(uname -s)" != "Darwin" ]]; then
  echo "!! --install needs macOS: there is no app bundle to install here" >&2
  exit 1
fi

if [[ "$CLEAN" == 1 ]]; then
  rm -rf .build dist
fi

echo "== build"
swift build

echo "== tests"
swift test

# The core library builds and tests anywhere; the app needs macOS.
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== app bundle"
  if [[ "$INSTALL" == 1 ]]; then
    "$SCRIPT_DIR/build-app.sh" --install
  else
    "$SCRIPT_DIR/build-app.sh"
  fi
fi
