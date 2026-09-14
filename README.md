# Cockpit

One app in the notch. Claude usage with pace predictions, clipboard history, and
the mouse-wheel fix, in a single black island that springs out of the notch.

- **Usage** — the 5-hour session, the weekly window and every per-model limit
  Anthropic exposes (Fable today). Each bar shows where you are, where the
  current pace lands you by the reset, and a tick for an even pace. Colour is
  risk: green while the pace fits the window, amber when you'd run dry a little
  early, red when you'd lose real time or hit the limit.
- **Clips** — everything you copy, plus every screenshot macOS saves. Click to
  copy it back, ↩ to paste it into the front app. ⇧⌘V opens it from anywhere.
- **Scroll** — reverse the mouse wheel while the trackpad stays natural
  (the ScrollFlip trick), switchable from the island.

The idle bar shows a readout either side of the notch; each side is switchable
(Session, Week, Fable, or nothing). Hover to open, click anywhere on the island
to pin it open, click again to release.

## Build

Requires macOS 26 and Xcode 26.

```sh
./build.sh                                 # compiles, assembles and signs Cockpit.app
cp -R Cockpit.app /Applications/
open /Applications/Cockpit.app
```

`build.sh` signs with an Apple Development identity when one is in the Keychain.
That matters: macOS ties the Accessibility and Keychain grants to the signing
identity, and an ad-hoc signature changes on every rebuild, silently voiding them.

## Permissions

- **Accessibility** — the scroll flip and ↩-to-paste need it. Asked once, then
  the Scroll tab shows the state.
- **Keychain** — per-model usage comes from Anthropic's usage endpoint, which
  needs the login Claude Code keeps in the Keychain (`claude` → `/login`).
  macOS asks before Cockpit reads it; the token is cached locally and never
  refreshed by Cockpit. Without it, a `claude setup-token` token pasted in
  Settings gives the session and weekly numbers from the rate-limit headers.

Everything Cockpit stores lives in `~/.cockpit`. Anthropic reports whole
percents, so a decimal only appears if the API ever sends one.

## Debug

```sh
/Applications/Cockpit.app/Contents/MacOS/Cockpit --notchinfo   # screen + notch geometry
cat ~/.cockpit/usage-state.json                                 # last refresh: source, login state, buckets
cat ~/.cockpit/state.json                                       # what's on screen
```
