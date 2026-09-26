# MX Master Input

Trackpad gestures for the Sense Panel on the Logitech MX Master 4.

## What it does

- Hold the Sense Panel and drag, and the desktop follows your finger the way it follows three fingers
  on a Magic Trackpad: through pauses and reversals, then committing or springing back on release.
  Left and right switch Spaces; up opens Mission Control; down closes it.
- A tap on the panel opens Mission Control.
- The horizontal thumb wheel scrolls like two fingers on a trackpad: pixel-precise, with scroll phases,
  following your natural scrolling setting. Each app decides what that does, so documents scroll
  sideways and Safari can swipe between pages. The main wheel is unchanged.
- It talks to the mouse directly over Logitech HID++. Logi Options+ is not needed, and the panel keeps
  working in password fields and other places where Secure Input is on.
- The menu-bar icon is bright while gestures are working and faded while they're off or the mouse
  isn't connected. Its menu shows the mouse and its battery. Turning gestures off, or quitting, returns
  the panel and the thumb wheel to their usual behavior. The panel's haptic click, which gestures turn
  off, stays off until the mouse next loses its settings, as it does when it sleeps.

| Sense Panel | Action |
|---|---|
| Tap | Mission Control |
| Hold and drag up | Mission Control |
| Hold and drag down | Close Mission Control, when it is open |
| Hold and drag left | Next Space |
| Hold and drag right | Previous Space |

Horizontal drags are reversed so the desktop moves with your finger, as it does on a trackpad. A dead
zone in the middle ignores the small movement a press causes, and each drag locks to the axis it starts
on. Dragging down does nothing on the desktop, where the same gesture would open App Exposé.

The thumb wheel does not yet add momentum after you let go.

## Requirements

- An MX Master 4 connected through a Logi Bolt receiver
- macOS 26 or 27 (validated on 26.5.2 `25F84` and 27.0 `26A428`)

### Permission

MX Master Input needs Accessibility permission to post gestures and shortcuts. It asks on first launch
and starts by itself as soon as the switch is turned on. If the switch is on but the menu still asks for
permission, macOS is holding an entry from an earlier build: open the menu, hold Option, and choose
Reset Accessibility Permission.

### Private interfaces

macOS has no public way to drive a progressive Spaces or Mission Control gesture, so MX Master Input
posts the private DockSwipe event the Dock reads from a trackpad. On macOS 26 that is a pair of CGEvents
with private fields; on macOS 27 it is a CGEvent carrying a private IOKit `HIDEvent`, resolved at run
time. The layout changes between major releases, so each one is validated before it is enabled. On a
release that hasn't been validated yet, or if the private API is missing, a released swipe becomes the
Control-arrow shortcut from Keyboard Shortcuts › Mission Control instead, without the live tracking.

The DockSwipe field layout was informed by the reverse engineering published in
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix), under its
[MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).

Taps and the shortcut fallback press Control-arrow through `AXUIElementPostKeyboardEvent`, because
system shortcuts ignore key events that apps post. Whether Mission Control is open is read from the
Dock's Accessibility tree.

## Install

Download `MXMasterInput-<version>-macOS.zip` from the
[latest release](https://github.com/mstallone/mx-master-input/releases/latest), unzip, and move
MXMasterInput.app to /Applications. It is a universal binary, signed with Developer ID and notarized.
It checks for updates daily and installs them itself through [Sparkle](https://sparkle-project.org);
Check for Updates… in the menu checks now.

## Building

`./build.sh` builds with SwiftPM, signs with your Apple Development identity so the Accessibility grant
survives rebuilds, installs to /Applications, and launches. It refuses to overwrite a release build
unless given `--replace`. `swift test` runs the tests; the hardware probe below reads a connected
MX Master 4 (in observation mode, without changing it) and is skipped otherwise.

    MXMASTER_RUN_HARDWARE_PROBE=1 swift test --filter SecureInputHardwareProbeTests

    Sources/MXMasterInput/main.swift              app lifecycle, menu, permission, reconnecting
    Sources/MXMasterInput/Session.swift           HID++ session: discovery, configuration, wake recovery
    Sources/MXMasterInput/HIDPP.swift             HID++ reports, feature IDs, battery readings
    Sources/MXMasterInput/HIDDevice.swift         IOKit access to the receiver's HID++ interface
    Sources/MXMasterInput/GestureRecognizer.swift panel motion to one continuous gesture
    Sources/MXMasterInput/DockSwipe.swift         gestures to Dock swipes, shortcut fallback
    Sources/MXMasterInput/ThumbWheel.swift        thumb wheel to trackpad-style scrolling
    Sources/SystemEvents/                         the macOS 27 HIDEvent and the Accessibility key press
    Resources/Info.plist                          bundle template; the version is stamped at build time
    Resources/AppIcon.iconset                     app icon
    Scripts/build-app.sh                          stages MXMasterInput.app from a built binary
    Scripts/sign.sh                               signs the app and Sparkle inside out
    Scripts/build-release.sh                      CI: universal build, Developer ID, notarize, staple, zip
    Scripts/generate-appcast.sh                   CI: Sparkle appcast for the release
    Scripts/SecureInputGestureTest.applescript    manual check of the panel inside a password field

### Thumb wheel

The wheel is diverted through HID++ feature `0x2150` (see
[logiops](https://github.com/PixlOne/logiops/blob/main/src/logid/backend/hidpp20/features/ThumbWheel.cpp)
and [Solaar](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py)).
Rotation is scaled from the wheel's reported resolution to 1,200 pixels per revolution, and each step is
spread over four frames at 120 Hz in whole pixels that add up to the exact distance. A reversal flushes
the buffer. Events are pixel-unit, continuous scroll events with began, changed, and ended phases, which
is what AppKit's [precise scrolling](https://developer.apple.com/documentation/appkit/nsevent/hasprecisescrollingdeltas)
and [WebKit's swipe tracking](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/ViewGestureControllerMac.mm)
look for. If the wheel's stop report is lost, the gesture ends after 300 ms without input.

## Releasing

The tag is the version. Pushing `vMAJOR.MINOR.PATCH` runs the Release workflow: tests, universal build,
Developer ID signature with hardened runtime and timestamp, notarization, stapling, Gatekeeper check,
then a GitHub Release with the zip, its SHA-256, and a signed Sparkle `appcast.xml`.

    git tag v0.2.0 && git push origin v0.2.0

| Secret | Contents |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | base64 of the Developer ID Application `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | its export password |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | base64 of the App Store Connect API key (`.p8`) |
| `APPLE_NOTARY_KEY_ID` | that key's ID |
| `APPLE_NOTARY_ISSUER_ID` | the App Store Connect issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | the EdDSA key from Sparkle's `generate_keys` |

The public half of the Sparkle key is `SUPublicEDKey` in `Resources/Info.plist`; the private key is also
in the login keychain under the `com.mattstallone.mxmasterinput` account. Keep a secure backup:
installed copies accept only updates signed with it and with the same Developer ID team.

MX Master Input is an independent project, not affiliated with Apple or Logitech.

## License

MIT. See [LICENSE](LICENSE).
