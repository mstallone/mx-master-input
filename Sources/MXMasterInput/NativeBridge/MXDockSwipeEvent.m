#import "MXDockSwipeEvent.h"

#include <dlfcn.h>
#include <math.h>

// Minimal declarations for IOKit's private HIDEvent runtime class. Resolve
// the class and SkyLight setter dynamically so unavailable APIs fall back
// without relying on CGEvent memory offsets or a hard private-framework link.
@interface HIDEvent : NSObject
- (instancetype)initWithType:(uint32_t)type
                  timestamp:(uint64_t)timestamp
                   senderID:(uint64_t)senderID;
@property(nonatomic) uint32_t options;
- (void)setIntegerValue:(NSInteger)value forField:(uint32_t)field;
- (void)setDoubleValue:(double)value forField:(uint32_t)field;
- (void)appendEvent:(HIDEvent *)event;
@end

typedef void (*MXSetHIDEventFunction)(CGEventRef, CFTypeRef);

CGEventRef MXCreateHIDDockSwipeEvent(
    double progress,
    NSInteger type,
    NSInteger phase,
    double exitSpeed,
    BOOL naturalScrolling
) {
    if ((type != 1 && type != 2)
        || (phase != 1 && phase != 2 && phase != 4 && phase != 8)
        || !isfinite(progress) || !isfinite(exitSpeed)) {
        return NULL;
    }

    static Class eventClass;
    static MXSetHIDEventFunction setHIDEvent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (!skyLight) {
            return;
        }
        // Keep the framework loaded for the lifetime of the cached pointer.
        setHIDEvent = (MXSetHIDEventFunction)dlsym(
            skyLight, "SLEventSetIOHIDEvent"
        );
        Class candidate = NSClassFromString(@"HIDEvent");
        if ([candidate instancesRespondToSelector:@selector(initWithType:timestamp:senderID:)]
            && [candidate instancesRespondToSelector:@selector(setOptions:)]
            && [candidate instancesRespondToSelector:@selector(setIntegerValue:forField:)]
            && [candidate instancesRespondToSelector:@selector(setDoubleValue:forField:)]
            && [candidate instancesRespondToSelector:@selector(appendEvent:)]) {
            eventClass = candidate;
        }
    });
    if (!eventClass || !setHIDEvent) {
        return NULL;
    }

    // IOKit event types/fields; see Mac Mouse Fix's macOS 27 investigation:
    // https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Tests/FixDockSwipes.m
    const uint32_t dockSwipeType = 23;
    const uint32_t velocityType = 9;
    const uint32_t dockFields = dockSwipeType << 16;
    const uint32_t velocityFields = velocityType << 16;
    HIDEvent *swipe = [[eventClass alloc] initWithType:dockSwipeType
                                          timestamp:0 senderID:0];
    if (!swipe) {
        return NULL;
    }
    swipe.options = (uint32_t)phase << 24;
    [swipe setIntegerValue:type forField:dockFields | 1]; // motion axis
    [swipe setIntegerValue:3 forField:dockFields | 5]; // Dock primary flavor
    // Unlike the legacy CGEvent fields, Dock applies the system's natural
    // scrolling inversion to HID progress. Undo it to keep our fixed panel
    // mapping (left -> next Space, up -> Mission Control). Velocity retains
    // the legacy sign, as in the real gesture envelope.
    const double hidProgress = naturalScrolling ? -progress : progress;
    [swipe setDoubleValue:hidProgress forField:dockFields | 2];

    if (phase == 4 || phase == 8) {
        HIDEvent *velocity = [[eventClass alloc] initWithType:velocityType
                                                 timestamp:0 senderID:0];
        if (!velocity) {
            return NULL;
        }
        [velocity setDoubleValue:exitSpeed forField:velocityFields | 0];
        [velocity setDoubleValue:exitSpeed forField:velocityFields | 1];
        [velocity setDoubleValue:0 forField:velocityFields | 2];
        [swipe appendEvent:velocity];
    }

    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        CGEventSetType(event, (CGEventType)30);
        setHIDEvent(event, (__bridge CFTypeRef)swipe);
    }
    return event;
}
