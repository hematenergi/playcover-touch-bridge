# PlayCover Touch Bridge

Turn an Android phone into a real touchscreen for PlayCover games. This bridge does not replace or patch PlayTools: it feeds true independent multi-touch from the phone into PlayTools' own touch engine, while the game video streams back to the phone over USB. The phone side is just a web app in Chrome: nothing to install, works on any Android phone with a browser, and stream settings can be tuned live without restarting the game. Developed and verified with Honkai: Star Rail.

Android sends each finger as an independent touch to PlayTools inside HSR. No fixed movement keymap is used. Video is captured from the HSR window and shown in Android Chrome over USB.

## Run again

1. Connect the Android phone by USB and allow USB debugging.
2. If HSR was opened normally through PlayCover, quit HSR first.
3. Double-click `Start.command`. Keep its Terminal window open.
4. Chrome opens on Android. Tap **Layar penuh** and hold the phone in landscape.
5. Touch the game picture directly. **Lepas jari** releases all held contacts if needed.

## Stream and touch markers

Tap **Stream** on Android to change settings while HSR keeps running:

| Preset | Target FPS | Width | JPEG quality |
| --- | --- | --- | --- |
| Responsif | 60 | 640 px | 35% |
| Seimbang (default) | 60 | 960 px | 45% |
| Tajam | 30 | 1280 px | 70% |

Custom choices: 30/45/60 FPS, widths 640/960/1280/1600 px, quality 20–90%. Tap **Terapkan** to apply and save settings for the next launch. Settings do not change the game's graphics quality or require restarting HSR. The FPS shown on Android measures frames drawn by the browser, not the selected target.

**Buletan sentuhan di layar Mac** shows numbered markers over the foreground HSR window. The transparent overlay follows the window, ignores mouse input, and hides when fingers are released, input expires, or another Mac app comes to the foreground. Toggle it in **Stream**.

The browser requests only the latest available frame after decoding the previous one, skipping older frames instead of accumulating an MJPEG playback queue. Frames are presented with a native image element: the earlier desynchronized canvas retained an old visible surface even while its pixels and FPS counter updated. During active gameplay on the connected Galaxy A54, the image renderer was observed around 48–54 decoded FPS with a 60 FPS target while switching between 640 px / 35% and 960 px / 45%. Visual synchronization was checked against a contemporaneous server frame during the mini game. A retained browser frame cursor also recovers when the host's frame counter resets. Actual results depend on the game, Mac, and phone; end-to-end latency and long-session stability have not been instrumented.

To stop, press **Ctrl+C** in the bridge Terminal. For the current Codex-launched session, ask Codex to stop the bridge. To restore an ordinary game session, quit HSR and reopen it from PlayCover.

## Scope and limits

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

To remove the prototype, stop it, quit HSR, delete this project folder and `~/Library/Containers/io.playcover.PlayCover/TouchBridge/`. Nothing auto-starts.
