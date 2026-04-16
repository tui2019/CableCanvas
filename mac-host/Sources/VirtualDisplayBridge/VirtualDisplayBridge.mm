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
    uint32_t ppi,
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
        gDescriptor.maxPixelsWide = hi_dpi ? (width * 2) : width;
        gDescriptor.maxPixelsHigh = hi_dpi ? (height * 2) : height;

        double ppiValue = (ppi < 160) ? 220.0 : static_cast<double>(ppi);
        double ratio = 25.4 / ppiValue;
        
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

        NSMutableArray<CGVirtualDisplayMode*>* modes = [[NSMutableArray alloc] init];
        
        if (hi_dpi) {
            // Provide modes so macOS can use them for different Retina scaling options.
            // ScreenCaptureKit will downscale/upscale these back to the native tablet resolution.
            
            // "Default" Retina (2.0x logical UI scale)
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate]];
            
            // 2.2x logical UI scale
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.9) height:(uint32_t)(height * 0.9) refreshRate:refreshRate]];
            
            // 2.5x logical UI scale
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.8) height:(uint32_t)(height * 0.8) refreshRate:refreshRate]];
            
            // 2.85x logical UI scale
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.7) height:(uint32_t)(height * 0.7) refreshRate:refreshRate]];
            
            // 3.0x logical UI scale (e.g. 1333p for 2000p display)
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.6666) height:(uint32_t)(height * 0.6666) refreshRate:refreshRate]];

            // 3.33x logical UI scale
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.6) height:(uint32_t)(height * 0.6) refreshRate:refreshRate]];
            
            // 4.0x logical UI scale
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(uint32_t)(width * 0.5) height:(uint32_t)(height * 0.5) refreshRate:refreshRate]];
        } else {
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate]];
        }
        
        gSettings.modes = modes;

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
