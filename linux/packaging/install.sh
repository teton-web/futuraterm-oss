#!/bin/sh
# Install FuturaTerm as an XDG desktop app (~/.local). Super+Space finds it.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PREFIX="${FUTURATERM_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"
DESKTOP_ID="com.davidsolheim.futuraterm"

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
install -m 755 "$ROOT/bin/futuraterm" "$BIN_DIR/futuraterm"
install -m 644 "$ROOT/share/icons/hicolor/256x256/apps/${DESKTOP_ID}.png" \
  "$ICON_DIR/${DESKTOP_ID}.png"

# Pin Exec to the installed binary so Walker/Hyprland do not depend on PATH.
sed "s|^Exec=.*|Exec=${BIN_DIR}/futuraterm|" \
  "$ROOT/share/applications/${DESKTOP_ID}.desktop" > "$APP_DIR/${DESKTOP_ID}.desktop"
chmod 644 "$APP_DIR/${DESKTOP_ID}.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed FuturaTerm to ${BIN_DIR}/futuraterm"
echo "Launcher: Super+Space, type FuturaTerm"
