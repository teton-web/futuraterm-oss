# Linux FuturaTerm

Native Linux frontend for FuturaTerm. This is **not** the macOS `.app` and not
an SSH remote project from a Mac.

The GhosttyKit embed API (`ghostty.h`) only defines `GHOSTTY_PLATFORM_MACOS`
and `GHOSTTY_PLATFORM_IOS` (Metal). Omarchy ships `libghostty-vt` (parser /
key encode, no surface, no pty). This binary is a GTK4 **FuturaTerm app** (not a single naked terminal):

- sidebar of projects (`$HOME` plus `$HOME/GitHub/*`, lazy-spawned like macOS)
- tabs (Ctrl+T / New Tab)
- split panes (Ctrl+D right, Ctrl+Shift+D down)
- each leaf is a **local** zmx session (`futuraterm-<project>-<hex>`)
- VT screen via libvterm + cairo
- control socket (`$XDG_RUNTIME_DIR/futuraterm-linux.sock`) for `dump` / `run` and JSON (`status`, `project.list`, `pane.list`, `pane.dump`, `pane.run`, `pane.split`, `tab.new`)

This is the Linux sibling of the macOS SwiftUI app, not a recompile of `platform: macOS`. Sparkle, Metal/libghostty-internal, and liquid glass are macOS-only.

## Build (on Linux)

```bash
./scripts/build-linux.sh
./linux/futuraterm-linux
```

Needs `gtk4`, `libvterm`, `cairo`, `pango` (present on Omarchy).

## Control

```bash
./linux/futuraterm-linux --session linux          # GUI
./linux/futuraterm-linux dump --session linux     # screen text
./linux/futuraterm-linux run --session linux 'printf hello; echo'
```

Socket: `$XDG_RUNTIME_DIR/futuraterm-linux-<session>.sock`

## Tests

```bash
./scripts/test-linux-session.sh   # portable; also runs on macOS
```
