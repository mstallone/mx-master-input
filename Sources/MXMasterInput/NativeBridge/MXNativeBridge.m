#import "MXNativeBridge.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>

static NSString *const MXHIDErrorDomain = @"com.mattstallone.mxmasterinput.hid";
static const NSInteger MXLogitechVendorID = 0x046D;

static NSInteger MXIntegerProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }

    NSInteger result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &result);
    return result;
}

static NSString *MXStringProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return @"";
    }
    return [(__bridge NSString *)value copy];
}

@interface MXHIDDeviceInfo () {
    IOHIDDeviceRef _device;
}

- (instancetype)initWithDevice:(IOHIDDeviceRef)device;
@property(nonatomic, readonly) IOHIDDeviceRef device;

@end

@implementation MXHIDDeviceInfo

- (instancetype)initWithDevice:(IOHIDDeviceRef)device {
    self = [super init];
    if (self) {
        _device = (IOHIDDeviceRef)CFRetain(device);
        _vendorID = MXIntegerProperty(device, CFSTR(kIOHIDVendorIDKey));
        _productID = MXIntegerProperty(device, CFSTR(kIOHIDProductIDKey));
        _usagePage = MXIntegerProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
        _usage = MXIntegerProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
        _maxInputReportSize = MXIntegerProperty(
            device, CFSTR(kIOHIDMaxInputReportSizeKey)
        );
        _maxOutputReportSize = MXIntegerProperty(
            device, CFSTR(kIOHIDMaxOutputReportSizeKey)
        );
        _productName = MXStringProperty(device, CFSTR(kIOHIDProductKey));
        _transport = MXStringProperty(device, CFSTR(kIOHIDTransportKey));
    }
    return self;
}

- (void)dealloc {
    if (_device) {
        CFRelease(_device);
        _device = NULL;
    }
}

- (IOHIDDeviceRef)device {
    return _device;
}

@end

@interface MXHIDConnection () {
    IOHIDDeviceRef _device;
    NSThread *_inputThread;
    CFRunLoopRef _inputRunLoop;
    dispatch_semaphore_t _openSemaphore;
    dispatch_semaphore_t _closeSemaphore;
    uint8_t *_reportBuffer;
    CFIndex _reportBufferSize;
    MXHIDReportHandler _reportHandler;
    NSError *_threadOpenError;
    BOOL _opened;
    BOOL _opening;
    BOOL _stopRequested;
}

- (void)handleInputReport:(const uint8_t *)report
                   length:(CFIndex)reportLength;
- (void)runInputThread;

@end

static void MXInputReportCallback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength
) {
    (void)sender;
    (void)type;
    (void)reportID;

    if (!context || result != kIOReturnSuccess || !report || reportLength <= 0) {
        return;
    }

    MXHIDConnection *connection = (__bridge MXHIDConnection *)context;
    [connection handleInputReport:report length:reportLength];
}

static void MXRunLoopKeepAlive(void *info) {
    (void)info;
}

@implementation MXHIDConnection

- (void)handleInputReport:(const uint8_t *)report
                   length:(CFIndex)reportLength {
    MXHIDReportHandler handler = _reportHandler;
    if (!handler) {
        return;
    }

    NSData *data = [NSData dataWithBytes:report length:(NSUInteger)reportLength];
    handler(data);
}

