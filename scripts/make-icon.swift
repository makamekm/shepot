import AppKit
import Foundation

let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let bounds = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: p * 0.21, yRadius: p * 0.21).fill()
        let heights: [CGFloat] = [0.20, 0.37, 0.55, 0.37, 0.20]
        for i in 0..<5 {
            let height = p * heights[i]
            let rect = NSRect(x: p * (0.267 + CGFloat(i) * 0.10), y: (p - height) / 2, width: p * 0.065, height: height)
            NSColor(red: 0.88, green: 0.84, blue: 0.99, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: p * 0.033, yRadius: p * 0.033).fill()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
