# MX Master Input

A single native macOS menu-bar app for the Logitech MX Master 4 Sense Panel.
It reads Logitech HID++ reports directly, so its input path does not depend on
keyboard shortcuts, keyboard event taps, Mouser, Karabiner-Elements, or Logi
Options+.

Version 0.1.0 is pinned to:

- macOS 26.5.2 (25F84), Apple silicon
- MX Master 4 through Logi Bolt receiver `0x046D:0xC548`
- Xcode 26.6 / Swift 6.3
- protocol and platform research date: 2026-07-26

## Mapping

| Sense Panel input | Action |
| --- | --- |
| Tap | Control-Up — Mission Control |
| Move left | Control-Right — Next Space |
| Move right | Control-Left — Previous Space |

The Space mapping is reversed: every movement direction in the left half-plane
changes to the next Space, and every direction in the right half-plane changes
to the previous Space. Vertical drift does not disqualify a gesture. A narrow
horizontal dead zone prevents the RawXY pulse caused by pressing the panel from
choosing a Space. A short click that stays inside that dead zone opens Mission
Control. RawXY reports received during a 60-millisecond post-press arming window
are discarded so movement queued before the press cannot trigger a Space
change. After each committed direction, continued travel that way is ignored
until reversal begins. Space shortcuts are queued 1.2 seconds apart so
rapid left-right alternation is preserved while macOS finishes each Space
animation.

The haptic engine is turned off before the panel is diverted. Activation fails
closed if the MX Master 4 does not confirm the haptic command or the Sense Panel
diversion.

## Why Secure Input does not block this design

Secure Event Input protects keyboard delivery from other applications that
monitor keyboard events. MX Master Input opens only Logitech's vendor-defined
HID++ collection with `IOHIDDevice`, below the keyboard-event-monitor path.

Outputs are the standard macOS Control-arrow shortcuts, posted as keyboard
events through Accessibility. This avoids private Dock notifications and
undocumented synthetic swipe fields. Secure Input does not affect direct HID++
capture, but macOS ultimately decides whether an Accessibility-posted shortcut
is delivered while Secure Input is active.

The Settings window reports the live Secure Input state. Its runtime
verification changes to Submitted when the app receives a physical panel input
and posts the mapped shortcut while Secure Input is enabled.

Accessibility/Post Event permission is required for shortcut posting. The
app does not install an event tap and does not read keyboard events.

References:

- [Apple IOHIDDevice user-space API](https://developer.apple.com/documentation/iokit/iohiddevice_h_user-space)
- [Apple Secure Event Input technical note](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)

## Why there is no kext or DriverKit extension

A kernel extension is unnecessary for the physical input path: macOS already
exposes the receiver's HID++ collection to user space. A virtual HID device
would add a second input stack and requires Apple's restricted
`com.apple.developer.hid.virtual.device` entitlement. This app instead talks to
the real device and posts standard keyboard shortcuts through Accessibility.

References:

- [Apple DriverKit](https://developer.apple.com/documentation/DriverKit)
- [Apple HIDDriverKit](https://developer.apple.com/documentation/hiddriverkit)

## Safety boundaries

- There is no process enumeration, `kill`, `pkill`, WindowServer operation, or
  application-management code.
- Quit terminates only MX Master Input.
- HID access is non-exclusive and limited to Logitech vendor-defined
collections with a 20-byte output report.
- The app restores default Sense Panel reporting before closing its HID
  connection.
- No global output is sent until a diverted Sense Panel report commits a
  gesture or qualifies as a short click.
- Startup auto-enable occurs only after a prior successful enable and only when
  Post Event access is already granted.

## Build and tests

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
xcodebuild \
  -project MXMasterInput.xcodeproj \
  -scheme MXMasterInput \
  -configuration Debug \
  -derivedDataPath DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build test
```

The normal tests are unhosted. They cannot launch the menu-bar app and do not
open the mouse or post system input.

An opt-in, input-only hardware probe can prove that the awake MX Master 4
responds over HID++ while the probe process itself has Secure Input enabled:

```sh
MXMASTER_RUN_HARDWARE_PROBE=1 \
  xcrun xctest \
  DerivedData/Build/Products/Debug/MXMasterInputTests.xctest
```

This probe runs the device session in observation mode. It does not divert the
panel, change haptic state, or post a system event.

## End-to-end verification

1. Wake the MX Master 4.
2. Open MX Master Input and grant Accessibility/Post Event access.
3. Select Enable. Confirm `Haptic engine: Off`.
4. Enable Secure Input using a password field or Secure Keyboard Entry in a
   terminal.
5. Confirm the app shows `Secure Input: Enabled`.
6. Click and release the Sense Panel without holding. Confirm Mission Control
   opens.
7. Hold the Sense Panel, move diagonally left past the threshold, then move
   diagonally right past the threshold without releasing.
8. Confirm macOS changes to the next Space and then returns to the previous
   Space.
9. Confirm `Runtime verification` reads Submitted.

The Control-arrow mappings follow the shortcuts configured in macOS Keyboard
settings. If one is disabled or remapped there, the corresponding panel action
will follow that system configuration.
