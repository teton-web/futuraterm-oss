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

# Sunshine hosts View Desktop for Mac Moonlight. moonlight-qt on this
# machine is the client and is optional. Prefer Omarchy's helper when
# present; never enable the sunshine.service alias first (LizardByte's
# unit is app-dev.lizardbyte.app.Sunshine.service).
ensure_desktop_host() {
  if ! command -v sunshine >/dev/null 2>&1; then
    if command -v omarchy-install-service-sunshine >/dev/null 2>&1; then
      echo "Installing Sunshine (View Desktop host) via Omarchy"
      # Helper enables the sunshine.service alias, which systemd refuses
      # (linked unit). Package install still succeeds; we enable the real
      # LizardByte unit below.
      omarchy-install-service-sunshine >/dev/null 2>&1 || true
    fi
    if ! command -v sunshine >/dev/null 2>&1 \
      && command -v pacman >/dev/null 2>&1 && pacman -Si sunshine >/dev/null 2>&1; then
      echo "Installing Sunshine (View Desktop host)"
      pacman_noconfirm sunshine
    fi
  fi
  if ! command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine is not in this distro's repos; View Desktop host is skipped."
    return 0
  fi
  open_sunshine_ports
  enable_sunshine_user_unit
  refresh_sunshine_admin
  echo "View Desktop host: Sunshine streams this screen to Moonlight."
  echo "First View Desktop from a Mac pairs automatically."
}

SUNSHINE_USER_UNIT="app-dev.lizardbyte.app.Sunshine.service"

enable_sunshine_user_unit() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  # Never enable sunshine.service — it is a symlink and systemd errors
  # "Refusing to operate on linked unit file" (omarchy#7050).
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "$SUNSHINE_USER_UNIT" >/dev/null 2>&1 \
    || systemctl --user start "$SUNSHINE_USER_UNIT" >/dev/null 2>&1 \
    || true
}

sunshine_admin_password() {
  if [ -n "${FUTURATERM_SUNSHINE_PASSWORD:-}" ]; then
    printf '%s' "$FUTURATERM_SUNSHINE_PASSWORD"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n/+=\n' | cut -c1-24
    return 0
  fi
  dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '\n/+=\n' | cut -c1-24
}

ensure_sunshine_origin_conf() {
  conf="$HOME/.config/sunshine/sunshine.conf"
  mkdir -p "$HOME/.config/sunshine"
  if [ ! -f "$conf" ] || ! grep -q '^origin_web_ui_allowed' "$conf"; then
    printf '\norigin_web_ui_allowed = pc\n' >> "$conf"
  fi
  if command -v sunshine >/dev/null 2>&1; then
    if strings "$(command -v sunshine)" 2>/dev/null | grep -q origin_pin_allowed; then
      if ! grep -q '^origin_pin_allowed' "$conf"; then
        printf 'origin_pin_allowed = wan\n' >> "$conf"
      fi
    fi
  fi
}

refresh_sunshine_admin() {
  if ! command -v sunshine >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$HOME/.config/sunshine" "$HOME/.config/futuraterm"
  ensure_sunshine_origin_conf
  user="$(id -un 2>/dev/null || printf '%s' "${USER:-futuraterm}")"
  pass="$(sunshine_admin_password)"
  if [ -z "$pass" ]; then
    return 0
  fi
  # Every install/upgrade rewrites Sunshine's login and our 0600 copy.
  # Skipping when a username already exists left the 401 admin page as a
  # user step on machines that had been set up before.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop "$SUNSHINE_USER_UNIT" >/dev/null 2>&1 || true
  fi
  if sunshine --creds "$user" "$pass" >/dev/null 2>&1; then
    old_umask="$(umask)"
    umask 077
    printf 'username=%s\npassword=%s\n' "$user" "$pass" > "$HOME/.config/futuraterm/sunshine-admin"
    chmod 600 "$HOME/.config/futuraterm/sunshine-admin"
    umask "$old_umask"
  fi
  enable_sunshine_user_unit
}

open_sunshine_ports() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  comment="futuraterm-sunshine"
  for port in 47984 47989 48010; do
    sudo ufw allow in proto tcp from 10.0.0.0/8 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    sudo ufw allow in proto tcp from 172.16.0.0/12 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    sudo ufw allow in proto tcp from 192.168.0.0/16 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    if ip link show tailscale0 >/dev/null 2>&1; then
      sudo ufw allow in on tailscale0 to any port "$port" proto tcp comment "$comment" >/dev/null 2>&1 || true
    fi
  done
  for port in 5353 47998 47999 48000 48002 48010; do
    sudo ufw allow in proto udp from 10.0.0.0/8 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    sudo ufw allow in proto udp from 172.16.0.0/12 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    sudo ufw allow in proto udp from 192.168.0.0/16 to any port "$port" comment "$comment" >/dev/null 2>&1 || true
    if ip link show tailscale0 >/dev/null 2>&1; then
      sudo ufw allow in on tailscale0 to any port "$port" proto udp comment "$comment" >/dev/null 2>&1 || true
    fi
  done
  sudo ufw reload >/dev/null 2>&1 || true
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
ensure_desktop_host
ensure_zmx

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
install -m 755 "$ROOT/bin/futuraterm" "$BIN_DIR/futuraterm"
if [ -f "$ROOT/bin/futuraterm-sunshine-pair" ]; then
  install -m 755 "$ROOT/bin/futuraterm-sunshine-pair" "$BIN_DIR/futuraterm-sunshine-pair"
elif [ -f "$ROOT/futuraterm-sunshine-pair" ]; then
  install -m 755 "$ROOT/futuraterm-sunshine-pair" "$BIN_DIR/futuraterm-sunshine-pair"
fi
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
