#!/usr/bin/env bash
# Sign each DMG with Sparkle's sign_update, then GET-merge a new <item> into
# the Sparkle feed at https://futuraterm.com/appcast.xml and POST the full XML.
#
# Signed releases run on private teton-web/futuraterm. Sparkle clients fetch
# the public site feed (not GitHub Pages). Duplicate sparkle:version items are
# skipped here (publisher skip). POST /api/releases/appcast unions <item>s by
# sparkle:version with the stored feed so overlapping publishes cannot drop an
# item; Blob key releases/sparkle/appcast.xml is still overwritten in place.
#
# Required env:
#   SPARKLE_ED_PRIVATE_KEY — EdDSA private key (Sparkle format)
#   FUTURATERM_RELEASE_UPLOAD_TOKEN — bearer for POST /api/releases/appcast
#   VERSION                — e.g. 1.8.0, or 0.9.0-beta.1 for a prerelease
#   TAG                    — e.g. v1.8.0
#
# Optional env:
#   PRERELEASE             — "true" to tag items with <sparkle:channel>beta.
#                            Only updaters whose allowedChannels includes
#                            "beta" (Settings → Updates → Channel: Beta)
#                            can see them; everyone else keeps getting stable.
#   ENCLOSURE_URL          — DMG download URL (prefer website Blob URL;
#                            GitHub public download is fallback only)
#   APPCAST_ORIGIN         — site origin (default https://futuraterm.com)
#   GITHUB_REPOSITORY      — provided by GitHub Actions (owner/repo); must be
#                            the public snapshot or the private working clone
#
# ONE feed, two channels — deliberately not a second appcast file. Sparkle
# filters channels client-side, so a beta tester's app and a stable user's app
# read the same URL and diverge only on the delegate's allowedChannels. That
# also means a tester who opts back out immediately sees stable again, with no
# feed-URL migration.
#
# Usage: publish-appcast.sh <dmg_dir>

set -euo pipefail

PUBLIC_REPO="teton-web/futuraterm-oss"
PRIVATE_REPO="teton-web/futuraterm"
case "${GITHUB_REPOSITORY:-}" in
  "$PUBLIC_REPO" | "$PRIVATE_REPO") ;;
  *)
    echo "error: refuse to publish appcast/feed URLs except from ${PUBLIC_REPO} or ${PRIVATE_REPO}" >&2
    exit 1
    ;;
esac

if [[ -z "${FUTURATERM_RELEASE_UPLOAD_TOKEN:-}" ]]; then
  echo "error: FUTURATERM_RELEASE_UPLOAD_TOKEN required to POST /api/releases/appcast" >&2
  exit 1
fi

# shellcheck source=scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DMG_DIR="${1:-dmgs}"
PRERELEASE="${PRERELEASE:-false}"
# MUST match the app's CFBundleVersion, which build.sh derives with the same
# helper — Sparkle orders updates by this, not by the display string.
COMPARISON_VERSION="$(sparkle_comparison_version "$VERSION")"
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
REPO_URL="https://github.com/${PUBLIC_REPO}"
APPCAST_ORIGIN="${APPCAST_ORIGIN:-https://futuraterm.com}"
APPCAST_URL="${APPCAST_ORIGIN%/}/appcast.xml"
APPCAST_POST_URL="${APPCAST_ORIGIN%/}/api/releases/appcast"
NOTES_URL="${REPO_URL}/releases/tag/${TAG}"

ITEMS_FILE=""
cleanup_publish() {
  rm -f ${ITEMS_FILE:+"$ITEMS_FILE"}
}
trap cleanup_publish EXIT

# Write the per-DMG <item> blocks into a temp file.
ITEMS_FILE=$(mktemp)

# Collect DMGs into an array so an empty dir fails with a clear message rather
# than iterating the literal `dmgs/*.dmg` glob and handing `sign_update` a
# nonexistent path (an opaque error).
shopt -s nullglob
dmgs=("$DMG_DIR"/*.dmg)
shopt -u nullglob
if [[ ${#dmgs[@]} -eq 0 ]]; then
  echo "error: no .dmg files found in '$DMG_DIR'" >&2
  exit 1
fi

# Prereleases carry <sparkle:channel>beta</sparkle:channel>; stable items carry
# no channel element at all (Sparkle's default channel, visible to everyone).
# The literal "beta" is a wire contract with `betaUpdateChannel` in
# FuturaTerm/App/Updater.swift — UpdaterChannelTests pins it on the Swift side.
CHANNEL_LINE=""
TITLE_SUFFIX=""
if [[ "$PRERELEASE" == "true" ]]; then
  CHANNEL_LINE=$'\n      <sparkle:channel>beta</sparkle:channel>'
  TITLE_SUFFIX=" (beta)"
fi

for dmg in "${dmgs[@]}"; do
  name=$(basename "$dmg")
  url="${ENCLOSURE_URL:-https://github.com/${PUBLIC_REPO}/releases/download/${TAG}/${name}}"
  sig=$(sign_update -f <(echo "$SPARKLE_ED_PRIVATE_KEY") "$dmg")
  cat >> "$ITEMS_FILE" <<ITEM
    <item>
      <title>FuturaTerm ${VERSION}${TITLE_SUFFIX}</title>
      <pubDate>${PUB_DATE}</pubDate>${CHANNEL_LINE}
      <sparkle:version>${COMPARISON_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
      <link>${REPO_URL}/releases/tag/${TAG}</link>
      <enclosure url="${url}" type="application/octet-stream" ${sig} />
    </item>
ITEM
done

WORKDIR=$(mktemp -d)
APPCAST_FILE="${WORKDIR}/appcast.xml"
if ! curl -fsS -H "Cache-Control: no-cache" "${APPCAST_URL}?t=$(date +%s)" -o "$APPCAST_FILE"; then
  echo "error: GET ${APPCAST_URL} failed" >&2
  exit 1
fi

if [[ ! -s "$APPCAST_FILE" ]] || ! grep -q "<rss" "$APPCAST_FILE"; then
  cat > "$APPCAST_FILE" <<HEADER
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FuturaTerm</title>
    <link>${APPCAST_URL}</link>
    <description>Updates for FuturaTerm.</description>
    <language>en</language>
  </channel>
</rss>
HEADER
fi

# Insert the new <item>s before </channel> — but only if this version isn't
# already present. Re-running the workflow for the same tag (a common recovery
# action) would otherwise append a duplicate <item> for the version, leaving
# Sparkle with two entries for one release.
if grep -q "<sparkle:version>${COMPARISON_VERSION}</sparkle:version>" "$APPCAST_FILE"; then
  echo "appcast already has an entry for ${VERSION}; not inserting a duplicate"
else
  awk -v items_file="$ITEMS_FILE" '
    /<\/channel>/ {
      while ((getline line < items_file) > 0) print line
      close(items_file)
    }
    { print }
  ' "$APPCAST_FILE" > "${APPCAST_FILE}.new"
  mv "${APPCAST_FILE}.new" "$APPCAST_FILE"
fi

curl -fsS -X POST "$APPCAST_POST_URL" \
  -H "Authorization: Bearer ${FUTURATERM_RELEASE_UPLOAD_TOKEN}" \
  -H "Content-Type: application/xml" \
  --data-binary @"$APPCAST_FILE"

echo "Published appcast for ${TAG}"
