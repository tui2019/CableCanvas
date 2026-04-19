import AppKit
import Foundation

func saveIcon(pixelSize: Int, fileName: String) {
    let size = NSSize(width: pixelSize, height: pixelSize)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return
    }
    bitmap.size = size

    NSGraphicsContext.saveGraphicsState()
    if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()

        if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil) {
            // Keep symbol inside adaptive icon safe area with room for launcher motion effects.
            let targetSymbolSize = (150.0 / 432.0) * CGFloat(pixelSize)
            let config = NSImage.SymbolConfiguration(pointSize: targetSymbolSize, weight: .regular)
            if let scaledImage = image.withSymbolConfiguration(config) {
                let tintedImage = NSImage(size: scaledImage.size)
                tintedImage.lockFocus()
                scaledImage.draw(in: NSRect(origin: .zero, size: scaledImage.size))
                NSColor.white.set()
                NSRect(origin: .zero, size: scaledImage.size).fill(using: .sourceAtop)
                tintedImage.unlockFocus()

                let symbolSize = tintedImage.size
                let rect = NSRect(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                tintedImage.draw(in: rect)
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    if let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: fileName))
    }
}

// Generate all standard Android density buckets (108dp base)
saveIcon(pixelSize: 108, fileName: "ic_launcher_foreground_mdpi.png")    // 1x
saveIcon(pixelSize: 162, fileName: "ic_launcher_foreground_hdpi.png")    // 1.5x
saveIcon(pixelSize: 216, fileName: "ic_launcher_foreground_xhdpi.png")   // 2x
saveIcon(pixelSize: 324, fileName: "ic_launcher_foreground_xxhdpi.png")  // 3x
saveIcon(pixelSize: 432, fileName: "ic_launcher_foreground_xxxhdpi.png") // 4x

print("Generated icons for all densities.")
