#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# shellcheck source=scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Local Release builds read VERSION and bump the patch after a successful
# archive so the next install is 0.1.2, 0.1.3, … CI always passes VERSION
# from the git tag and must not rewrite the file.
AUTO_BUMP=0
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(read_marketing_version "$VERSION_FILE")"
  AUTO_BUMP=1
fi

# Sparkle compares CFBundleVersion against the appcast's sparkle:version when
# deciding whether an update is newer, so the two must agree exactly — both go
# through `sparkle_comparison_version` (see _lib.sh for why a raw `-beta.N`
# string can't be used, and why a commit count can't either: it can stay equal
# across two tags built from the same commit and trip "You're up to date").
# CFBundleShortVersionString keeps the human-readable $VERSION for display.
BUILD_NUMBER="$(sparkle_comparison_version "$VERSION")"
GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER}"

# Developer ID signing. macOS TCC keys privacy grants to the app's designated
# requirement, so every distributed build must use the SAME certificate:
# "Developer ID Application: Teton Web Ventures LLC (3SDKZLQW7P)" (Apple ID
# david@tetonweb.com). Ad-hoc is the project.yml default for local/debug/bench.
#
# If FUTURATERM_CODESIGN_IDENTITY is unset, a machine that already has that
# identity in the keychain (this one) uses it; otherwise the archive stays
# ad-hoc. CI imports the .p12 and sets the identity explicitly.
TETON_DEVELOPER_ID="Developer ID Application: Teton Web Ventures LLC (3SDKZLQW7P)"
TETON_TEAM_ID="3SDKZLQW7P"
CODESIGN_IDENTITY="${FUTURATERM_CODESIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${FUTURATERM_DEVELOPMENT_TEAM:-}"
if [[ -z "$CODESIGN_IDENTITY" ]] \
  && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$TETON_DEVELOPER_ID"; then
  CODESIGN_IDENTITY="$TETON_DEVELOPER_ID"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$TETON_TEAM_ID}"
fi
SIGNING_OVERRIDES=()
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  SIGNING_OVERRIDES+=(
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    SIGNING_OVERRIDES+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  fi
fi
DMG_NAME="FuturaTerm-${VERSION}.dmg"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/FuturaTerm.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Ensure GhosttyKit + bundled resources (themes, shell-integration) are present
# before xcodegen resolves the folder references. Idempotent; no-op in CI where
# ci:setup already ran.
"$PROJECT_ROOT/scripts/setup.sh"

# Regenerate the Xcode project so any project.yml edits land in CI builds
# without requiring a developer to commit the generated .xcodeproj.
xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Archive: Xcode handles universal binary arch ($(ARCHS_STANDARD) is
# arm64+x86_64 in Release), embeds Sparkle.framework, signs everything
# (including Sparkle's XPC services) with the configured identity, and
# substitutes our Info.plist build-setting tokens.
xcodebuild \
  -project FuturaTerm.xcodeproj \
  -scheme FuturaTerm \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_COMMIT" \
  SPARKLE_ED_PUBLIC_KEY="$SPARKLE_ED_PUBLIC_KEY" \
  ${SIGNING_OVERRIDES[@]+"${SIGNING_OVERRIDES[@]}"} \
  archive \
  | (xcbeautify --quiet 2>/dev/null || cat)

# Copy the .app straight out of the archive. `ditto` (not cp) preserves the
# framework symlinks a valid macOS bundle needs.
#
# This deliberately avoids `xcodebuild -exportArchive`: its `-exportOptionsPlist`
# `method` value is unstable across Xcode releases (Apple renamed the macOS
# export methods in Xcode 16, breaking the old `mac-application` value — the
# failure that motivated this). A direct copy has no version-sensitive tokens.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/FuturaTerm.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: $ARCHIVED_APP not found in archive" >&2
  exit 1
fi
mkdir -p "$EXPORT_PATH"
ditto "$ARCHIVED_APP" "$EXPORT_PATH/FuturaTerm.app"

APP_BUNDLE="$EXPORT_PATH/FuturaTerm.app"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  "$PROJECT_ROOT/scripts/codesign-release.sh" \
    --app "$APP_BUNDLE" \
    --identity "$CODESIGN_IDENTITY" \
    --entitlements "$PROJECT_ROOT/FuturaTerm/FuturaTerm.entitlements"
fi
# Sanity-check the copy is a valid, signed bundle before building a DMG from it.
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
  echo "ERROR: exported $APP_BUNDLE failed code-signature verification" >&2
  exit 1
fi
# When a stable identity was requested, an ad-hoc signature slipping through
# would ship an update that silently resets every user's TCC grants — exactly
# what the identity exists to prevent — so fail rather than package it.
if [[ -n "$CODESIGN_IDENTITY" ]] \
  && codesign --display --verbose "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
  echo "ERROR: $APP_BUNDLE is ad-hoc signed despite a Developer ID identity being set" >&2
  exit 1
fi

# Package into a compressed DMG with an Applications symlink for drag-install.
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create -volname "FuturaTerm" -srcfolder "$DMG_STAGING" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"
rm -rf "$DMG_STAGING"

DMG_PATH="$BUILD_DIR/$DMG_NAME"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

# Notarize distributed builds. CI sets FUTURATERM_NOTARIZE=1. A Developer ID
# signature without a staple still trips Gatekeeper on download.
if [[ "${FUTURATERM_NOTARIZE:-}" == "1" ]]; then
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "ERROR: FUTURATERM_NOTARIZE=1 requires a Developer ID identity" >&2
    exit 1
  fi
  "$PROJECT_ROOT/scripts/notarize.sh" "$DMG_PATH"
fi

echo "Done: build/$DMG_NAME"
if [[ "$AUTO_BUMP" == "1" ]]; then
  next="$(bump_patch_version "$VERSION")"
  printf '%s\n' "$next" >"$VERSION_FILE"
  echo "Next local Release will be $next"
fi
