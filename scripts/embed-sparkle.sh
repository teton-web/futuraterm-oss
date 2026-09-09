#!/usr/bin/env bash
# Embed Sparkle.framework into Direct (Debug/Release) app bundles, or strip
# it from AppStore products.
#
# xcodegen cannot omit an SPM product per configuration, so AppStore still
# lists Sparkle with link:false / embed:false. Direct still needs the
# framework in Contents/Frameworks (Xcode will not copy it). AppStore must
# not ship it — strip the bundle copy and the remaining load commands.
#
# Do not use `$BUILD_DIR/../../SourcePackages` as the only lookup. That
# resolves for a normal build (BUILD_DIR is DerivedData/Build/Products) and
# misses during `xcodebuild archive` (BUILD_DIR is
# DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/<scheme>/BuildProductsPath).
# Walk up from the Xcode dirs until SourcePackages exists.
set -euo pipefail

srcroot="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sparkle_artifact_under() {
  local root="$1"
  local cand
  for cand in "${root}"/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
    if [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

find_sparkle_framework() {
  local cand d start
  for start in \
    "${BUILD_DIR:-}" \
    "${BUILT_PRODUCTS_DIR:-}" \
    "${CONFIGURATION_BUILD_DIR:-}" \
    "${OBJROOT:-}"
  do
    [ -n "$start" ] || continue
    d="$start"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if sparkle_artifact_under "$d"; then
        return 0
      fi
      d=$(dirname "$d")
    done
  done

  for cand in \
    "${CONFIGURATION_BUILD_DIR:-}/Sparkle.framework" \
    "${BUILT_PRODUCTS_DIR:-}/Sparkle.framework" \
    "${BUILD_DIR:-}/Sparkle.framework" \
    "${BUILD_DIR:-}/${CONFIGURATION:-}/Sparkle.framework"
  do
    if [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  for cand in \
    "${srcroot}/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-"*/Sparkle.framework \
    "${srcroot}/build/DerivedData-mas/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-"*/Sparkle.framework
  do
    if [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

if [ "${1:-}" = "--find" ]; then
  find_sparkle_framework
  exit $?
fi

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
  echo "error: embed-sparkle.sh must run inside an Xcode build phase (missing BUILT_PRODUCTS_DIR)" >&2
  exit 1
fi

FW="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
mkdir -p "$FW"

if [ "${CONFIGURATION:-}" = "AppStore" ]; then
  rm -rf "$FW/Sparkle.framework"
  find "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH" -name 'Sparkle*' -print -delete 2>/dev/null || true
  python3 "$srcroot/scripts/strip-sparkle-dylib.py" "$BUILT_PRODUCTS_DIR/$EXECUTABLE_PATH"
  exit 0
fi

SRC=$(find_sparkle_framework) || {
  echo "error: Sparkle.framework not found for Direct embed" >&2
  exit 1
}
rsync -a --delete "$SRC/" "$FW/Sparkle.framework/"