+ (NSArray<MXHIDDeviceInfo *> *)logitechVendorDevices {
    IOHIDManagerRef manager = IOHIDManagerCreate(
        kCFAllocatorDefault, kIOHIDOptionsTypeNone
    );
    if (!manager) {
        return @[];
    }

    NSDictionary *matching = @{
        @kIOHIDVendorIDKey: @(MXLogitechVendorID),
    };
    IOHIDManagerSetDeviceMatching(
        manager, (__bridge CFDictionaryRef)matching
    );

    IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        CFRelease(manager);
        return @[];
    }

    CFSetRef deviceSet = IOHIDManagerCopyDevices(manager);
    if (!deviceSet) {
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return @[];
    }

    NSMutableArray<MXHIDDeviceInfo *> *result = [NSMutableArray array];
    CFIndex count = CFSetGetCount(deviceSet);
    IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    if (devices) {
        CFSetGetValues(deviceSet, (const void **)devices);
        for (CFIndex index = 0; index < count; index++) {
            IOHIDDeviceRef device = devices[index];
            NSInteger usagePage = MXIntegerProperty(
                device, CFSTR(kIOHIDPrimaryUsagePageKey)
            );
            NSInteger maxOutput = MXIntegerProperty(
                device, CFSTR(kIOHIDMaxOutputReportSizeKey)
            );

            // HID++ lives on Logitech's vendor-defined HID collection.
            // Requiring a 20-byte output report excludes the receiver's
            // standard mouse and keyboard collections.
            if (usagePage < 0xFF00 || maxOutput < 20) {
                continue;
            }
            [result addObject:[[MXHIDDeviceInfo alloc] initWithDevice:device]];
        }
        free(devices);
    }

    CFRelease(deviceSet);
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);

    [result sortUsingComparator:^NSComparisonResult(
        MXHIDDeviceInfo *left, MXHIDDeviceInfo *right
    ) {
        if (left.productID != right.productID) {
            return left.productID < right.productID
                ? NSOrderedAscending
                : NSOrderedDescending;
        }
        if (left.usagePage != right.usagePage) {
            return left.usagePage < right.usagePage
                ? NSOrderedAscending
                : NSOrderedDescending;
        }
        return left.usage < right.usage
            ? NSOrderedAscending
            : (left.usage > right.usage ? NSOrderedDescending : NSOrderedSame);
    }];
    return result;
}

- (instancetype)initWithDeviceInfo:(MXHIDDeviceInfo *)deviceInfo {
    self = [super init];
    if (self) {
        _device = (IOHIDDeviceRef)CFRetain(deviceInfo.device);
    }
    return self;
}

- (void)dealloc {
    [self close];
    if (_device) {
        CFRelease(_device);
        _device = NULL;
    }
}

- (BOOL)openWithReportHandler:(MXHIDReportHandler)reportHandler
                        error:(NSError **)error {
    dispatch_semaphore_t openSemaphore = nil;

    @synchronized(self) {
        if (_opened) {
            return YES;
        }

        if (_opening) {
            if (error) {
                *error = [NSError errorWithDomain:MXHIDErrorDomain
                                             code:kIOReturnBusy
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"The HID device is already being opened.",
                }];
            }
            return NO;
        }

        _opening = YES;
        _stopRequested = NO;
        _threadOpenError = nil;
        _reportHandler = [reportHandler copy];
        _reportBufferSize = MAX(
            64,
            MXIntegerProperty(_device, CFSTR(kIOHIDMaxInputReportSizeKey))
        );
        _reportBuffer = calloc((size_t)_reportBufferSize, sizeof(uint8_t));
        if (!_reportBuffer) {
            _opening = NO;
            _reportHandler = nil;
            _reportBufferSize = 0;
            if (error) {
                *error = [NSError errorWithDomain:MXHIDErrorDomain
                                             code:kIOReturnNoMemory
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Unable to allocate the HID input-report buffer.",
                }];
            }
            return NO;
        }

        _openSemaphore = dispatch_semaphore_create(0);
        _closeSemaphore = dispatch_semaphore_create(0);
        openSemaphore = _openSemaphore;
        _inputThread = [[NSThread alloc]
            initWithTarget:self
                  selector:@selector(runInputThread)
                    object:nil
        ];
        _inputThread.name =
            @"com.mattstallone.mxmasterinput.hid-run-loop";
        _inputThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_inputThread start];
    }

    long waitResult = dispatch_semaphore_wait(
        openSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC))
    );
    if (waitResult != 0) {
        [self close];
        if (error) {
            *error = [NSError errorWithDomain:MXHIDErrorDomain
                                         code:kIOReturnTimeout
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Timed out while opening the HID input run loop.",
            }];
        }
        return NO;
    }

    @synchronized(self) {
        if (_opened) {
            return YES;
        }
        if (error) {
            *error = _threadOpenError ?: [NSError
                errorWithDomain:MXHIDErrorDomain
                           code:kIOReturnError
                       userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"The HID input run loop did not open.",
                }
            ];
        }
        return NO;
    }
}

