#import "SystemEvents.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include <math.h>

// Declarations for IOKit's private HIDEvent class. The class and the SkyLight setter are resolved at
// run time, so a macOS without them returns NULL (and the caller falls back to keyboard shortcuts)
// instead of failing to launch.
@interface HIDEvent : NSObject
- (instancetype)initWithType:(uint32_t)type timestamp:(uint64_t)timestamp senderID:(uint64_t)senderID;
@property(nonatomic) uint32_t options;
- (void)setIntegerValue:(NSInteger)value forField:(uint32_t)field;
- (void)setDoubleValue:(double)value forField:(uint32_t)field;
- (void)appendEvent:(HIDEvent *)event;
@end

typedef void (*MXSetHIDEventFunction)(CGEventRef, CFTypeRef);

CGEventRef MXCreateHIDDockSwipeEvent(double progress, NSInteger axis, NSInteger phase,
                                     double exitSpeed, BOOL naturalScrolling) {
    if ((axis != 1 && axis != 2) || (phase != 1 && phase != 2 && phase != 4 && phase != 8)
        || !isfinite(progress) || !isfinite(exitSpeed)) {
        return NULL;
    }

    static Class eventClass;
    static MXSetHIDEventFunction setHIDEvent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Never closed: the cached function pointer lives as long as the process.
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!skyLight) return;
        setHIDEvent = (MXSetHIDEventFunction)dlsym(skyLight, "SLEventSetIOHIDEvent");
        Class candidate = NSClassFromString(@"HIDEvent");
        if ([candidate instancesRespondToSelector:@selector(initWithType:timestamp:senderID:)]
            && [candidate instancesRespondToSelector:@selector(setOptions:)]
            && [candidate instancesRespondToSelector:@selector(setIntegerValue:forField:)]
            && [candidate instancesRespondToSelector:@selector(setDoubleValue:forField:)]
            && [candidate instancesRespondToSelector:@selector(appendEvent:)]) {
            eventClass = candidate;
        }
    });
    if (!eventClass || !setHIDEvent) return NULL;

    // IOKit event types and fields, from Mac Mouse Fix's macOS 27 investigation:
    // https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Tests/FixDockSwipes.m
    const uint32_t dockSwipeType = 23, velocityType = 9;
    const uint32_t dockFields = dockSwipeType << 16, velocityFields = velocityType << 16;
    HIDEvent *swipe = [[eventClass alloc] initWithType:dockSwipeType timestamp:0 senderID:0];
    if (!swipe) return NULL;
    swipe.options = (uint32_t)phase << 24;
    [swipe setIntegerValue:axis forField:dockFields | 1];
    [swipe setIntegerValue:3 forField:dockFields | 5]; // Dock's primary flavor
    // Unlike the macOS 26 CGEvent fields, the Dock applies natural scrolling to HID progress. Undo it
    // so the panel mapping stays fixed. Velocity keeps the uninverted sign, as in a real gesture.
    [swipe setDoubleValue:(naturalScrolling ? -progress : progress) forField:dockFields | 2];

    if (phase == 4 || phase == 8) {
        HIDEvent *velocity = [[eventClass alloc] initWithType:velocityType timestamp:0 senderID:0];
        if (!velocity) return NULL;
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

BOOL MXPostControlArrow(CGKeyCode keyCode) {
    if (keyCode != kVK_LeftArrow && keyCode != kVK_RightArrow && keyCode != kVK_UpArrow && keyCode != kVK_DownArrow) {
        return NO;
    }
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return NO;

    const struct { CGKeyCode key; Boolean down; } events[] = {
        {kVK_Control, true}, {keyCode, true}, {keyCode, false}, {kVK_Control, false},
    };
    BOOL succeeded = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (size_t i = 0; i < sizeof events / sizeof events[0]; i++) {
        // Release every key even if an earlier one failed, so Control is never left down.
        succeeded &= AXUIElementPostKeyboardEvent(systemWide, 0, events[i].key, events[i].down) == kAXErrorSuccess;
    }
#pragma clang diagnostic pop
    CFRelease(systemWide);
    return succeeded;
}
