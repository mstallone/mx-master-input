#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Creates the HID-backed gesture envelope consumed by Dock on macOS 27.
// Returns NULL when the private runtime API is unavailable. Does not post it.
CGEventRef _Nullable MXCreateHIDDockSwipeEvent(
    double progress,
    NSInteger type,
    NSInteger phase,
    double exitSpeed
) CF_RETURNS_RETAINED;
