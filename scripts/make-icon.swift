import AppKit
import CoreGraphics
import Foundation

// Render in a fixed 1024-point coordinate system so each iconset slot has
// exactly the required pixel dimensions, regardless of the display scale.
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func drawIcon(pixels: Int) -> Data {
    let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                           bytesPerRow: pixels * 4, space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    canvas.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 76, y: 88, width: 872, height: 872),
                      cornerWidth: 206, cornerHeight: 206, transform: nil)

    canvas.saveGState()
    canvas.setShadow(offset: CGSize(width: 0, height: -16), blur: 25, color: color(0x160F30, alpha: 0.38))
    canvas.setFillColor(color(0x171126))
    canvas.addPath(tile)
    canvas.fillPath()
    canvas.restoreGState()

    canvas.saveGState()
    canvas.addPath(tile)
    canvas.clip()
    canvas.drawLinearGradient(gradient([color(0x54408A), color(0x291D48), color(0x161123)], [0, 0.46, 1]),
                              start: CGPoint(x: 130, y: 952), end: CGPoint(x: 856, y: 97),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    canvas.drawRadialGradient(gradient([color(0xB896FF, alpha: 0.36), color(0xB896FF, alpha: 0)], [0, 1]),
                              startCenter: CGPoint(x: 256, y: 884), startRadius: 0,
                              endCenter: CGPoint(x: 256, y: 884), endRadius: 560, options: [])
    canvas.drawRadialGradient(gradient([color(0x50BBCC, alpha: 0.16), color(0x50BBCC, alpha: 0)], [0, 1]),
                              startCenter: CGPoint(x: 878, y: 258), startRadius: 0,
                              endCenter: CGPoint(x: 878, y: 258), endRadius: 490, options: [])
    canvas.addPath(tile)
    canvas.setStrokeColor(color(0xF1E7FF, alpha: 0.24))
    canvas.setLineWidth(7)
    canvas.strokePath()
    canvas.restoreGState()

    // A single line starts and ends at rest, like a brief spoken phrase.
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 233, y: 515))
    wave.addCurve(to: CGPoint(x: 354, y: 665), control1: CGPoint(x: 309, y: 515), control2: CGPoint(x: 316, y: 665))
    wave.addCurve(to: CGPoint(x: 478, y: 350), control1: CGPoint(x: 407, y: 665), control2: CGPoint(x: 425, y: 350))
    wave.addCurve(to: CGPoint(x: 603, y: 704), control1: CGPoint(x: 530, y: 350), control2: CGPoint(x: 552, y: 704))
    wave.addCurve(to: CGPoint(x: 720, y: 515), control1: CGPoint(x: 652, y: 704), control2: CGPoint(x: 655, y: 515))
    wave.addQuadCurve(to: CGPoint(x: 791, y: 515), control: CGPoint(x: 755, y: 515))
    let ribbon = wave.copy(strokingWithWidth: 72, lineCap: .round, lineJoin: .round, miterLimit: 1)

    canvas.saveGState()
    canvas.setShadow(offset: CGSize(width: 0, height: -9), blur: 27, color: color(0xB591FF, alpha: 0.42))
    canvas.setFillColor(color(0xE5D7FF))
    canvas.addPath(ribbon)
    canvas.fillPath()
    canvas.restoreGState()

    canvas.saveGState()
    canvas.addPath(ribbon)
    canvas.clip()
    canvas.drawLinearGradient(gradient([color(0xD0B1FF), color(0xFCF4FF), color(0xBCF3EF)], [0, 0.56, 1]),
                              start: CGPoint(x: 220, y: 380), end: CGPoint(x: 808, y: 640),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    canvas.restoreGState()
    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try drawIcon(pixels: size * scale).write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
