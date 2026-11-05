// Renders the 🧹 app icon: swift assets/make-icon.swift && iconutil -c icns assets/AppIcon.iconset
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.17, green: 0.18, blue: 0.24, alpha: 1),
                        NSColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1)])!.draw(in: path, angle: -90)
    let str = NSAttributedString(string: "🧹", attributes: [.font: NSFont.systemFont(ofSize: s * 0.56)])
    let sz = str.size()
    str.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2))
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = "assets/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
