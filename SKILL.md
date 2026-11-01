---
name: playcover-touch-bridge
description: Adapt and run PlayCover Touch Bridge for a different PlayCover game. Covers retargeting the game path in host.py, launching so PlayTools and the bridge library are in the game process, and verifying with the built-in self check. Use when setting this bridge up for any PlayCover title, or when the bridge fails to attach to a game.
---

# PlayCover Touch Bridge — adaptation skill

The bridge turns an Android phone into a real multi-touch touchscreen for a
PlayCover game: the Mac streams the game window to Chrome on the phone, and
each finger is fed back as an independent touch through PlayTools' own touch
engine. It does not patch the game or PlayTools.

Verified end-to-end with Honkai: Star Rail
(`com.HoYoverse.hkrpgoversea.app`) on PlayCover 3.1.0. Any other game is an
adaptation: the native parts (TouchBridge.m, Capture.swift) are
game-agnostic, and only two values in `host.py` name the game.

## Prerequisites

- Apple Silicon Mac with PlayCover installed and the target game already
  installed in PlayCover, with PlayTools enabled for that game.
- Xcode command-line tools, Python 3, ADB on the Mac.
- Android phone with Chrome and USB debugging allowed, connected by USB.

## Find your game

```sh
ls ~/Library/Containers/io.playcover.PlayCover/Applications/
```

Each entry is a `<bundle-id>.app` folder. The executable is the file of the
same base name inside it, for example:

```
com.example.game.app/examplegame
```

## Adapt host.py

Exactly two game-specific values, both near the top level of `host.py`:

1. `APP` (around line 23): the full path to your game's executable inside
   its `.app` folder.
2. The already-running check in `main()` (around line 280): `pgrep -x
   <name>` must use your game's executable name instead of `hkrpg`.

Leave these alone unless you have a reason: `PORT` (19470, phone-facing,
loopback only), `NATIVE_PORT` (19471, internal), and `RUNTIME` (where the
built dylib is staged inside the PlayCover container). The capture helper
follows the launched process and skips the small splash window, so no
window title or size is hardcoded per game.

## Run

1. Quit the game if it is open in PlayCover. The bridge must launch the
   game itself so the DYLD library and PlayTools are in the process;
   touches cannot be attached to a game that was opened normally.
2. Double-click `Start.command` and keep its Terminal window open.
   It builds the native parts if needed, launches the game, serves
   127.0.0.1:19470, sets up ADB reverse, and opens Chrome on the phone
   with the session token in the URL.
3. On the phone, tap **Fullscreen** and hold it in landscape.
4. Stop with Ctrl+C in the bridge Terminal.

## Verify

- With the bridge active: `python3 self_check.py` (transport and
  authentication checks; it sends no game touches).
- In the Stream panel on the phone, enable **Touch markers on Mac**:
  touches on the phone should appear as numbered markers over the game
  window on the Mac, and the game should react to each finger
  independently (for example, virtual stick and camera at the same time).

## Troubleshooting

- `OSError: [Errno 48] Address already in use` when starting: a previous
  bridge host is still running and holding port 19470. Quit the game,
  stop the old host process (`host.py`), then start again.
- "PlayTools touch API unavailable": the game was not launched by the
  bridge, or PlayTools is disabled for this game in PlayCover. Quit the
  game, enable PlayTools for it, and relaunch through `Start.command`.
- Phone shows no video: confirm the game window is the foreground window
  and that the launching terminal has macOS Screen Recording permission.
- Changing the game's window orientation or aspect ratio requires a
  bridge restart.

## Do not change

- The session token flow (token is generated per session, stored in
  `build/session.json`, and passed to the phone in the URL fragment).
  Never commit or share `build/session.json`.
- The heartbeat release: closing the page or losing the phone connection
  must release all touches. Do not make touches sticky.
- The loopback binding: the server listens on 127.0.0.1 only; USB access
  goes through ADB reverse. Do not expose it on the LAN.
