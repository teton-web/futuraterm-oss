<!-- page:
slug: install
title: Installation
nav: Installation
group: Getting started
description: Build FuturaTerm from source.
-->

# Installation

FuturaTerm is not on Homebrew yet. Build it from source.

## From source

Requires macOS 26+ and full Xcode 26 to build. The app runs on macOS 14+.

```sh
git clone https://github.com/davidsolheim/futuraterm.git
cd futuraterm
mise install
mise run setup
mise run run
```

`mise run run` launches **FuturaTerm Debug**, which uses its own bundle ID and Application Support directory.

To install a Release build:

```sh
mise run build
mise run install
```

That copies `FuturaTerm.app` to `/Applications`. Auto-update is disabled until FuturaTerm has its own signing keys and feed. Clear Gatekeeper quarantine if macOS blocks the first launch:

```sh
xattr -cr /Applications/FuturaTerm.app
```

Project YAML lives in `~/.config/futuraterm/projects/`. The control CLI inside a pane is `futuraterm`.
