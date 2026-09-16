#import <XCTest/XCTest.h>
#import "../../Sources/MXMasterInput/NativeBridge/MXDockSwipeEvent.h"
#include <dlfcn.h>
#include <math.h>

// Read the actual attached IOKit payload, rather than testing only the Swift
// controller's mocked post callback. These tests never post system events.
@protocol MXHIDEventInspection <NSObject>
- (uint32_t)type;
- (uint32_t)options;
- (NSInteger)integerValueForField:(uint32_t)field;
- (double)doubleValueForField:(uint32_t)field;
- (NSArray<id<MXHIDEventInspection>> *)children;
@end

@interface MXDockSwipeEventTests : XCTestCase
@end

@implementation MXDockSwipeEventTests

- (void)setUp {
    [super setUp];
    XCTSkipIf(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27,
              @"HID-backed Dock gestures are validated only on macOS 27.");
}

- (id<MXHIDEventInspection>)payloadForProgress:(double)progress
                   axis:(NSInteger)axis
                  phase:(NSInteger)phase
               velocity:(double)velocity {
    return [self payloadForProgress:progress axis:axis phase:phase
                          velocity:velocity naturalScrolling:NO];
}

- (id<MXHIDEventInspection>)payloadForProgress:(double)progress
                   axis:(NSInteger)axis
                  phase:(NSInteger)phase
               velocity:(double)velocity
       naturalScrolling:(BOOL)naturalScrolling {
    CGEventRef event = MXCreateHIDDockSwipeEvent(
        progress, axis, phase, velocity, naturalScrolling
    );
    XCTAssertTrue(event != NULL);
    if (!event) return nil;
    XCTAssertEqual(CGEventGetType(event), (CGEventType)30);
    CFTypeRef (*copyHIDEvent)(CGEventRef) = dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
    XCTAssertTrue(copyHIDEvent != NULL);
    id<MXHIDEventInspection> payload = copyHIDEvent ? CFBridgingRelease(copyHIDEvent(event)) : nil;
    CFRelease(event);
    XCTAssertNotNil(payload);
    return payload;
}

- (void)testHorizontalBeginCarriesProgressAndPhase {
    id<MXHIDEventInspection> payload = [self payloadForProgress:0.25 axis:1 phase:1 velocity:0];
    XCTAssertEqual([payload type], 23u);
    XCTAssertEqual([payload options] >> 24, 1u);
    XCTAssertEqual([payload integerValueForField:(23 << 16) | 1], 1);
    XCTAssertEqual([payload integerValueForField:(23 << 16) | 5], 3);
    XCTAssertEqualWithAccuracy([payload doubleValueForField:(23 << 16) | 2], 0.25, 0.00001);
    XCTAssertEqual([payload children].count, 0u);
}

- (void)testVerticalChangePreservesNegativeProgress {
    id<MXHIDEventInspection> payload = [self payloadForProgress:-0.5 axis:2 phase:2 velocity:0];
    XCTAssertEqual([payload options] >> 24, 2u);
    XCTAssertEqual([payload integerValueForField:(23 << 16) | 1], 2);
    XCTAssertEqualWithAccuracy([payload doubleValueForField:(23 << 16) | 2], -0.5, 0.00001);
    XCTAssertEqual([payload children].count, 0u);
}

- (void)testEndAndCancelAttachVelocityChild {
    for (NSNumber *phase in @[@4, @8]) {
        id<MXHIDEventInspection> payload = [self payloadForProgress:0.75 axis:1
                                       phase:phase.integerValue velocity:-2.5];
        XCTAssertEqual([payload options] >> 24, phase.unsignedIntValue);
        XCTAssertEqual([payload children].count, 1u);
        id<MXHIDEventInspection> velocity = [payload children].firstObject;
        XCTAssertEqual([velocity type], 9u);
        XCTAssertEqualWithAccuracy([velocity doubleValueForField:(9 << 16) | 0], -2.5, 0.00001);
        XCTAssertEqualWithAccuracy([velocity doubleValueForField:(9 << 16) | 1], -2.5, 0.00001);
        XCTAssertEqualWithAccuracy([velocity doubleValueForField:(9 << 16) | 2], 0.0, 0.00001);
    }
}

- (void)testNaturalScrollingConvertsBothAxesWithoutChangingVelocity {
    for (NSNumber *axis in @[@1, @2]) {
        for (NSNumber *natural in @[@YES, @NO]) {
            // Positive horizontal input means next Space; negative vertical
            // input means Mission Control. Both need the same normalization.
            double progress = axis.integerValue == 1 ? 0.5 : -0.5;
            id<MXHIDEventInspection> payload = [self
                payloadForProgress:progress axis:axis.integerValue phase:4
                velocity:2.5 naturalScrolling:natural.boolValue];
            double expected = natural.boolValue ? -progress : progress;
            XCTAssertEqualWithAccuracy(
                [payload doubleValueForField:(23 << 16) | 2], expected, 0.00001
            );
            id<MXHIDEventInspection> velocity = [payload children].firstObject;
            XCTAssertEqualWithAccuracy(
                [velocity doubleValueForField:(9 << 16) | 0], 2.5, 0.00001
            );
        }
    }
}

- (void)testRejectsInvalidGestureParameters {
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(0.2, 0, 1, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(0.2, 3, 1, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(0.2, 1, 0, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(0.2, 1, 3, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(NAN, 1, 1, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(INFINITY, 1, 1, 0, YES) == NULL);
    XCTAssertTrue(MXCreateHIDDockSwipeEvent(0.2, 1, 4, INFINITY, YES) == NULL);
}
@end
