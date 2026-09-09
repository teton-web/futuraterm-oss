#!/usr/bin/env bash
# Sign a FuturaTerm.app (and nested Mach-O) with a Developer ID identity.
#
# Xcode's archive already signs most of the bundle, but post-build copies
# (the bundled `futuraterm` CLI, zmx, the ghostty shim) land after the first
# seal. Notarization rejects unsigned or ad-hoc nested binaries, so this
# re-signs inside-out, then the outer app with our entitlements.
set -euo pipefail

usage() {
  echo "usage: codesign-release.sh --app <FuturaTerm.app> --identity <identity> [--entitlements <plist>]" >&2
  exit 2
}

APP=""
IDENTITY=""
ENTITLEMENTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --entitlements) ENTITLEMENTS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$APP" && -d "$APP" && -n "$IDENTITY" ]] || usage

is_macho() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  local desc
  desc="$(file -b "$f" 2>/dev/null || true)"
  [[ "$desc" == *Mach-O* ]]
}

sign_item() {
  local path="$1"
  local ents ents_args=()
  ents="$(mktemp)"
  if codesign --display --xml --entitlements "$ents" "$path" >/dev/null 2>&1 && [[ -s "$ents" ]]; then
    ents_args=(--entitlements "$ents")
  fi
  # Bash 3.2 + `set -u` rejects "${arr[@]}" on an empty array.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    ${ents_args[@]+"${ents_args[@]}"} "$path"
  rm -f "$ents"
}

# Deepest paths first so frameworks/XPCs are sealed before the bundle that
# contains them.
while IFS= read -r path; do
  [[ "$path" == "$APP" ]] && continue
  sign_item "$path"
done < <(
  {
    find "$APP" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.so" \) -print
    find "$APP" -type f -print
  } | awk '{ print length($0), $0 }' | sort -nr | while read -r _ p; do
    if [[ -d "$p" || -L "$p" ]]; then
      echo "$p"
    elif is_macho "$p"; then
      echo "$p"
    fi
  done | awk 'NF && !seen[$0]++'
)

APP_SIGN_ARGS=()
if [[ -n "$ENTITLEMENTS" ]]; then
  APP_SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  ${APP_SIGN_ARGS[@]+"${APP_SIGN_ARGS[@]}"} "$APP"

codesign --verify --deep --strict "$APP"
echo "signed $APP with $IDENTITY"
