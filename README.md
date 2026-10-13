# Notch

A small native macOS app (Swift, AppKit + SwiftUI) that turns the MacBook notch into a "Dynamic Island".
It lives in the menu bar, has no Dock icon, and sends nothing over the network except the lyrics (LRCLIB)
and weather (Open-Meteo) requests. No analytics, no accounts.

Requires macOS 14 or later on Apple Silicon. On a Mac without a notch, a fake notch is drawn at the top centre.

## Build

You need the Xcode Command Line Tools (`xcode-select --install`) or Xcode.

```sh
./build.sh        # builds build/Notch.app
./build.sh run    # builds, copies to /Applications, (re)launches
```

### One-time: a stable signing certificate (recommended)

macOS remembers permissions (Automation, Calendar…) per app *signature*. An ad-hoc signature changes at every
build, so macOS would ask again after each rebuild. Create a local certificate once:

1. Open **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `Notch Local` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → Create.

`build.sh` uses it automatically (or set `NOTCH_SIGN_IDENTITY` to another name). Without it, the app is signed ad-hoc.

## Run

`./build.sh run`, or open `/Applications/Notch.app`. The capsule icon in the menu bar holds the settings.

## What works so far

- **Step 1** – menu bar icon (no Dock icon), Theme menu (Dark Matte / White Matte), Quit.
- **Step 2** – the island over the notch, in all spaces and in full screen. Rest the mouse on the notch for
  0.25 s to open it; move away to close it; click it to keep it open (click again or click elsewhere to release).
  The **Test** menu shows the compact pill, a peek, and opens/closes the island by hand.
- **Step 3** – the tiles:
  - **Music** – Spotify or Music (only if already running; never launched). Cover, title, artist, progress,
    previous / play-pause / next, and the current lyric line under the tiles, synced, from LRCLIB.
    Lyrics are cached in `~/Library/Caches/local.notch.island/lyrics`. macOS asks for the Automation
    permission once per player, the first time the island opens while that player runs.
    Spotify only exposes a cover *URL*, so Spotify covers are off unless you tick
    **Spotify Covers** in the menu (that is a request to Spotify's servers).
  - **Weather** – Open-Meteo, for the city set in **Weather City…** (refreshed every 30 min while you open the island).
  - **Calendar** – next event (EventKit). Access is asked the first time the island opens.
  - **Focus timer** – 25 min, start/pause and reset; a bubble and a sound when it ends.

- **Step 4** – peeks (bubbles under the notch for 2–4 s): an app opens or quits (with its icon), charger
  connected, battery at 20 % and 10 %. **Do Not Disturb Bubbles** (menu, off by default) asks for the Focus
  permission when you turn it on. macOS has no public Do Not Disturb API: the Focus permission only says
  whether *a* Focus is on, and if macOS refuses it the app tells you and leaves the bubbles off.

## Network

Only these requests leave the Mac: `lrclib.net` (title, artist, album, duration of the current track),
`geocoding-api.open-meteo.com` and `api.open-meteo.com` (the city name and its coordinates), and, only if you
turn it on, the Spotify cover image.

## Remove

```sh
pkill -x Notch
rm -rf /Applications/Notch.app
tccutil reset All local.notch.island       # forget the permissions granted to Notch
defaults delete local.notch.island          # forget the settings
```

Then delete the `Notch Local` certificate in Keychain Access if you made one.
