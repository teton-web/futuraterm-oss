#!/usr/bin/env bash
# Archive the AppStore configuration with Apple Distribution.
# No notarize, no Sparkle public-key override, no DMG — MAS ships via ASC.
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# shellcheck source=scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(read_marketing_version "$VERSION_FILE")"
fi

# App Store CFBundleVersion ≤ 3 period-separated integers. Direct/Sparkle
# stamping in build.sh keeps sparkle_comparison_version (4 components).
BUILD_NUMBER="$(mas_bundle_version "$VERSION")"
GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Apple Distribution (not Developer ID). Env names only — never a p12 in git:
# FUTURATERM_MAS_CODESIGN_IDENTITY, FUTURATERM_MAS_SIGNING_CERT_P12,
# FUTURATERM_MAS_SIGNING_CERT_PASSWORD, FUTURATERM_MAS_PROVISIONING_PROFILE,
# FUTURATERM_DEVELOPMENT_TEAM.
TETON_MAS_ID="Apple Distribution: Teton Web Ventures LLC (3SDKZLQW7P)"
TETON_TEAM_ID="3SDKZLQW7P"
CODESIGN_IDENTITY="${FUTURATERM_MAS_CODESIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${FUTURATERM_DEVELOPMENT_TEAM:-}"
if [[ -z "$CODESIGN_IDENTITY" ]] \
  && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$TETON_MAS_ID"; then
  CODESIGN_IDENTITY="$TETON_MAS_ID"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$TETON_TEAM_ID}"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  echo "ERROR: Apple Distribution identity not found." >&2
  echo "Create 'Apple Distribution: Teton Web Ventures LLC (3SDKZLQW7P)' in Certificates, Identifiers & Profiles for Apple ID david@tetonweb.com, or set FUTURATERM_MAS_CODESIGN_IDENTITY." >&2
  echo "MAS archives must not fall back to ad-hoc signing." >&2
  exit 1
fi

SIGNING_OVERRIDES=(
  CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
  CODE_SIGN_STYLE=Manual
  OTHER_CODE_SIGN_FLAGS="--timestamp"
)
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  SIGNING_OVERRIDES+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi
PROFILE_SPECIFIER="${FUTURATERM_MAS_PROVISIONING_PROFILE_SPECIFIER:-}"
if [[ -n "$PROFILE_SPECIFIER" ]]; then
  SIGNING_OVERRIDES+=(PROVISIONING_PROFILE_SPECIFIER="$PROFILE_SPECIFIER")
fi

DERIVED_DATA="$BUILD_DIR/DerivedData-mas"
ARCHIVE_PATH="$BUILD_DIR/FuturaTerm-AppStore.xcarchive"
EXPORT_PATH="$BUILD_DIR/export-mas"

"$PROJECT_ROOT/scripts/setup.sh"
xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

xcodebuild \
  -project FuturaTerm.xcodeproj \
  -scheme FuturaTerm \
  -configuration AppStore \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_COMMIT" \
  "${SIGNING_OVERRIDES[@]}" \
  archive \
  | (xcbeautify --quiet 2>/dev/null || cat)

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/FuturaTerm.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: $ARCHIVED_APP not found in archive" >&2
  exit 1
fi
mkdir -p "$EXPORT_PATH"
ditto "$ARCHIVED_APP" "$EXPORT_PATH/FuturaTerm.app"

APP_BUNDLE="$EXPORT_PATH/FuturaTerm.app"
# xcodegen cannot drop the Sparkle SPM product per configuration.
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
find "$APP_BUNDLE" -name 'Sparkle*' -print -delete 2>/dev/null || true
python3 "$PROJECT_ROOT/scripts/strip-sparkle-dylib.py" "$APP_BUNDLE/Contents/MacOS/FuturaTerm"
"$PROJECT_ROOT/scripts/codesign-release.sh" \
  --app "$APP_BUNDLE" \
  --identity "$CODESIGN_IDENTITY" \
  --entitlements "$PROJECT_ROOT/FuturaTerm/FuturaTerm.mas.entitlements"

if codesign --display --verbose "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
  echo "ERROR: $APP_BUNDLE is ad-hoc signed despite Apple Distribution being required" >&2
  exit 1
fi

# exportArchive reads the xcarchive, not export-mas/. Put the Sparkle-stripped
# re-signed app back so ASC upload matches local mise run build-mas.
rm -rf "$ARCHIVED_APP"
ditto "$APP_BUNDLE" "$ARCHIVED_APP"
if [[ -d "$ARCHIVED_APP/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "ERROR: Sparkle.framework still present in $ARCHIVED_APP after strip" >&2
  exit 1
fi

echo "Done: $ARCHIVE_PATH"
echo "Copied app: $APP_BUNDLE"
