import AppKit

let size = NSSize(width: 512, height: 512)
let outputImage = NSImage(size: size)
outputImage.lockFocus()
NSColor.clear.set()
NSRect(origin: .zero, size: size).fill()

if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .regular)
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
outputImage.unlockFocus()

if let tiff = outputImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "ic_launcher_foreground.png"))
    print("Saved ic_launcher_foreground.png")
}