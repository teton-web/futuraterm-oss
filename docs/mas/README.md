# Mac App Store Connect listing pack (public stub)

Paste-ready **structure** for an App Store Connect record. This pack is **not** a claim that FuturaTerm is listed or shipping on the Mac App Store. Direct GitHub DMGs remain the published channel (Developer ID + notarize). MAS archives use a separate AppStore configuration; see `AGENTS.md` Releasing.

**Do not commit Apple account identifiers, Team IDs, SKUs, API keys, or provisioning profile names to this public repository.** Keep those in a private ops location (private `teton-web/futuraterm`, Doppler `teton-certs`, or CI secrets).

Do not invent a dollar price. Paid upfront, no IAP / StoreKit.

## Identifiers (set privately)

| Field | Where to set |
| --- | --- |
| SKU / bundle ID | Private ASC record / `PRODUCT_BUNDLE_IDENTIFIER` in your fork’s `project.yml` |
| Apple ID (account) | Private ops only — never commit |
| Team ID | `FUTURATERM_DEVELOPMENT_TEAM` (env / CI) — never commit |
| Signing (MAS) | `FUTURATERM_MAS_CODESIGN_IDENTITY` + Apple Distribution cert (env / CI) |
| Signing (Direct) | `FUTURATERM_CODESIGN_IDENTITY` + Developer ID cert (env / CI) |
| Primary category | Developer Tools |
| Age rating | 4+ (SSH / outbound network to user-specified hosts; no user-generated social content) |

Same bundle id on both channels when you publish both. Same team. Different identity and entitlements.

## Short description

(30 characters max in ASC; keep under that.)

```
GPU terminal for macOS
```

## Full description

FuturaTerm is a native macOS terminal emulator: SwiftUI chrome, libghostty for the surface, split panes, project workspaces, and a Quick Terminal overlay.

Two distribution channels, one product:

- **Direct (GitHub DMG)** — Developer ID signed and notarized. Not App Sandbox. Sparkle auto-update when a feed is published. Full Disk Access banner where the Direct build needs it.
- **Mac App Store** — Apple Distribution signed, App Sandbox on, no Sparkle. Updates come from the App Store. Temporary exception entitlements let the sandboxed build read/write `~/.config/futuraterm`, Ghostty’s Application Support config, and related Ghostty config paths the terminal actually uses.

This listing is the MAS channel only. There is no in-app purchase and no StoreKit. The app is paid upfront in App Store Connect (`HUMAN: set in ASC`).

## Keywords

(100-character ASC field, comma-separated, no spaces after commas if you need the budget.)

```
terminal,emulator,developer,ssh,shell,split,gpu,macos,ghostty,cli
```

Character count: 65.

## What’s New

Placeholder until the first MAS version ships:

```
First Mac App Store listing. Same FuturaTerm as the Direct GitHub build, sandboxed, updated through the App Store.
```

## URLs

| Field | Value |
| --- | --- |
| Support | https://futuraterm.com |
| Privacy policy | https://futuraterm.com/privacy |

## Price

Paid upfront. **`HUMAN: set in ASC`**. Do not put a dollar amount in this repo.

## Review notes (App Review)

FuturaTerm is a terminal. Reviewers should treat it like other developer tools that spawn shells and optional SSH.

Sandbox:

- Temporary exception entitlements cover config the app and Ghostty must read/write outside the container: `~/.config/futuraterm` (project/layout files), Ghostty Application Support (`~/Library/Application Support/com.mitchellh.ghostty`), and `~/.config/ghostty` when the user keeps config there.
- Network client: local shells, remote projects over user-configured SSH.
- Camera and microphone **usage strings exist** so child processes (and the terminal) can request those TCC prompts if a program in a pane needs them. The app itself does not capture camera or mic in its UI.

Demo (enough to prove it launches and runs a command):

1. Launch FuturaTerm.
2. File → Open Project… (or the sidebar +) and pick a local folder via the Open panel.
3. In the resulting pane, type `echo hi` and press Return. Output should appear in the surface.

No Apple ID sign-in inside the app. No IAP. No account to create.

## Screenshots

See [screenshots.md](screenshots.md). Do not commit large PNGs here.
