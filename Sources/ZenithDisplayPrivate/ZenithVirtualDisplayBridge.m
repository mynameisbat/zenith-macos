#import "ZenithVirtualDisplayBridge.h"

// Private CoreGraphics interfaces
@class CGVirtualDisplayDescriptor;

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
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
@property(retain, nonatomic) dispatch_queue_t queue;
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
    descriptor.sizeInMillimeters = CGSizeMake(527, 296);
    descriptor.queue = dispatch_queue_create("app.zenith.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    descriptor.vendorID = 0x3456;
    descriptor.productID = 0x1234;
    descriptor.serialNum = 0x0001;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"[ZenithVirtualDisplayBridge] display initWithDescriptor returned nil");
        return nil;
    }

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];
    CGVirtualDisplayMode *hidpiMode = nil;
    if (hiDPI && width >= 2 && height >= 2) {
        hidpiMode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)(width / 2) height:(unsigned int)(height / 2) refreshRate:(double)refreshRate];
        if (hidpiMode) [modes addObject:hidpiMode];
    }
    CGVirtualDisplayMode *nativeMode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate];
    if (nativeMode) [modes addObject:nativeMode];

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modes;

    BOOL ok = [display applySettings:settings];
    CGDisplayModeRef dm = CGDisplayCopyDisplayMode(display.displayID);
    NSLog(@"[ZenithVirtualDisplayBridge] hidpiMode=%@ nativeMode=%@ modes=%lu applySettings=%d displayID=%u dm=%@", hidpiMode, nativeMode, (unsigned long)modes.count, ok, display.displayID, dm);
    if (dm) CGDisplayModeRelease(dm);
    if (!ok) {
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
