# mx4d — a tiny MX Master 4 button driver for macOS

Back, forward and the gesture ("app switch") button on a Logitech MX Master 4, without Logi Options+.

- ~3.7 MB memory, 0% CPU at idle, ~260 KB on disk. No UI, no updater, no account.
- Talks to the mouse directly over Logitech's HID++ protocol through the Bolt/Unifying receiver or Bluetooth.
- Should also work with other MX mice that have the same gesture button (MX Master 3/3S); only the MX Master 4 on a Bolt receiver has been tested.

## What it does

| Button | Default |
| --- | --- |
| Back / forward | Back / forward everywhere. Apps that ignore mouse buttons 4/5 (Safari, Finder, Xcode, other Apple apps, Firefox) get a trackpad-style navigation swipe; apps that handle them natively (Chrome, VS Code, …) get the normal click. |
| Gesture button, click | Mission Control |
| Gesture button, hold + move up | Mission Control |
| Gesture button, hold + move down | App Exposé |
| Gesture button, hold + move left / right | Move one Space left / right |

Everything else (wheel, SmartShift, thumb wheel, DPI) keeps the mouse's built-in behavior. The haptic Sense Panel is left alone unless you map it. For example, tap for Spotlight, hold for Siri, or hold + move to switch Spaces (see below).

## Install

Requires Xcode command line tools.

```bash
make install
```

This builds `MX4Driver.app`, copies it to `~/Applications`, and loads a LaunchAgent so it starts at login. macOS will ask you to allow **MX4 Driver** under System Settings › Privacy & Security › Accessibility. That's needed to post the swipe/keyboard events and to watch the side buttons. The gesture button's Mission Control and Exposé actions work even before you grant it.

The build is signed with your Apple Development certificate if you have one, so the Accessibility grant survives rebuilds. Otherwise it's ad-hoc signed and you'll need to re-grant after each rebuild.

```bash
make uninstall
```

```bash
make logs
```

```bash
make probe
```

`make probe` lists connected Logitech devices, their HID++ features, haptic level and buttons.

## Configure

Optional. Create `~/.config/mx4d/config.json` (every key is optional) and run `make restart`:

```json
{
  "universalBackForward": true,
  "gestureButton": {
    "click": "missionControl",
    "up": "missionControl",
    "down": "appExpose",
    "left": "spaceLeft",
    "right": "spaceRight"
  },
  "sensePanel": { "tap": "cmd+space", "hold": "siri" },
  "gestureThreshold": 100,
  "gestureStep": 200,
  "hapticFeedback": "none",
  "hapticLevel": 60,
  "verbose": false
}
```

Actions: `none`, `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`, `spaceRight`, `back`, `forward`, `siri`, a shortcut like `cmd+tab`, `ctrl+up`, `cmd+shift+4`, or `open:` followed by an app name (`open:Notes`), bundle ID (`open:com.apple.Safari`), path, or URL (`open:shortcuts://run-shortcut?name=Timer`).

`gestureButton` and `sensePanel` take the same keys: `tap` (or `click`), `hold`, `up`, `down`, `left` and `right`. Either button can also take one action as a plain string, which fires on press. With a hold action, a tap fires on release and holding for 0.4 s fires the hold action instead. With direction actions, holding the button and moving the mouse fires the direction instead of the tap. The pointer does not move while you hold the button. The example above maps the Sense Panel like ⌘Space on a Mac keyboard: tap for Spotlight, hold for Siri.

To move Space switching from the gesture button to the Sense Panel:

```json
{
  "gestureButton": { "left": "none", "right": "none" },
  "sensePanel": { "left": "spaceLeft", "right": "spaceRight" },
  "hapticFeedback": "subtleCollision"
}
```

A Space swipe keeps going while you hold the button: after the first switch, each further `gestureStep` sensor counts of travel (default: twice `gestureThreshold`) moves one more Space, and moving back goes back.

`hapticFeedback` makes the MX Master 4 play a haptic waveform each time a swipe fires, including each repeated Space switch: `sharpStateChange`, `dampStateChange`, `sharpCollision`, `dampCollision`, `subtleCollision`, `happyAlert`, `angryAlert`, `completed`, `square`, `wave`, `firework`, `mad`, `knock`, `jingle`, `ringing` or `whisperCollision`. Run `build/MX4Driver.app/Contents/MacOS/mx4d --haptic knock` to feel a waveform before you choose it. The strength comes from the mouse's haptic level. `hapticLevel` (0–100, 0 = off) sets it each time the mouse connects. It also controls the Sense Panel's own press and release clicks, which the firmware plays itself and which can't be turned off separately. Leave it out to keep the mouse's current level (60 by default).

Set every direction and the hold to `none` to make the gesture button act on press instead of release (the pointer then keeps moving while it's held). Set every gesture button action to `none` to leave the button to macOS as mouse button 6, so other apps can bind it. `gestureThreshold` is how far (in sensor counts) you have to move while holding the button before it counts as a swipe; a normal click moves 0–10.

## How it works

- **Gesture button / Sense Panel**: diverted with HID++ feature `0x1B04` (REPROG_CONTROLS_V4), with raw XY diversion so movement while held is reported to us instead of moving the pointer. The diversion is temporary (lives in the mouse's RAM), so it's re-applied when the receiver reports the mouse reconnecting, when the mouse asks for reconfiguration (`0x1D4B`), and, as a last resort, when the button shows up as a plain mouse-button-6 click. When the daemon stops, it hands the buttons back to the firmware.
- **Back / forward**: a `CGEventTap` on other-mouse-button events. In apps that don't understand buttons 4/5, the click is replaced with a navigation swipe gesture event.
- **Haptic feedback**: HID++ feature `0x19B0` (HAPTIC), function 4 (play waveform). The waveform IDs come from Solaar.
- **Mission Control / Exposé**: the Dock's `CoreDockSendNotification`. Space switching posts the system's ⌃← / ⌃→ shortcuts.

## Credits

- [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT) for the navigation-swipe event fields and the list of apps that need swipes instead of button clicks.
- [Solaar](https://github.com/pwr-Solaar/Solaar) for documenting HID++ feature and control IDs.
