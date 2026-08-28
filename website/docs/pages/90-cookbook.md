<!-- page:
slug: cookbook
title: Cookbook
nav: Cookbook
group: Community
description: Community-shared FuturaTerm workflows and recipes — read what others run, and post your own.
-->

# Cookbook

The [**Cookbook**](https://github.com/davidsolheim/futuraterm/discussions/categories/cookbook) is a discussion category for workflows and recipes — the layouts, keybinds, and scripts people actually run to get more out of FuturaTerm. Anyone can post, and anyone can borrow.

Three to start with:

- **Navigating `nvim` and FuturaTerm with the same keybinds** — one <kbd>ctrl</kbd>+<kbd>h/j/k/l</kbd> chord moves between nvim's own splits while you're inside it and between FuturaTerm's panes when you reach the edge. The vim-tmux-navigator experience, without tmux.
- **Driving an interactive program from a script** — a pipe can't help you with a REPL or a paged diff, but `pane run`, `pane key`, and `pane dump` can type into one and read what's on screen.
- **Giving a coding agent control of FuturaTerm** — a drop-in skill file that lets an agent run commands in panes and *see* what a full-screen program is displaying.

## Post your own

Got a layout, keybind, shell integration, or script that earns its keep? [Start a Cookbook topic](https://github.com/davidsolheim/futuraterm/discussions/new?category=cookbook). What makes a recipe easy for the next person to adopt:

- **Lead with what it gets you** — the annoyance it removes, before the config.
- **Include the whole thing** — the full [layout YAML](/docs/declarative-layouts), keybind, or script, not a fragment to reassemble.
- **Name the minimum version** if it leans on something recent, and say which other tools need to be installed.

> The Cookbook is for recipes. Bugs belong in [Issues](https://github.com/davidsolheim/futuraterm/issues), questions in [Q&A](https://github.com/davidsolheim/futuraterm/discussions/categories/q-a), and feature requests in [Ideas](https://github.com/davidsolheim/futuraterm/discussions/categories/ideas).
