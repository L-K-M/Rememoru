#!/usr/bin/env bash
# Build dist/Rememoru.app from the Swift package (macOS only).
#
# Usage: scripts/build-app.sh [--install]
#   --install   also copy the app to ~/Applications, replacing an older copy
#
# Environment:
#   CODESIGN_IDENTITY  signing identity (default "-", ad hoc). macOS ties the
#                      Accessibility grant to the signature, and an ad-hoc
#                      signature changes with every build, so each rebuild
#                      needs the grant again. An "Apple Development" or
#                      self-signed code-signing identity keeps it.
#   BUNDLE_ID          bundle identifier (default io.github.l-k-m.rememoru)
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP="$REPOSITORY_ROOT/dist/Rememoru.app"
readonly VERSION="$(tr -d '[:space:]' < "$REPOSITORY_ROOT/VERSION")"
readonly IDENTITY="${CODESIGN_IDENTITY:--}"
readonly BUNDLE_ID="${BUNDLE_ID:-io.github.l-k-m.rememoru}"

install_option="${1:-}"
if [[ -n "$install_option" && "$install_option" != "--install" ]]; then
  echo "Usage: scripts/build-app.sh [--install]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Rememoru.app can only be built on macOS." >&2
  exit 1
fi

cd "$REPOSITORY_ROOT"
swift build -c release --product Rememoru
binary="$(swift build -c release --show-bin-path)/Rememoru"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$binary" "$APP/Contents/MacOS/Rememoru"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Rememoru</string>
    <key>CFBundleExecutable</key>
    <string>Rememoru</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Rememoru</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The hardened runtime only matters for notarized Developer ID builds.
sign_options=()
if [[ "$IDENTITY" != "-" ]]; then
  sign_options=(--options runtime --timestamp)
fi
codesign --force --sign "$IDENTITY" "${sign_options[@]+"${sign_options[@]}"}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, signed with ${IDENTITY/#-/ad hoc identity})"

if [[ "$install_option" == "--install" ]]; then
  target="$HOME/Applications/Rememoru.app"
  mkdir -p "$HOME/Applications"
  # a running copy keeps the old binary mapped; quit it first
  pkill -x Rememoru 2>/dev/null || true
  rm -rf "$target"
  ditto "$APP" "$target"
  echo "Installed $target"
fi
