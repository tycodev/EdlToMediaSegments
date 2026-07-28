#!/usr/bin/env bash
set -euox pipefail

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/release.sh <version> <release-tag-or-name>

Example:
  ./scripts/release.sh 1.0.0.4 v1.0.0.4

This script:
  1. Zips bin/Release/net9.0/EdlToMediaSegments.dll into EdlToMediaSegments-<version>.zip
  2. Computes the zip MD5 checksum
  3. Updates the matching version checksum in manifest.json
  4. Uploads the zip to the specified GitHub release
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

VERSION=$1
RELEASE=$2
MANIFEST=manifest.json
SOURCE_DLL=bin/Release/net9.0/EdlToMediaSegments.dll
OUTPUT=EdlToMediaSegments-${VERSION}.zip

if [[ ! -f "$SOURCE_DLL" ]]; then
  echo "Error: source DLL not found: $SOURCE_DLL" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: manifest.json not found in repository root." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to update manifest.json." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh (GitHub CLI) is required to upload the release asset." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required to read the repository remote." >&2
  exit 1
fi

REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$REMOTE_URL" ]]; then
  echo "Error: no origin remote found. Set an origin remote or use a GitHub repo default." >&2
  exit 1
fi

REPO=$(printf '%s' "$REMOTE_URL" | sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#\.git$##')
if [[ -z "$REPO" ]]; then
  echo "Error: could not parse GitHub repo from remote URL: $REMOTE_URL" >&2
  exit 1
fi

rm -f "$OUTPUT"
zip -j "$OUTPUT" "$SOURCE_DLL"

echo "Created $OUTPUT"

if command -v md5 >/dev/null 2>&1; then
  MD5=$(md5 -q "$OUTPUT")
elif command -v md5sum >/dev/null 2>&1; then
  MD5=$(md5sum "$OUTPUT" | awk '{print $1}')
else
  echo "Error: md5 or md5sum is required to compute checksum." >&2
  exit 1
fi

MD5=$(printf '%s' "$MD5" | tr '[:upper:]' '[:lower:]')

echo "Computed MD5: $MD5"

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

jq --arg version "$VERSION" --arg checksum "$MD5" '
  if any(.[]?.versions[]?; .version == $version) then
    map(
      .versions |= map(
        if .version == $version then .checksum = $checksum else . end
      )
    )
  else
    error("version \($version) not found in manifest.json")
  end
' "$MANIFEST" > "$TMPFILE"

mv "$TMPFILE" "$MANIFEST"
trap - EXIT

echo "Updated $MANIFEST checksum for version $VERSION"

gh release upload "$RELEASE" "$OUTPUT" --repo "$REPO" --clobber

echo "Uploaded $OUTPUT to release $RELEASE on $REPO"
