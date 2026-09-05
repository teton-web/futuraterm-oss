#!/usr/bin/env bash
# Portable unit test of the Linux session/zmx argv helper. Runs on macOS and Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ft-linux-test-session-$$"
cc -O2 -Wall -Wextra -o "$OUT" "$ROOT/linux/tests/test_session.c" "$ROOT/linux/src/session.c"
"$OUT"
rm -f "$OUT"
