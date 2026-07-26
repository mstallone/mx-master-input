# MX Master Input

**First-party-feeling, Apple-native gestures on a Logitech MX Master.**

MX Master Input brings the progressive Space-switching experience of Apple's
Magic Trackpad to the MX Master 4 Sense Panel. The desktop stays attached to
your movement, responds when you reverse direction, and commits or snaps back
when you release—just like a native macOS gesture.

This is not conventional mouse-button remapping. The app reads Logitech HID++
reports directly and drives the phased system gesture understood by Dock, so
the interaction is continuous rather than a keyboard shortcut followed by an
uninterruptible animation. It does not depend on keyboard event taps, Mouser,
Karabiner-Elements, or Logi Options+.

## Why this matters

Most mouse gesture utilities can only turn a gesture into a one-shot action
such as Control-Left or Control-Right. That asks macOS to start a Space
transition, but the mouse no longer controls what happens next: the animation
runs by itself, quick reversals are dropped, and the result feels like a
shortcut.

Apple's trackpad experience is different because it sends one continuous,
phased gesture to the window system. The current Space moves with your hand.
You can slow down, stop, reverse, commit, or cancel before lifting your fingers.
That direct manipulation—not merely triggering the same destination—is what
makes the interaction feel first-party.

MX Master Input gives the Sense Panel that same interaction model:

- progressive, analog control of the Space transition
- immediate reversals within the active gesture
- natural release behavior that commits or snaps back
- a simple click for Mission Control
- direct HID++ input that continues to work while Secure Input is enabled

The result is an MX Master that participates in macOS gestures as an input
surface, instead of impersonating one with a sequence of keystrokes.

Version 0.1.0 is pinned to:

- macOS 26.5.2 (25F84), Apple silicon
- MX Master 4 through Logi Bolt receiver `0x046D:0xC548`
- Xcode 26.6 / Swift 6.3
- protocol and platform research date: 2026-07-26

## Mapping

| Sense Panel input | Action |
| --- | --- |
| Tap | Control-Up — Mission Control |
| Hold and drag left | Continuous system swipe — Next Space |
| Hold and drag right | Continuous system swipe — Previous Space |

The Space mapping is reversed: every movement direction in the left half-plane
reveals the next Space, and every movement direction in the right half-plane
reveals the previous Space. Once the motion crosses the activation threshold,
the app begins one phased Dock swipe. Every subsequent RawXY sample updates its
progress, so the desktop follows the mouse and reversals modify the same active
gesture. Releasing the panel ends the stream and lets Dock commit the Space or
snap back. There is no action queue or intentional animation delay.

Vertical drift does not disqualify a gesture. A narrow horizontal dead zone
prevents the RawXY pulse caused by pressing the panel from beginning a swipe. A
short click that stays inside that dead zone opens Mission Control. RawXY
reports received during a 60-millisecond post-press arming window are discarded
so movement queued before the press cannot cross into the new gesture.

The haptic engine is turned off before the panel is diverted. Activation fails
closed if the MX Master 4 does not confirm the haptic command or the Sense Panel
diversion.

## Progressive Space gesture implementation

macOS does not publish an API for injecting the progressive gesture consumed by
Dock. On macOS 26, MX Master Input emits the private `DockSwipe` event shape
used by the native gesture pipeline: a cumulative horizontal progress value
accompanied by `began`, `changed`, `ended`, and `cancelled` phases. Unlike
posting Control-arrow repeatedly, each RawXY report updates the gesture already
in progress. This path was verified on build 25F84 in both directions and by
retargeting a transition while its settling animation was still active.

The private event-field layout is inherently OS-version-sensitive. The app does
not use it on macOS 27, where the representation changed; it falls back to the
standard Accessibility-posted Control-arrow action instead. Every active
synthetic swipe is cancelled before a replacement begins, when the device
session stops, and when the app terminates.

The DockSwipe field mapping was informed by the reverse engineering published
in [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix), under the
[MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).

## Why Secure Input does not block this design

Secure Event Input protects keyboard delivery from other applications that
monitor keyboard events. MX Master Input opens only Logitech's vendor-defined
HID++ collection with `IOHIDDevice`, below the keyboard-event-monitor path.

Space motion is posted as a phased system gesture rather than keyboard input.
The Mission Control tap and compatibility fallback use Control-arrow keyboard
events through Accessibility. Secure Input does not affect direct HID++ capture,
but macOS ultimately decides whether a synthesized output event is delivered.

The Settings window reports the live Secure Input state. Its runtime
verification changes to Submitted when the app receives a physical panel input
and posts the mapped system event while Secure Input is enabled.

Accessibility/Post Event permission is required for output posting. The app
does not install an event tap and does not read keyboard events.

References:

- [Apple IOHIDDevice user-space API](https://developer.apple.com/documentation/iokit/iohiddevice_h_user-space)
- [Apple Secure Event Input technical note](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)

## Why there is no kext or DriverKit extension

A kernel extension is unnecessary for the physical input path: macOS already
exposes the receiver's HID++ collection to user space. A virtual HID device
would add a second input stack and requires Apple's restricted
`com.apple.developer.hid.virtual.device` entitlement. This app instead talks
directly to the real device and posts the translated system events in process.

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
- No global output is sent until diverted panel motion clears both activation
  thresholds or the press qualifies as a short click.
- Every begun Dock swipe receives an end or cancellation during normal disable,
  replacement, and termination paths.
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

## Manual Secure Input gesture test

Run the included AppleScript to open a focused hidden-answer field, which
enables macOS Secure Event Input:

```sh
osascript Scripts/SecureInputGestureTest.applescript
```

Keep the insertion point in the hidden field while trying a Sense Panel
gesture. Mission Control or a Space change may remove focus, so return to the
dialog and refocus the field before each separate test. The dialog closes after
10 minutes if `Finish` is not selected.

## End-to-end verification

1. Wake the MX Master 4.
2. Open MX Master Input and grant Accessibility/Post Event access.
3. Select Enable. Confirm `Haptic engine: Off`.
4. Enable Secure Input using a password field or Secure Keyboard Entry in a
   terminal.
5. Confirm the app shows `Secure Input: Enabled`.
6. Click and release the Sense Panel without holding. Confirm Mission Control
   opens.
7. Hold the Sense Panel and drag left. Confirm the current desktop follows the
   mouse progressively; reverse before releasing and confirm it follows back.
8. Drag far enough left and release to commit the next Space. Repeat to the
   right to return to the previous Space.
9. Confirm `Runtime verification` reads Submitted.

Mission Control and the compatibility fallback follow the Control-arrow
shortcuts configured in macOS Keyboard settings.
