# MAS screenshot runbook

Capture **5–8** Mac screenshots for App Store Connect. Keep the PNGs out of git (large binaries); store them in the ASC record or a private asset folder.

This is a capture checklist, not a claim that MAS is live.

## ASC sizes (Mac)

Use at least one of:

- 1280 × 800
- 2560 × 1600
- 2880 × 1800

Prefer 2560 × 1600 or 2880 × 1800 on a Retina display. Crop to those pixels; do not letterbox into a phone frame. No status-bar overlays that hide chrome. English (US) locale is enough for v1.

Windowed captures: size the main window, then screenshot the window (not the whole desktop) and scale/crop to an ASC size.

## Scenes (required set)

Shoot these, then add 1–3 extras if they stay honest (no mockups of unshipped MAS chrome).

1. **Main window** — sidebar with at least one project and a tab, plus a live terminal pane (prompt visible). This is the hero.
2. **Splits** — two or more panes in one tab (horizontal or vertical split; a 2×2 grid is fine).
3. **Settings** — Settings window open on a real pane (General or Appearance). Native sidebar Settings, not a screenshot of System Settings.
4. **Quick Terminal** — overlay panel visible over the desktop or main window, with a prompt.

Optional extras (still 5–8 total):

5. Command palette over a pane.
6. Remote-project sidebar row (if a remote project exists on the capture machine).
7. Split + search or another everyday developer layout.

## How to capture

1. Build **Release or AppStore**, not a debug banner if it would show “FuturaTerm Debug” in the title.
2. Use a throwaway project folder (`echo hi` in the pane) so no private paths leak.
3. Hide unrelated desktop clutter; keep the system menu bar if the capture is full-screen, otherwise window-only.
4. Check pixel dimensions with `sips -g pixelWidth -g pixelHeight <file>` before upload.

Do **not** commit the PNG/JPEG files to this repository.
