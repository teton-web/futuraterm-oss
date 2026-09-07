#!/usr/bin/env bash
# Submit a disk image to Apple notarization and staple the ticket.
#
# Credentials, first match wins:
#   1. APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER
#   2. APPLE_API_KEY (PEM body) + APPLE_API_KEY_ID + APPLE_API_ISSUER
#   3. notarytool keychain profile `futuraterm`
#   4. ~/.asc/AuthKey_*.p8 + ~/.asc/issuer-id.txt (local Apple ID setup)
set -euo pipefail

usage() {
  echo "usage: notarize.sh <artifact.dmg>" >&2
  exit 2
}

ARTIFACT="${1:-}"
[[ -n "$ARTIFACT" && -f "$ARTIFACT" ]] || usage

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH=()
TMPKEY=""
cleanup() { [[ -n "$TMPKEY" ]] && rm -f "$TMPKEY"; }
trap cleanup EXIT

resolve_auth() {
  if [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
    AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
    return
  fi
  if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
    TMPKEY="$(mktemp)"
    printf '%s' "$APPLE_API_KEY" >"$TMPKEY"
    # Apple's keys are PEM; restore a trailing newline if the secret lost it.
    [[ "$(tail -c1 "$TMPKEY" | wc -l)" -eq 0 ]] && printf '\n' >>"$TMPKEY"
    chmod 600 "$TMPKEY"
    AUTH=(--key "$TMPKEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
    return
  fi
  if xcrun notarytool history --keychain-profile futuraterm >/dev/null 2>&1; then
    AUTH=(--keychain-profile futuraterm)
    return
  fi
  local asc="${HOME}/.asc"
  local key="" issuer=""
  if [[ -d "$asc" ]]; then
    key="$(find "$asc" -maxdepth 1 -name 'AuthKey_*.p8' -print -quit)"
    if [[ -f "$asc/issuer-id.txt" ]]; then
      issuer="$(tr -d '[:space:]' <"$asc/issuer-id.txt")"
    fi
  fi
  if [[ -n "$key" && -n "$issuer" ]]; then
    local key_id
    key_id="$(basename "$key" .p8)"
    key_id="${key_id#AuthKey_}"
    AUTH=(--key "$key" --key-id "$key_id" --issuer "$issuer")
    return
  fi
  echo "error: no notarization credentials." >&2
  echo "Set APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER, or store a notarytool profile named futuraterm." >&2
  exit 1
}

resolve_auth

echo "submitting $(basename "$ARTIFACT") for notarization"
if ! xcrun notarytool submit "$ARTIFACT" --wait --progress "${AUTH[@]}"; then
  echo "error: notarization failed for $ARTIFACT" >&2
  exit 1
fi

xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "stapled $ARTIFACT"
