#!/usr/bin/env bash
# Build native Linux FuturaTerm (ELF). Does not invoke xcodebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/linux"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "scripts/build-linux.sh produces an ELF and must run on Linux (e.g. dts-3)." >&2
  echo "The portable linux/tests suite still runs here:" >&2
  "$ROOT/scripts/test-linux-session.sh"
  echo "On Omarchy: rsync this tree and run: ./scripts/build-linux.sh" >&2
  exit 0
fi

if ! pkg-config --exists gtk4 vterm cairo pangocairo; then
  echo "missing pkg-config modules: gtk4 vterm cairo pangocairo" >&2
  echo "Arch/Omarchy: pacman -S --needed gtk4 libvterm cairo pango" >&2
  exit 1
fi

make -C "$ROOT/linux" all test
file "$ROOT/linux/futuraterm-linux"
