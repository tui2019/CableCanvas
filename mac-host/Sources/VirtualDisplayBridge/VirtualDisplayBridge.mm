#include "VirtualDisplayBridge.h"
#include <algorithm>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

@class CGVirtualDisplayDescriptor;
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
- (instancetype)init;
@end

static CGVirtualDisplay* gDisplay = nil;
static CGVirtualDisplayDescriptor* gDescriptor = nil;
static CGVirtualDisplaySettings* gSettings = nil;

static unsigned int hashString(const char* text) {
    unsigned long hash = 5381;
    if (text == nullptr) return 1;
    for (const char* p = text; *p; ++p) {
        hash = ((hash << 5) + hash) + static_cast<unsigned long>(*p);
    }
    return static_cast<unsigned int>(hash & 0xFFFFFFFF);
}

static void cleanupDisplay() {
    if (gDisplay) {
        gDisplay = nil;
    }
    if (gSettings) {
        gSettings = nil;
    }
    if (gDescriptor) {
        gDescriptor = nil;
    }
}

static bool configureMirror(bool mirrorMain) {
    if (!gDisplay) return false;
    if (!mirrorMain) return true;

    CGDisplayConfigRef config = nullptr;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;

    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGError err = CGConfigureDisplayMirrorOfDisplay(config, gDisplay.displayID, mainDisplay);

    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
}

bool cc_create_virtual_display(
    uint32_t width,
    uint32_t height,
    uint32_t refresh_rate,
    bool hi_dpi,
    bool mirror_main,
    const char* display_name
) {
    @autoreleasepool {
        if (width == 0 || height == 0) return false;
        cleanupDisplay();

        NSString* name = display_name ? [NSString stringWithUTF8String:display_name] : @"CableCanvas Virtual";
        if (!name || [name length] == 0) {
            name = @"CableCanvas Virtual";
        }

        gDescriptor = [[CGVirtualDisplayDescriptor alloc] init];
        gDescriptor.name = name;
        gDescriptor.maxPixelsWide = width;
        gDescriptor.maxPixelsHigh = height;

        // Approximate physical size using typical desktop PPI.
        double ppi = 110.0;
        double ratio = 25.4 / ppi;
        gDescriptor.sizeInMillimeters = CGSizeMake(width * ratio, height * ratio);

        unsigned int stableHash = hashString([name UTF8String]);
        gDescriptor.serialNum = stableHash;
        gDescriptor.productID = (stableHash >> 16) & 0xFFFF;
        gDescriptor.vendorID = 0xCC01;

        gDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:gDescriptor];
        if (!gDisplay) {
            cleanupDisplay();
            return false;
        }

        CGFloat refreshRate = (refresh_rate < 1) ? 60.0 : static_cast<CGFloat>(refresh_rate);
        gSettings = [[CGVirtualDisplaySettings alloc] init];
        gSettings.hiDPI = hi_dpi ? 1 : 0;

        CGVirtualDisplayMode* mode =
            [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate];
        if (hi_dpi) {
            NSUInteger lowW = std::max(static_cast<NSUInteger>(width / 2), static_cast<NSUInteger>(1));
            NSUInteger lowH = std::max(static_cast<NSUInteger>(height / 2), static_cast<NSUInteger>(1));
            CGVirtualDisplayMode* lowMode =
                [[CGVirtualDisplayMode alloc] initWithWidth:lowW height:lowH refreshRate:refreshRate];
            gSettings.modes = @[mode, lowMode];
        } else {
            gSettings.modes = @[mode];
        }

        if (![gDisplay applySettings:gSettings]) {
            cleanupDisplay();
            return false;
        }

        if (!configureMirror(mirror_main)) {
            cleanupDisplay();
            return false;
        }

        return true;
    }
}

bool cc_destroy_virtual_display(void) {
    @autoreleasepool {
        bool hadDisplay = gDisplay != nil;
        cleanupDisplay();
        return hadDisplay;
    }
}

bool cc_is_virtual_display_active(void) {
    return gDisplay != nil;
}

uint32_t cc_virtual_display_id(void) {
    if (!gDisplay) return 0;
    return static_cast<uint32_t>(gDisplay.displayID);
}
