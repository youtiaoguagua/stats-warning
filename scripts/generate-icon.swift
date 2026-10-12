import AppKit
import Foundation

let directory = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        let background = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 452, height: 452), xRadius: 100, yRadius: 100)
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.62, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.91, green: 0.27, blue: 0.12, alpha: 1))!.draw(in: background, angle: -90)
        NSColor.white.setStroke()
        let stem = NSBezierPath(roundedRect: NSRect(x: 215, y: 180, width: 82, height: 217), xRadius: 41, yRadius: 41)
        stem.lineWidth = 20
        stem.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 189, y: 105, width: 134, height: 134)).fill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: 198, width: 24, height: 131), xRadius: 12, yRadius: 12).fill()
        for y in [265, 305, 345] {
            NSBezierPath(roundedRect: NSRect(x: 326, y: CGFloat(y), width: 35, height: 10), xRadius: 5, yRadius: 5).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: directory)
