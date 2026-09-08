#!/bin/sh
# Grok Bot → FuturaTerm handoff (POR-348).
#
# Open (or select) a project, reuse-or-create a grok pane, print its zmx
# session, and optionally type a prompt. Pin the nested CLI so Debug never
# talks to Release:
#
#   FUTURATERM_CLI=/Applications/FuturaTerm.app/Contents/Resources/bin/futuraterm \
#     ./scripts/grok-bot-handoff.sh /absolute/or/~project [prompt words...]
#
# Grok Bot must pass --cli or FUTURATERM_CLI (the nested
# Contents/Resources/bin/futuraterm). PATH is only a convenience inside a pane.
# Auto-launches the companion .app unless you add --no-launch / --socket
# (not used here). project create is not idempotent — this uses project open.
# futuraterm://open?path= cannot pass run=; drive grok through this CLI.
#
# Live flags (from --help / CLI/FuturaTermCommand.swift): --run, --no-reuse,
# --json, --no-launch, --socket. Exit 0 ok / 1 app error / 2 unreachable.
#
# After open, drive the pane (POR-424; still nested CLI, never socket JSON):
#   pane dump --quiet-ms 300 --json
#   pane choices --json / pane choose 2
#   pane select --line 1 / pane selection
#   pane click --col --row
# VoiceOver/AX: terminal is a text area; Grok Bot still uses this CLI.

set -eu

usage() {
  printf '%s\n' "usage: grok-bot-handoff.sh [--cli PATH] [--no-reuse] <project-dir> [prompt...]" >&2
  exit 1
}

cli=${FUTURATERM_CLI:-}
reuse=1
path=
while [ $# -gt 0 ]; do
  case "$1" in
    --cli)
      [ $# -ge 2 ] || usage
      cli=$2
      shift 2
      ;;
    --no-reuse)
      reuse=0
      shift
      ;;
    -*)
      usage
      ;;
    *)
      path=$1
      shift
      break
      ;;
  esac
done

[ -n "$path" ] || usage

if [ -z "$cli" ]; then
  if command -v futuraterm >/dev/null 2>&1; then
    cli=$(command -v futuraterm)
  elif [ -x /Applications/FuturaTerm.app/Contents/Resources/bin/futuraterm ]; then
    cli=/Applications/FuturaTerm.app/Contents/Resources/bin/futuraterm
  elif [ -x /Applications/FuturaTermDebug.app/Contents/Resources/bin/futuraterm ]; then
    cli=/Applications/FuturaTermDebug.app/Contents/Resources/bin/futuraterm
  else
    printf '%s\n' "futuraterm CLI not found; pass --cli or set FUTURATERM_CLI to Contents/Resources/bin/futuraterm" >&2
    exit 2
  fi
fi

# Keep --run/--json/--no-reuse on the open verb. Do not use project create.
if [ "$reuse" -eq 0 ]; then
  json=$("$cli" project open "$path" --run grok --no-reuse --json)
else
  json=$("$cli" project open "$path" --run grok --json)
fi

# CLI --json prints the data payload (panes[0].session), not {ok,data}.
session=
if command -v python3 >/dev/null 2>&1; then
  session=$(printf '%s\n' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"panes\"][0][\"session\"])") || session=
fi
if [ -z "$session" ]; then
  session=$(printf '%s\n' "$json" | awk -F '"' '/"session"[[:space:]]*:/{ print $4; exit }')
fi
if [ -z "$session" ]; then
  printf '%s\n' "project open --run grok --json did not return panes[0].session" >&2
  printf '%s\n' "$json" >&2
  exit 1
fi

printf '%s\n' "$session"

if [ $# -gt 0 ]; then
  "$cli" pane run --session "$session" -- "$@"
  "$cli" pane dump --session "$session"
fi
