# Notch

A native macOS app (Swift, AppKit + SwiftUI) that turns the MacBook notch into a "Dynamic Island".
It lives in the menu bar, has no Dock icon, and starts at login only if you turn it on.

- **Island**: rest the pointer on the notch for 0.25 s to open it, move away to close it, click it to keep it
  open (click again, or anywhere else, to release). Spring animations, Dark Matte / White Matte themes.
  The black band of the real notch always stays black.
- **Tiles** (show, hide, reorder from the menu): Music (Spotify / Apple Music, synced lyrics from LRCLIB),
  Weather (Open-Meteo), next Calendar event, 25-minute Focus timer.
- **Peeks**: app opened or quit, charger connected, battery at 20 % and 10 %, Focus (Do Not Disturb) on/off.
- **Compact pill**: while the focus timer runs, a black pill beside the notch shows the time left.

Requires macOS 14 or later on Apple Silicon. On a Mac without a notch, a notch-sized island is drawn at the
top centre of the main screen.

## Privacy

Nothing leaves the Mac except:

| Request | What is sent | When |
|---|---|---|
| `lrclib.net` | title, artist, album, duration of the current track | once per new track (then cached) |
| `geocoding-api.open-meteo.com`, `api.open-meteo.com` | the city name, then its coordinates | at most every 30 min, when you open the island |
| Spotify's image server | the cover URL given by Spotify | only if you tick **Spotify Covers** |

No analytics, no accounts, no other network access.

## Permissions

Each one is asked only when the feature that needs it is first used:

| Permission | Asked when | Why |
|---|---|---|
| Automation → Spotify / Music | the island first opens while that player is running | read the track, play/pause/next |
| Calendar (full access) | the island first opens with the Calendar tile shown | show your next event |
| Focus | you turn on **Do Not Disturb Bubbles** | know when a Focus turns on or off |

The app never launches Spotify or Music: every script runs only if the player is already running.

**Do Not Disturb**: macOS has no public API for it. The Focus permission only says whether *a* Focus
(Do Not Disturb or any other) is on. If macOS refuses that permission, the app says so and leaves the
bubbles off.

## Build

You need the Xcode Command Line Tools (`xcode-select --install`) or Xcode.

```sh
./build.sh        # builds build/Notch.app
./build.sh run    # builds, copies to /Applications, (re)launches
swift test        # unit tests (needs Xcode, not just the Command Line Tools)
```

### One-time: a stable signing certificate (recommended)

macOS remembers permissions per app *signature*. An ad-hoc signature changes at every build, so macOS would
ask again after each rebuild. Create a local certificate once:

1. Open **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `Notch Local` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → Create.

`build.sh` uses it automatically (or set `NOTCH_SIGN_IDENTITY` to another name). Without it, the app is
signed ad-hoc and still works.

## Settings (menu bar capsule)

Tiles (checkbox to show or hide, arrows to reorder) · Weather City… · Spotify Covers · Do Not Disturb
Bubbles · Theme (Dark Matte / White Matte) · Launch at Login · Quit.

## Code

| File | Role |
|---|---|
| `App.swift` | entry point, menu bar menu |
| `IslandModel.swift` | island states, sizes (from the reference screenshot), notch geometry |
| `IslandWindow.swift` | the non-activating panel over the notch, mouse tracking, window sizing |
| `IslandView.swift` | island shape, compact timer pill, peeks |
| `Tiles.swift`, `TilesEditor.swift` | the four tiles, lyrics line, the tiles editor in the menu |
| `Music.swift` | Spotify / Music through AppleScript, LRCLIB lyrics and cache |
| `Weather.swift`, `Calendar.swift` | Open-Meteo, EventKit, focus timer |
| `Peeks.swift` | apps, power (IOKit), Focus |
| `Theme.swift`, `Settings.swift` | colours, preferences |

## Remove

```sh
pkill -x Notch
rm -rf /Applications/Notch.app
tccutil reset All local.notch.island        # forget the permissions granted to Notch
defaults delete local.notch.island           # forget the settings
rm -rf ~/Library/Caches/local.notch.island     # cached lyrics
```

Turn off **Launch at Login** first if you had it on (or remove Notch in System Settings › General › Login Items),
and delete the `Notch Local` certificate in Keychain Access if you made one.
