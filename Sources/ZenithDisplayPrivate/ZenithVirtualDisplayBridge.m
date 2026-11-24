#import "ZenithVirtualDisplayBridge.h"

// Private CoreGraphics interfaces
@class CGVirtualDisplayDescriptor;

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t dispatchQueue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface ZenithVirtualDisplayBridge ()
@property(strong, nonatomic, nullable) CGVirtualDisplay *display;
@end

@implementation ZenithVirtualDisplayBridge

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(CGFloat)refreshRate
                                hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (!self) return nil;

    if (![ZenithVirtualDisplayBridge isSupported]) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)width;
    descriptor.maxPixelsHigh = (unsigned int)height;
    descriptor.sizeInMillimeters = CGSizeMake(1600, 1000);
    descriptor.dispatchQueue = dispatch_get_main_queue();
    descriptor.vendorID = 0x3456;
    descriptor.productID = 0x1234;
    descriptor.serialNum = 0x0001;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) return nil;

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[mode];

    if (![display applySettings:settings]) {
        return nil;
    }

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : 0;
}

- (void)destroy {
    _display = nil;
}

- (void)dealloc {
    [self destroy];
}

@end
