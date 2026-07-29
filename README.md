# MX Master Input

**Trackpad-style macOS gestures for the Logitech MX Master 4 Sense Panel.**

MX Master Input brings the Magic Trackpad's progressive Mission Control and
Space-switching gestures to the MX Master 4. It reads the Sense Panel directly
over Logitech HID++ and drives a continuous macOS gesture instead of translating
each swipe into a keyboard shortcut. The desktop follows your movement—even
when you pause or reverse direction—then commits or snaps back when you
release.

## Requirements

- Logitech MX Master 4 connected through the Logi Bolt receiver
  (`0x046D:0xC548`)
- Apple silicon Mac running macOS 26.5.2 (`25F84`)
- Accessibility permission for posting system actions

Version 0.1.3 is validated with Xcode 26.6 and Swift 6.3.

## Controls

| Sense Panel input | Action |
| --- | --- |
| Tap | Mission Control |
| Hold and drag up | Mission Control |
| Hold and drag down | Close Mission Control when it is open |
| Hold and drag left | Next Space |
| Hold and drag right | Previous Space |

The Space mapping is intentionally reversed so the desktop tracks the physical
motion naturally. A central dead zone ignores movement caused by pressing the
panel, and each swipe locks to its initial horizontal or vertical axis.

Mission Control taps and the compatibility fallback use the Control-arrow
shortcuts configured in macOS Keyboard settings.

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

## Updates and releases

The app uses [Sparkle 2](https://sparkle-project.org/) to check for updates
daily and install them automatically. **Check for Updates…** in the menu-bar
menu starts a check immediately.

Version tags such as `v0.1.3` run the GitHub release workflow. It tests, signs,
notarizes, and verifies a universal app before publishing the ZIP, SHA-256
checksum, and Sparkle-signed `appcast.xml` to GitHub Releases.

The workflow requires these Actions secrets:

- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `SPARKLE_ED_PRIVATE_KEY`

`SPARKLE_ED_PRIVATE_KEY` is the private EdDSA key exported by Sparkle's
`generate_keys` tool. Its public half is committed in `Info.plist`. The private
key is also stored in the macOS Keychain under the
`com.mattstallone.mxmasterinput` Sparkle account. Keep it in Actions secrets and
a secure backup; replacing both it and the Developer ID identity can prevent
installed copies from accepting updates.

## How it works

MX Master Input reads Logitech's vendor-defined HID++ reports directly and
converts horizontal and vertical Sense Panel motion into the private
`DockSwipe` event used by macOS.

Because macOS does not publish an API for injecting progressive gestures, this
event format is OS-version-sensitive. The private path is validated on macOS
26.5.2, disabled on macOS 27, and replaced there with standard Control-arrow
actions.

Direct HID++ input continues while Secure Event Input is enabled. Accessibility
permission is still required to submit Mission Control and Space actions. Logi
Options+ is not required.

The `DockSwipe` field mapping was informed by the reverse engineering published
in [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix), under its
[MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License).

MX Master Input is an independent project and is not affiliated with Apple or
Logitech.
