<img src="site/favicon.svg" width="88" height="88" alt="PlayCover Touch Bridge logo">

# PlayCover Touch Bridge

[Website](https://hematenergi.github.io/playcover-touch-bridge/) · [Quick start](#-quick-start)

Turn an Android phone into a real touchscreen for [PlayCover](https://github.com/PlayCover/PlayCover) games. This bridge does not replace or patch [PlayTools](https://github.com/PlayCover/PlayTools): it feeds true independent multi-touch from the phone into PlayTools' own touch engine, while the game video streams back to the phone over USB. The phone side is just a web app in Chrome: nothing to install, works on any Android phone with a browser, and stream settings can be tuned live without restarting the game. Developed and verified with Honkai: Star Rail.

## ✨ Highlights

- **True multi-touch from a real touchscreen** — every finger on the phone is sent as an independent touch to PlayTools inside the game. No fixed movement keymap is used.
- **Nothing to install on the phone** — the phone side is a web app shown in Android Chrome over USB.
- **Patches nothing** — the installed game binary, the PlayTools framework, and existing keymaps are not modified; the bridge launches the game with a temporary `DYLD_INSERT_LIBRARIES` module.
- **Live stream tuning** — change FPS, width, and JPEG quality presets mid-game from the phone, with no game restart.
- **Private by design** — the server listens only on Mac loopback ports and is reached from the phone over USB (ADB reverse); requests require a random session token.
- **Touches release themselves** — closing the page or losing the heartbeat releases all held contacts, with a fallback timeout of about 3–4 seconds.

Built by Dany Arkham ([hematenergi](https://github.com/hematenergi)), also the author of [Fragment](https://github.com/hematenergi/fragment). Licensed under [MIT](LICENSE). Running a different PlayCover game? See [SKILL.md](SKILL.md) for how to adapt the bridge.

## Why not keymapping or streaming?

PlayCover already ships PlayTools keymapping: keyboard and mouse input translated into touches. It works, but your fingers never touch the game — a virtual stick is steered with keys and the camera with a mouse.

Game-streaming apps solve the other half: the picture reaches your phone. But the input they send back is pointer-style, not independent simultaneous touches inside the iOS app. Here the phone is both the screen and the input surface: video is captured from the game window and shown in Chrome on the phone, and each finger comes back as its own simultaneous UIKit touch, so a virtual stick and the camera can move at the same time, independently.

## Requirements

- An Apple Silicon Mac with PlayCover 3.1.0 / PlayTools and the game installed (developed and verified with the HSR app, `com.HoYoverse.hkrpgoversea.app`).
- Xcode command-line tools, Python 3, and ADB on the Mac.
- An Android phone with Chrome, connected by USB, with USB debugging allowed.
- macOS Screen Recording permission for the capture helper / launching terminal.

## 🚀 Quick start

1. Connect the Android phone by USB and allow USB debugging.
2. If the game was opened normally through PlayCover, quit it first. The bridge has to launch the game itself with the temporary touch module.
3. Double-click `Start.command`. Keep its Terminal window open.
4. Chrome opens on the phone by itself. Tap **Fullscreen** and hold the phone in landscape.
5. Touch the game picture directly. **Release touches** lets go of all held contacts if needed.

To stop, press **Ctrl+C** in the bridge Terminal. To restore an ordinary game session, quit the game and reopen it from PlayCover.

## ⚙️ Stream settings and touch markers

### Movable toolbar

Drag the **⠿** handle to move the toolbar. The **↔ / ↕** button switches between horizontal and vertical; the default is vertical at the left edge. The toolbar stays inside the viewport after rotation or fullscreen changes, and the handle also supports arrow keys.

Under **Stream → Toolbar**, adjust the layout, normal opacity, faded opacity, or disable the two-second auto-fade. Touch the toolbar to wake it. The position reset returns it to the left. These UI preferences save immediately in the phone browser's local storage, independently of stream settings.

### Video and markers

Tap **Stream** on the phone to change settings while the game keeps running:

| Preset | Target FPS | Width | JPEG quality |
| --- | --- | --- | --- |
| Responsive | 60 | 640 px | 35% |
| Balanced (default) | 60 | 960 px | 45% |
| Sharp | 30 | 1280 px | 70% |

Custom choices: 30/45/60 FPS, widths 640/960/1280/1600 px, quality 20–90%. Tap **Apply** to apply and save settings for the next launch. Settings do not change the game's graphics quality or require restarting the game. The FPS shown on the phone measures frames drawn by the browser, not the selected target.

**Touch markers on Mac** shows numbered markers over the foreground game window. The transparent overlay follows the window, ignores mouse input, and hides when fingers are released, input expires, or another Mac app comes to the foreground. Toggle it in **Stream**.

The browser requests only the latest available frame after decoding the previous one, skipping older frames instead of accumulating an MJPEG playback queue. Frames are presented with a native image element: the earlier desynchronized canvas retained an old visible surface even while its pixels and FPS counter updated. During active gameplay on the connected Galaxy A54, the image renderer was observed around 48–54 decoded FPS with a 60 FPS target while switching between 640 px / 35% and 960 px / 45%. Visual synchronization was checked against a contemporaneous server frame during the mini game. A retained browser frame cursor also recovers when the host's frame counter resets. Actual results depend on the game, Mac, and phone; end-to-end latency and long-session stability have not been instrumented.

## ⚠️ Scope and limits

- Built for this Mac's Apple Silicon PlayCover 3.1.0 / PlayTools installation and the HSR app at `~/Library/Containers/io.playcover.PlayCover/Applications/com.HoYoverse.hkrpgoversea.app`.
- Uses a temporary `DYLD_INSERT_LIBRARIES` launch. The installed HSR binary, PlayTools framework, and existing keymaps are not patched.
- Listens only on Mac loopback ports 19470 and 19471; ADB reverse provides USB access. Requests require a random session token. Closing the page or losing the heartbeat releases touches, with a fallback timeout of about 3–4 seconds.
- Prototype video: configurable JPEG at up to 60 FPS, without audio forwarding. This is not a production streaming system.
- Window cropping uses the current game aspect ratio and the Mac window's title bar height. Restart the bridge after changing window orientation or aspect ratio.
- Verified: independent touch IDs, simultaneous UIKit touches, live video on Galaxy A54, user-confirmed working control, live resolution/quality changes, and visible numbered Mac touch markers. Not every mini game has been tested.
- Requires Xcode command-line tools, Python 3, ADB, Android Chrome, and macOS Screen Recording permission for the capture helper / launching terminal.

## Files and checks

`TouchBridge.m` is the in-game receiver; `Capture.swift` streams window frames; `host.py` serves the local browser UI in `index.html`. `build/session.json` contains a local session token and must not be shared. Game output and capture diagnostics stay under `build/`.

Run `python3 self_check.py` while the bridge is active for transport/authentication checks. It does not send game touches.

For the toolbar check, show the bridge in unlocked Android Chrome, run `adb forward tcp:19472 localabstract:chrome_devtools_remote`, then `node ui_check.mjs` (Node 22+). This exercises touch dragging, input isolation, directions, fade, opacity, viewport bounds, and persistence, restoring the original toolbar preferences afterward. Remove debug forwarding with `adb forward --remove tcp:19472` when finished.

To remove the prototype, stop it, quit HSR, delete this project folder and `~/Library/Containers/io.playcover.PlayCover/TouchBridge/`. Nothing auto-starts.

## Built on

- [PlayCover](https://github.com/PlayCover/PlayCover) — the app that runs iOS games on Apple Silicon Macs. This bridge is an add-on for it, not a fork.
- [PlayTools](https://github.com/PlayCover/PlayTools) — PlayCovers input framework. The bridge feeds real phone touches into PlayTools own touch API instead of replacing it.

## Feedback

Issues and discussions are welcome — especially reports from other PlayCover games. If you are adapting the bridge to a different title, start with [SKILL.md](SKILL.md).