- (void)runInputThread {
    @autoreleasepool {
        IOReturn result = IOHIDDeviceOpen(
            _device, kIOHIDOptionsTypeNone
        );
        if (result != kIOReturnSuccess) {
            dispatch_semaphore_t openSemaphore = nil;
            dispatch_semaphore_t closeSemaphore = nil;

            @synchronized(self) {
                _threadOpenError = [NSError
                    errorWithDomain:MXHIDErrorDomain
                               code:result
                           userInfo:@{
                        NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:
                                @"IOHIDDeviceOpen failed: 0x%08X", result],
                    }
                ];
                _opening = NO;
                _reportHandler = nil;
                if (_reportBuffer) {
                    free(_reportBuffer);
                    _reportBuffer = NULL;
                }
                _reportBufferSize = 0;
                _inputThread = nil;
                openSemaphore = _openSemaphore;
                closeSemaphore = _closeSemaphore;
            }

            dispatch_semaphore_signal(openSemaphore);
            dispatch_semaphore_signal(closeSemaphore);
            return;
        }

        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        CFRetain(runLoop);

        CFRunLoopSourceContext sourceContext = {0};
        sourceContext.perform = MXRunLoopKeepAlive;
        CFRunLoopSourceRef keepAliveSource = CFRunLoopSourceCreate(
            kCFAllocatorDefault, 0, &sourceContext
        );
        if (keepAliveSource) {
            CFRunLoopAddSource(
                runLoop, keepAliveSource, kCFRunLoopDefaultMode
            );
        }

        IOHIDDeviceScheduleWithRunLoop(
            _device, runLoop, kCFRunLoopDefaultMode
        );
        IOHIDDeviceRegisterInputReportCallback(
            _device,
            _reportBuffer,
            _reportBufferSize,
            MXInputReportCallback,
            (__bridge void *)self
        );

        dispatch_semaphore_t openSemaphore = nil;
        BOOL shouldStop = NO;
        @synchronized(self) {
            _inputRunLoop = runLoop;
            _opened = YES;
            _opening = NO;
            shouldStop = _stopRequested;
            openSemaphore = _openSemaphore;
        }
        dispatch_semaphore_signal(openSemaphore);

        if (!shouldStop) {
            CFRunLoopRun();
        }

        IOHIDDeviceUnscheduleFromRunLoop(
            _device, runLoop, kCFRunLoopDefaultMode
        );
        if (keepAliveSource) {
            CFRunLoopRemoveSource(
                runLoop, keepAliveSource, kCFRunLoopDefaultMode
            );
            CFRelease(keepAliveSource);
        }
        IOHIDDeviceClose(_device, kIOHIDOptionsTypeNone);

        dispatch_semaphore_t closeSemaphore = nil;
        @synchronized(self) {
            _inputRunLoop = NULL;
            _opened = NO;
            _opening = NO;
            _stopRequested = NO;
            _reportHandler = nil;
            if (_reportBuffer) {
                free(_reportBuffer);
                _reportBuffer = NULL;
            }
            _reportBufferSize = 0;
            _inputThread = nil;
            closeSemaphore = _closeSemaphore;
        }

        CFRelease(runLoop);
        dispatch_semaphore_signal(closeSemaphore);
    }
}

