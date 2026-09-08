# Linux FuturaTerm

Native Linux frontend for FuturaTerm. This is **not** the macOS `.app` and not
an SSH remote project from a Mac.

The GhosttyKit embed API (`ghostty.h`) only defines `GHOSTTY_PLATFORM_MACOS`
and `GHOSTTY_PLATFORM_IOS` (Metal). Omarchy ships `libghostty-vt` (parser /
key encode, no surface, no pty). This binary is a GTK4 **FuturaTerm workspace**:

- persisted project sidebar (open/create/select/rename/unload/remove — local folders and `[user@]host:dir` remotes)
- tabs (new/close/rename, in-project and global next/prev, recent) and pinned tabs
- split tree (split right/down/auto, focus, resize, zoom, separate, close)
- YAML layouts in `~/.config/futuraterm/projects/`
- each leaf is a zmx session `futuraterm-<projectslug>-<hex>` (remote panes are `ssh` + host zmx, not nested local zmx)
- command palette, Settings (General / Projects / Appearance / Quick Terminal / Keymaps), quick-terminal overlay
- VT screen via libvterm + cairo; font/palette from XDG Ghostty config
- `futuraterm` CLI over `$XDG_RUNTIME_DIR/futuraterm/control.sock`

This is the Linux sibling of the macOS SwiftUI app, not a recompile of `platform: macOS`. Sparkle, Metal/libghostty-internal, and liquid glass are macOS-only.

## Build (on Linux)

```bash
./scripts/build-linux.sh
./linux/futuraterm-linux
```

## Install as an Omarchy app

From the site (pulls the tarball from [teton-web/futuraterm-oss](https://github.com/teton-web/futuraterm-oss/releases/latest)):

```bash
curl -fsSL https://futuraterm.com/install-linux.sh | sh
```

That installs `~/.local/bin/futuraterm`, an XDG `.desktop` file, the icon,
and Sunshine so a Mac can View Desktop this machine (Moonlight is the client
on the Mac). The installer configures Sunshine admin; first View Desktop
pairs automatically. If pairing cannot run, the PIN page is
https://localhost:47990. Super+Space then finds **FuturaTerm**.

From this tree, after `./scripts/package-linux.sh`:

```bash
tar -xzf linux/dist/FuturaTerm-*-linux-x86_64.tar.gz
./FuturaTerm-*-linux-x86_64/install.sh
```

Needs `gtk4`, `libvterm`, `cairo`, `pango` (present on Omarchy).

## Control

```bash
./linux/futuraterm-linux                          # GUI
./linux/futuraterm-linux status
./linux/futuraterm-linux project list
./linux/futuraterm-linux tab new
./linux/futuraterm-linux pane split --direction right
./linux/futuraterm-linux pane run --session NAME -- printf hello
./linux/futuraterm-linux pane dump --session NAME
./linux/futuraterm-linux layout save
```

Socket: `$XDG_RUNTIME_DIR/futuraterm/control.sock` (override with `--socket` or `FUTURATERM_SOCKET`).

Quick terminal is an in-app overlay (`ctrl+grave` by default). On Hyprland, bind the same chord globally if you want it from other apps:

```
bind = CTRL, grave, exec, futuraterm pane dump >/dev/null 2>&1 || true
```

(or map Super+Space to the `.desktop` file and use the in-app shortcut).

## Tests

```bash
./scripts/test-linux-session.sh   # portable; also runs on macOS
```
