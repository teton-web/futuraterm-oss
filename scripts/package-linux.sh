#!/usr/bin/env bash
# Build FuturaTerm-*-linux-x86_64.tar.gz (XDG desktop app layout).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64) ARCH=x86_64 ;;
  aarch64 | arm64) ARCH=aarch64 ;;
esac
NAME="FuturaTerm-${VERSION}-linux-${ARCH}"
STAGE="${ROOT}/linux/dist/${NAME}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: package-linux.sh must run on Linux" >&2
  exit 1
fi

"$ROOT/scripts/build-linux.sh"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/applications" \
  "$STAGE/share/icons/hicolor/256x256/apps"
install -m 755 "$ROOT/linux/futuraterm-linux" "$STAGE/bin/futuraterm"
install -m 755 "$ROOT/linux/packaging/futuraterm-sunshine-pair" \
  "$STAGE/bin/futuraterm-sunshine-pair"
install -m 644 "$ROOT/linux/share/applications/com.davidsolheim.futuraterm.desktop" \
  "$STAGE/share/applications/"
install -m 644 "$ROOT/linux/share/icons/hicolor/256x256/apps/com.davidsolheim.futuraterm.png" \
  "$STAGE/share/icons/hicolor/256x256/apps/"
install -m 755 "$ROOT/linux/packaging/install.sh" "$STAGE/install.sh"
(
  cd "$ROOT/linux/dist"
  tar -czf "${NAME}.tar.gz" "$NAME"
  cp -f "${NAME}.tar.gz" "FuturaTerm-linux-${ARCH}.tar.gz"
  sha256sum "${NAME}.tar.gz" "FuturaTerm-linux-${ARCH}.tar.gz" > SHA256SUMS
)
echo "$ROOT/linux/dist/${NAME}.tar.gz"
