#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C bridge providing safe access to CoreGraphics private CGVirtualDisplay API.
@interface ZenithVirtualDisplayBridge : NSObject

/// The CGDirectDisplayID allocated by the window server, or 0 if inactive.
@property(readonly, nonatomic) CGDirectDisplayID displayID;

/// Whether the system window server supports CGVirtualDisplay.
+ (BOOL)isSupported;

/// Initializes and attaches a virtual display with the given properties.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(CGFloat)refreshRate
                                hiDPI:(BOOL)hiDPI;

/// Destroys the virtual display.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
