#!/bin/sh
# Install FuturaTerm as an XDG desktop app (~/.local). Super+Space finds it.
# Unattended: one sudo for every missing pacman dep, no per-package prompts.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PREFIX="${FUTURATERM_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"
DESKTOP_ID="com.davidsolheim.futuraterm"

pacman_noconfirm() {
  # One transaction, never "Install foo? [Y/n]" per package.
  if sudo -n true >/dev/null 2>&1; then
    sudo -n pacman -S --needed --noconfirm --noprogressbar "$@"
  else
    sudo pacman -S --needed --noconfirm --noprogressbar "$@"
  fi
}

ensure_runtime_packages() {
  if ! command -v pacman >/dev/null 2>&1; then
    return 0
  fi
  missing=""
  for p in gtk4 libvterm cairo pango; do
    if ! pacman -Q "$p" >/dev/null 2>&1; then
      missing="$missing $p"
    fi
  done
  missing=${missing# }
  if [ -z "$missing" ]; then
    return 0
  fi
  echo "Installing runtime packages (one shot): $missing"
  pacman_noconfirm $missing
}

ensure_zmx() {
  if command -v zmx >/dev/null 2>&1; then
    return 0
  fi
  if [ -x "$HOME/.local/bin/zmx" ]; then
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  if command -v mise >/dev/null 2>&1; then
    echo "Installing zmx with mise (unattended)"
    MISE_YES=1 mise use -g zmx --yes </dev/null
    if command -v mise >/dev/null 2>&1; then
      REAL="$(mise which zmx 2>/dev/null || true)"
      if [ -n "$REAL" ] && [ -x "$REAL" ]; then
        cp -f "$REAL" "$HOME/.local/bin/zmx"
        chmod 755 "$HOME/.local/bin/zmx"
        return 0
      fi
    fi
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64 | amd64) A=x86_64 ;;
    aarch64 | arm64) A=aarch64 ;;
    *)
      echo "error: zmx is missing and arch ${ARCH} has no tarball fallback." >&2
      return 1
      ;;
  esac
  echo "Installing zmx tarball to ~/.local/bin"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/futuraterm-zmx.XXXXXX")"
  for VER in 0.8.1 0.8.0 0.7.0; do
    if curl -fsSL "https://zmx.sh/a/zmx-${VER}-linux-${A}.tar.gz" -o "$tmp/zmx.tgz"; then
      tar -xzf "$tmp/zmx.tgz" -C "$tmp"
      BIN="$(find "$tmp" -type f -name zmx | head -1)"
      if [ -n "$BIN" ]; then
        cp -f "$BIN" "$HOME/.local/bin/zmx"
        chmod 755 "$HOME/.local/bin/zmx"
        rm -rf "$tmp"
        return 0
      fi
    fi
  done
  rm -rf "$tmp"
  echo "error: could not install zmx (needed for FuturaTerm sessions)." >&2
  return 1
}

ensure_runtime_packages
ensure_zmx

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
