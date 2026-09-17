# Thumb wheel scrolling

The goal is to deliver the scrolling input an application expects from a
trackpad. Back/forward navigation belongs to the application receiving it.

## Research

- Apple's [precise scrolling documentation](https://developer.apple.com/documentation/appkit/nsevent/hasprecisescrollingdeltas)
  distinguishes coarse mouse-wheel steps from precise scrolling deltas.
- Apple's [scroll swipe tracking API](https://developer.apple.com/documentation/appkit/nsevent/trackswipeevent(options:dampenamountthresholdmin:max:usinghandler:))
  lets an application turn scroll-wheel events into an interactive page swipe.
- [WebKit's macOS gesture controller](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/ViewGestureControllerMac.mm)
  checks precise deltas, scroll phases, and whether swipe tracking is enabled.
  Its [shared gesture controller](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ViewGestureController.cpp)
  also considers horizontal direction, scroll-edge state, and available history.
  This supports letting Safari interpret the scrolling stream itself; it does
  not establish that every Safari version accepts this synthetic stream.
- [Logiops' thumb-wheel protocol implementation](https://github.com/PixlOne/logiops/blob/main/src/logid/backend/hidpp20/features/ThumbWheel.cpp)
  documents through its implementation the HID++ 0x2150 info/status/reporting
  calls and signed rotation reports. The corresponding header identifies
  inactive/start/active/stop states. Solaar independently uses this feature for
  [thumb wheel diversion](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py).

## Implementation

Only the connected MX Master 4's thumb wheel is diverted. Raw wheel resolution
and direction come from the device. The initial gain is 1,200 pixels per full
wheel revolution. Each delta is spread over four frames at 120 Hz, with integer
pixel rounding that preserves total movement. Reversal flushes buffered motion.

Output uses pixel-unit Core Graphics scrolling with continuous data and
began/changed/ended phases. macOS natural scrolling is applied once per gesture.
Stop reports finish the stream after the smoothing buffer drains; a 300 ms idle
watchdog handles a missing stop report. Disconnect, disable, and wake recovery
cancel active scrolling. Original wheel reporting/inversion is saved and
restored on normal shutdown. No global scroll event tap or browser shortcuts
are used. No additional momentum is synthesized after release.

## Validation

Automated tests convert the actual generated CGEvents into NSEvents and check
precise horizontal deltas, AppKit phases, and absence of vertical scrolling.
Additional tests cover packet filtering, direction preferences, reversal,
smoothing distance, release, cancellation, and missing begin/stop reports.

Still requires a physical MX Master 4 check:

1. Compare slow/fast wheel movement and reversals with a trackpad in a wide
   document; tune gain and smoothing if needed.
2. In Safari with browsing history and page swiping enabled, compare behavior
   over horizontally scrollable content and at its edge.
3. Verify behavior with natural scrolling on and off, and after mouse sleep.
4. Disable the app and confirm ordinary thumb-wheel scrolling is restored.

A successful build and event-property tests do not verify device firmware
behavior, Safari's acceptance of injected gestures, or subjective smoothness.