- (BOOL)sendOutputReport:(NSData *)report error:(NSError **)error {
    if (report.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:MXHIDErrorDomain
                                         code:kIOReturnBadArgument
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"The HID output report is empty.",
            }];
        }
        return NO;
    }

    @synchronized(self) {
        if (!_opened) {
            if (error) {
                *error = [NSError errorWithDomain:MXHIDErrorDomain
                                             code:kIOReturnNotOpen
                                         userInfo:@{
                    NSLocalizedDescriptionKey: @"The HID device is not open.",
                }];
            }
            return NO;
        }

        const uint8_t *bytes = report.bytes;
        IOReturn result = IOHIDDeviceSetReport(
            _device,
            kIOHIDReportTypeOutput,
            bytes[0],
            bytes,
            (CFIndex)report.length
        );
        if (result == kIOReturnSuccess) {
            return YES;
        }

        if (error) {
            *error = [NSError errorWithDomain:MXHIDErrorDomain
                                         code:result
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"IOHIDDeviceSetReport failed: 0x%08X", result],
            }];
        }
        return NO;
    }
}

- (void)close {
    dispatch_semaphore_t closeSemaphore = nil;
    NSThread *inputThread = nil;
    CFRunLoopRef inputRunLoop = NULL;
    BOOL shouldWait = NO;

    @synchronized(self) {
        if (!_opened && !_opening && !_inputThread) {
            return;
        }

        _stopRequested = YES;
        inputThread = _inputThread;
        closeSemaphore = _closeSemaphore;
        if (_inputRunLoop) {
            inputRunLoop = (CFRunLoopRef)CFRetain(_inputRunLoop);
        }
        shouldWait = inputThread
            && inputThread != [NSThread currentThread];
    }

    if (inputRunLoop) {
        if (inputThread == [NSThread currentThread]) {
            CFRunLoopStop(inputRunLoop);
        } else {
            CFRunLoopPerformBlock(
                inputRunLoop,
                kCFRunLoopDefaultMode,
                ^{
                    CFRunLoopStop(inputRunLoop);
                }
            );
            CFRunLoopWakeUp(inputRunLoop);
        }
        CFRelease(inputRunLoop);
    }

    if (shouldWait && closeSemaphore) {
        dispatch_semaphore_wait(
            closeSemaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC))
        );
    }
}

@end

BOOL MXHasPostEventAccess(void) {
    return CGPreflightPostEventAccess();
}

BOOL MXRequestPostEventAccess(void) {
    return CGRequestPostEventAccess();
}

BOOL MXPostControlArrow(NSInteger keyCode) {
    switch (keyCode) {
        case kVK_LeftArrow:
        case kVK_RightArrow:
        case kVK_UpArrow:
        case kVK_DownArrow:
            break;
        default:
            return NO;
    }

    if (!CGPreflightPostEventAccess()) {
        return NO;
    }

    AXUIElementRef systemWideElement = AXUIElementCreateSystemWide();
    if (!systemWideElement) {
        return NO;
    }

    // macOS symbolic hotkeys ignore equivalent application-posted CGEvents.
    // Posting the physical chord through the system-wide Accessibility element
    // matches System Events and is recognized as Control-arrow.
    struct {
        CGKeyCode keyCode;
        Boolean keyDown;
    } events[] = {
        {kVK_Control, true},
        {(CGKeyCode)keyCode, true},
        {(CGKeyCode)keyCode, false},
        {kVK_Control, false},
    };

    BOOL succeeded = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (size_t index = 0; index < 4; index++) {
        AXError error = AXUIElementPostKeyboardEvent(
            systemWideElement,
            0,
            events[index].keyCode,
            events[index].keyDown
        );
        if (error != kAXErrorSuccess) {
            succeeded = NO;
        }
    }
#pragma clang diagnostic pop

    CFRelease(systemWideElement);
    return succeeded;
}

BOOL MXIsSecureInputEnabled(void) {
    return IsSecureEventInputEnabled();
}
