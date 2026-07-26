#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MXHIDDeviceInfo : NSObject

@property(nonatomic, readonly) NSInteger vendorID;
@property(nonatomic, readonly) NSInteger productID;
@property(nonatomic, readonly) NSInteger usagePage;
@property(nonatomic, readonly) NSInteger usage;
@property(nonatomic, readonly) NSInteger maxInputReportSize;
@property(nonatomic, readonly) NSInteger maxOutputReportSize;
@property(nonatomic, copy, readonly) NSString *productName;
@property(nonatomic, copy, readonly) NSString *transport;

@end

typedef void (^MXHIDReportHandler)(NSData *report);

@interface MXHIDConnection : NSObject

+ (NSArray<MXHIDDeviceInfo *> *)logitechVendorDevices;

- (instancetype)initWithDeviceInfo:(MXHIDDeviceInfo *)deviceInfo;
- (BOOL)openWithReportHandler:(MXHIDReportHandler)reportHandler
                        error:(NSError **)error;
- (BOOL)sendOutputReport:(NSData *)report error:(NSError **)error;
- (void)close;

@end

FOUNDATION_EXPORT BOOL MXHasPostEventAccess(void);
FOUNDATION_EXPORT BOOL MXRequestPostEventAccess(void);
FOUNDATION_EXPORT BOOL MXPostControlArrow(NSInteger keyCode);
FOUNDATION_EXPORT BOOL MXPostHorizontalDockSwipe(
    double progress,
    NSInteger phase
);
FOUNDATION_EXPORT BOOL MXIsSecureInputEnabled(void);

NS_ASSUME_NONNULL_END
