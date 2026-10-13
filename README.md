# Notch

A native macOS app (Swift, AppKit + SwiftUI) that turns the MacBook notch into a "Dynamic Island".
It lives in the menu bar, has no Dock icon, and starts at login only if you turn it on.

- **Island**: rest the pointer on the notch for 0.25 s to open it, move away to close it, click it to keep it
  open (click again, or anywhere else, to release). Spring animations, Dark Matte / White Matte themes.
  The black band of the real notch always stays black.
- **Tiles** (show, hide, reorder from the menu): Music (Spotify / Apple Music, synced lyrics from LRCLIB),
  Weather (Open-Meteo), next Calendar event, 25-minute Focus timer.
- **Peeks**: app opened or quit, charger connected, battery at 20 % and 10 %, Focus (Do Not Disturb) on/off.
- **Claude Code**: what Claude is doing in the compact pill, permission requests with Allow / Deny,
  "Done" with how long it took.

Requires macOS 14 or later on Apple Silicon. On a Mac without a notch, a notch-sized island is drawn at the
top centre of the main screen.

## Privacy

Nothing leaves the Mac except:

| Request | What is sent | When |
|---|---|---|
| `lrclib.net` | title, artist, album, duration of the current track | once per new track (then cached) |
| `geocoding-api.open-meteo.com`, `api.open-meteo.com` | the city name, then its coordinates | at most every 30 min, when you open the island |
| Spotify's image server | the cover URL given by Spotify | only if you tick **Spotify Covers** |

No analytics, no accounts, no other network access. Claude Code talks to the app through a local Unix
socket that only your user can open (`~/Library/Application Support/Notch/notch.sock`, mode 0600).

## Permissions

Each one is asked only when the feature that needs it is first used:

| Permission | Asked when | Why |
|---|---|---|
| Automation → Spotify / Music | the island first opens while that player is running | read the track, play/pause/next |
| Calendar (full access) | the island first opens with the Calendar tile shown | show your next event |
| Focus | you turn on **Do Not Disturb Bubbles** | know when a Focus turns on or off |

The Allow/Deny shortcuts are system hot keys and need **no** Accessibility permission. The app never launches
Spotify or Music; a player is only read while it is already running.

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

## Claude Code

1. Install the app in `/Applications` (`./build.sh run` does it).
2. Menu bar capsule › **Claude Code › Copy Hook Settings**, or copy this block, and merge it into
   `~/.claude/settings.json` yourself (inside the top-level `{ }`; if you already have a `"hooks"` key,
   add these events to it):

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "'/Applications/Notch.app/Contents/Resources/notch-hook.sh'", "timeout": 5 }] }],
  "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "'/Applications/Notch.app/Contents/Resources/notch-hook.sh'", "timeout": 5 }] }],
  "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "'/Applications/Notch.app/Contents/Resources/notch-hook.sh'", "timeout": 130 }] }],
  "Notification": [{ "hooks": [{ "type": "command", "command": "'/Applications/Notch.app/Contents/Resources/notch-hook.sh'", "timeout": 5 }] }],
  "Stop": [{ "hooks": [{ "type": "command", "command": "'/Applications/Notch.app/Contents/Resources/notch-hook.sh'", "timeout": 5 }] }]
}
```

3. Start a new Claude Code session.

What you get:

- While Claude works, the compact pill shows the current step (reading, editing, running, searching…) and
  a small animated grid. When it stops, a bubble says **Done** with how long it took.
- When Claude asks for a permission, the island opens with the **whole** request (the full command, or every
  field of the tool's input), never cut. **Allow** stays disabled until every line has been on screen
  (long requests scroll). Shortcuts: **⌃⌥Y** Allow, **⌃⌥N** Deny (only active while a request waits).
- **Ask in Terminal**, no answer within 120 s, or the app not running: Claude Code asks in its own window,
  as usual. `notch-hook.sh` exits at once, silently, when Notch is not there.

## Settings (menu bar capsule)

Tiles (checkbox to show or hide, arrows to reorder) · Weather City… · Spotify Covers · Do Not Disturb
Bubbles · Theme (Dark Matte / White Matte) · Claude Code · Launch at Login · Quit.

## Code

| File | Role |
|---|---|
| `App.swift` | entry point (`--hook` mode or the app), menu bar menu |
| `IslandModel.swift` | island states, sizes (from the reference screenshot), notch geometry |
| `IslandWindow.swift` | the non-activating panel over the notch, mouse tracking, window sizing |
| `IslandView.swift` | island shape, compact pill, peeks |
| `Tiles.swift`, `TilesEditor.swift` | the four tiles, lyrics line, the tiles editor in the menu |
| `Music.swift` | Spotify / Music through AppleScript, LRCLIB lyrics and cache |
| `Weather.swift`, `Calendar.swift` | Open-Meteo, EventKit, focus timer |
| `Peeks.swift` | apps, power (IOKit), Focus |
| `HookSocket.swift`, `Claude.swift`, `ClaudeViews.swift`, `HotKeys.swift` | Claude Code bridge, permission card, shortcuts |
| `Theme.swift`, `Settings.swift` | colours, preferences |

## Remove

```sh
pkill -f "/Applications/Notch.app/Contents/MacOS/Notch$"   # the app, not hooks in flight
rm -rf /Applications/Notch.app
tccutil reset All local.notch.island        # forget the permissions granted to Notch
defaults delete local.notch.island           # forget the settings
rm -rf ~/Library/Caches/local.notch.island ~/"Library/Application Support/Notch"
```

Then remove the `"hooks"` entries pointing to `notch-hook.sh` from `~/.claude/settings.json`, turn off
**Launch at Login** first if you had it on (or remove Notch in System Settings › General › Login Items),
and delete the `Notch Local` certificate in Keychain Access if you made one.
