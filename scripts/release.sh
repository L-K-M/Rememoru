#!/usr/bin/env bash
# Version, verify, commit, and tag an app release.
# Usage: scripts/release.sh X.Y.Z [--push]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly VERSION_FILE="$REPOSITORY_ROOT/VERSION"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
  echo "Usage: scripts/release.sh X.Y.Z [--push]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

readonly version="$1"
readonly push_option="${2:-}"

if [[ ! "$version" =~ $VERSION_PATTERN ]]; then
  echo "Version must use X.Y.Z." >&2
  exit 2
fi

if [[ -n "$push_option" && "$push_option" != "--push" ]]; then
  usage
  exit 2
fi

cd "$REPOSITORY_ROOT"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Releases must start on main." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree must be clean." >&2
  exit 1
fi

# Releasing from anything but origin/main itself tags a tree nobody has
# reviewed on the remote: behind means stale, ahead means unpushed.
git fetch origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "Local main must match origin/main; sync first." >&2
  exit 1
fi

readonly tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

# VERSION becomes the app's CFBundleShortVersionString; the release tag
# must agree with it.
printf '%s\n' "$version" > "$VERSION_FILE"

"$SCRIPT_DIR/build.sh" --clean

git add "$VERSION_FILE"
git commit -s -m "Release Rememoru $version" \
  -m "Bump VERSION and publish the app release."
git tag -a "$tag" -m "Rememoru $version"

if [[ "$push_option" == "--push" ]]; then
  git push origin main "$tag"
fi

echo "Created $tag."
