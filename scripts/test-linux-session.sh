#!/usr/bin/env bash
# Portable unit test of the Linux session/zmx argv helper. Runs on macOS and Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ft-linux-test-session-$$"
cc -O2 -Wall -Wextra -o "$OUT" "$ROOT/linux/tests/test_session.c" "$ROOT/linux/src/session.c"
"$OUT"
rm -f "$OUT"
DESKTOP="$ROOT/linux/share/applications/com.davidsolheim.futuraterm.desktop"
test -f "$DESKTOP"
grep -q '^Name=FuturaTerm$' "$DESKTOP"
grep -q '^Exec=futuraterm$' "$DESKTOP"
grep -q '^Categories=System;TerminalEmulator;$' "$DESKTOP"
grep -q '^StartupWMClass=com.davidsolheim.futuraterm$' "$DESKTOP"
test -f "$ROOT/linux/share/icons/hicolor/256x256/apps/com.davidsolheim.futuraterm.png"
test -f "$ROOT/linux/packaging/install.sh"
grep -q 'share/applications' "$ROOT/linux/packaging/install.sh"
