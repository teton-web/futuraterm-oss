#!/usr/bin/env bash
# Publish one notarized DMG to futuraterm.com (Vercel Blob + Neon app_releases).
#
# Required env when publishing:
#   FUTURATERM_RELEASE_UPLOAD_TOKEN — Bearer for the site write endpoints
#   VERSION                         — marketing version, e.g. 0.1.21
#
# Optional env:
#   PRERELEASE                     — "true" → channel beta; else stable
#   FUTURATERM_RELEASE_SITE_ORIGIN — default https://futuraterm.com
#   PUBLISH_WEBSITE_DRY_RUN        — "1" logs intended request then exits 0
#
# Usage: publish-website-release.sh <dmg_dir>
#
# Unset token: skip with a log line and exit 0 (public snapshot / forks).
# Never print the bearer or the Blob client token.

set -euo pipefail

DMG_DIR="${1:-dmgs}"
VERSION="${VERSION:-}"
PRERELEASE="${PRERELEASE:-false}"
ORIGIN="${FUTURATERM_RELEASE_SITE_ORIGIN:-https://futuraterm.com}"
ORIGIN="${ORIGIN%/}"

if [[ -z "${FUTURATERM_RELEASE_UPLOAD_TOKEN:-}" ]]; then
  echo "FUTURATERM_RELEASE_UPLOAD_TOKEN unset; skipping website DMG publish"
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "error: VERSION is required" >&2
  exit 1
fi

FILENAME="FuturaTerm-${VERSION}.dmg"
DMG="${DMG_DIR}/${FILENAME}"
if [[ ! -f "$DMG" ]]; then
  echo "error: expected exactly ${FILENAME} in ${DMG_DIR} (missing ${DMG})" >&2
  ls -la "$DMG_DIR" >&2 || true
  exit 1
fi

if [[ "$PRERELEASE" == "true" ]]; then
  CHANNEL="beta"
else
  CHANNEL="stable"
fi

SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
if SIZE=$(stat -f%z "$DMG" 2>/dev/null); then
  :
elif SIZE=$(stat -c%s "$DMG" 2>/dev/null); then
  :
else
  echo "error: could not stat ${DMG}" >&2
  exit 1
fi
if [[ "$SIZE" -lt 1 ]]; then
  echo "error: ${DMG} is empty" >&2
  exit 1
fi

TOKEN_URL="${ORIGIN}/api/releases/upload-token"
COMPLETE_URL="${ORIGIN}/api/releases/complete"

echo "Website publish: version=${VERSION} channel=${CHANNEL} filename=${FILENAME} sha256=${SHA256} sizeBytes=${SIZE}"
echo "Token URL: ${TOKEN_URL}"
echo "Complete URL: ${COMPLETE_URL}"

if [[ "${PUBLISH_WEBSITE_DRY_RUN:-}" == "1" ]]; then
  echo "PUBLISH_WEBSITE_DRY_RUN=1; not contacting the site"
  exit 0
fi

# python3 only for JSON; never print bearer / client token.
parse_json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

TOKEN_BODY=$(python3 -c 'import json,sys; print(json.dumps({"version":sys.argv[1],"filename":sys.argv[2],"channel":sys.argv[3]}))' \
  "$VERSION" "$FILENAME" "$CHANNEL")

TOKEN_RESP=$(mktemp)
BLOB_RESP=""
COMPLETE_RESP=""
trap 'rm -f "$TOKEN_RESP" ${BLOB_RESP:+"$BLOB_RESP"} ${COMPLETE_RESP:+"$COMPLETE_RESP"}' EXIT

HTTP_CODE=$(curl -sS -o "$TOKEN_RESP" -w "%{http_code}" -X POST "$TOKEN_URL" \
  -H "Authorization: Bearer ${FUTURATERM_RELEASE_UPLOAD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$TOKEN_BODY")
if [[ "$HTTP_CODE" != 2* ]]; then
  echo "error: upload-token returned HTTP ${HTTP_CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:2000])' <"$TOKEN_RESP" >&2 || true
  exit 1
fi

BLOB_CLIENT_TOKEN=$(parse_json_field token <"$TOKEN_RESP")
BLOB_PATHNAME=$(parse_json_field pathname <"$TOKEN_RESP")
BLOB_CONTENT_TYPE=$(parse_json_field contentType <"$TOKEN_RESP")
if [[ -z "$BLOB_CLIENT_TOKEN" || -z "$BLOB_PATHNAME" || -z "$BLOB_CONTENT_TYPE" ]]; then
  echo "error: upload-token response missing token, pathname, or contentType" >&2
  exit 1
fi
echo "Blob pathname: ${BLOB_PATHNAME}"

BLOB_RESP=$(mktemp)
BLOB_QUERY=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.urlencode({"pathname": sys.argv[1]}))' "$BLOB_PATHNAME")
HTTP_CODE=$(curl -sS -o "$BLOB_RESP" -w "%{http_code}" -X PUT \
  "https://vercel.com/api/blob/?${BLOB_QUERY}" \
  -H "Authorization: Bearer ${BLOB_CLIENT_TOKEN}" \
  -H "x-api-blob-access: public" \
  -H "x-api-version: 11" \
  -H "x-content-type: ${BLOB_CONTENT_TYPE}" \
  -H "Content-Type: ${BLOB_CONTENT_TYPE}" \
  --data-binary @"$DMG")
if [[ "$HTTP_CODE" != 2* ]]; then
  echo "error: Blob PUT returned HTTP ${HTTP_CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:2000])' <"$BLOB_RESP" >&2 || true
  exit 1
fi

BLOB_URL=$(parse_json_field url <"$BLOB_RESP")
if [[ -z "$BLOB_URL" ]]; then
  echo "error: Blob PUT response missing url" >&2
  exit 1
fi
echo "Blob URL: ${BLOB_URL}"

COMPLETE_BODY=$(python3 -c '
import json, sys
print(json.dumps({
  "version": sys.argv[1],
  "channel": sys.argv[2],
  "filename": sys.argv[3],
  "sha256": sys.argv[4],
  "sizeBytes": int(sys.argv[5]),
  "url": sys.argv[6],
  "storageKey": sys.argv[7],
}))
' "$VERSION" "$CHANNEL" "$FILENAME" "$SHA256" "$SIZE" "$BLOB_URL" "$BLOB_PATHNAME")

COMPLETE_RESP=$(mktemp)
HTTP_CODE=$(curl -sS -o "$COMPLETE_RESP" -w "%{http_code}" -X POST "$COMPLETE_URL" \
  -H "Authorization: Bearer ${FUTURATERM_RELEASE_UPLOAD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$COMPLETE_BODY")
if [[ "$HTTP_CODE" != 2* ]]; then
  echo "error: complete returned HTTP ${HTTP_CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:2000])' <"$COMPLETE_RESP" >&2 || true
  exit 1
fi

echo "Website complete HTTP ${HTTP_CODE} for ${VERSION} (${CHANNEL})"
