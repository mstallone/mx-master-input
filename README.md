# MX Master Input

**First-party-feeling, Apple-native gestures on a Logitech MX Master.**

MX Master Input brings the progressive Space-switching experience of Apple's
Magic Trackpad to the MX Master 4 Sense Panel. The desktop follows your
movement, responds when you reverse direction, and commits or snaps back when
you release—just like a native macOS gesture.

Unlike conventional mouse-button remapping, this is not a gesture translated
into a one-shot keyboard shortcut. The app reads the Sense Panel directly over
Logitech HID++ and drives one continuous, phased system gesture.

## Why it feels native

A Control-arrow shortcut tells macOS where to go and leaves the animation to
finish by itself. A trackpad gesture keeps you in control throughout the
transition: you can slow down, stop, reverse, commit, or cancel before
releasing.

MX Master Input gives the Sense Panel that same direct-manipulation model:

- progressive control of the Space transition
- immediate reversals during the active gesture
- natural release behavior that commits or snaps back
- a simple click for Mission Control

## Requirements

- Logitech MX Master 4 connected through the Logi Bolt receiver
  (`0x046D:0xC548`)
- Apple silicon Mac running macOS 26.5.2 (`25F84`)
- Accessibility permission for posting system actions

Version 0.1.0 is validated with Xcode 26.6 and Swift 6.3.

## Controls

| Sense Panel input | Action |
| --- | --- |
| Tap | Mission Control |
| Hold and drag left | Next Space |
| Hold and drag right | Previous Space |

The Space mapping is intentionally reversed so the desktop tracks the physical
motion naturally. A central dead zone filters the small movement caused by
pressing the panel. Once a swipe begins, vertical drift is ignored and every
horizontal movement updates the same active gesture.

Mission Control and the compatibility fallback use the Control-arrow shortcuts
configured in macOS Keyboard settings.

## Build and run

The Xcode project is generated from `project.yml` using
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open MXMasterInput.xcodeproj
```

Select your development team in Xcode, run the `MXMasterInput` scheme, grant
Accessibility permission when prompted, and select **Enable** from the menu-bar
app.

To run the automated tests:

```sh
xcodebuild \
  -project MXMasterInput.xcodeproj \
  -scheme MXMasterInput \
  -configuration Debug \
  -derivedDataPath DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build test
```

## Releases

Version tags such as `v0.1.0` run the GitHub release workflow. It tests the app,
builds a universal `arm64`/`x86_64` archive, signs it with NextByte's Developer
ID Application certificate, submits it to Apple notarization, staples the
ticket, and verifies it with both Gatekeeper and `syspolicy_check` before
publishing the ZIP and its SHA-256 checksum. The workflow rejects unsigned,
Apple Development-signed, unnotarized, or wrongly versioned builds.

The repository needs these Actions secrets before a maintainer pushes a version
tag:

- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

## How it works

MX Master Input reads Logitech's vendor-defined HID++ reports directly and
converts Sense Panel motion into the private `DockSwipe` event consumed by the
native macOS gesture pipeline. A single stream carries `began`, `changed`,
`ended`, and `cancelled` phases, allowing reversals to modify the transition
already in progress.

macOS does not publish an API for injecting this progressive gesture, so the
event format is inherently OS-version-sensitive. The current implementation is
validated on macOS 26.5.2. It disables the private path on macOS 27 and falls
back to standard Control-arrow actions.

Direct HID++ input continues while Secure Event Input is enabled. Accessibility
permission is still required to submit Mission Control and Space actions. Logi
Options+ is not required.

The `DockSwipe` field mapping was informed by the reverse engineering published
in [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix), under the
[MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).

MX Master Input is an independent project and is not affiliated with Apple or
Logitech.
