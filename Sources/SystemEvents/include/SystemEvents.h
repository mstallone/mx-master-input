#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// The two system events that need Objective-C. Everything else is in Swift.

NS_ASSUME_NONNULL_BEGIN

/// Builds the DockSwipe event that the Dock consumes on macOS 27: a CGEvent carrying a private IOKit
/// HIDEvent. `axis` is 1 (horizontal) or 2 (vertical); `phase` is 1, 2, 4 or 8 (began, changed, ended,
/// cancelled). Returns NULL for invalid arguments or when the private runtime API is unavailable.
/// The event is not posted.
CGEventRef _Nullable MXCreateHIDDockSwipeEvent(double progress, NSInteger axis, NSInteger phase,
                                               double exitSpeed, BOOL naturalScrolling) CF_RETURNS_RETAINED;

/// Presses Control and an arrow key through the system-wide Accessibility element. Symbolic hot keys
/// ignore application-posted CGEvents; this path is the one System Events uses, and they accept it.
/// Returns NO for a key code that is not an arrow, or when any of the four key events fails.
BOOL MXPostControlArrow(CGKeyCode keyCode);

NS_ASSUME_NONNULL_END
