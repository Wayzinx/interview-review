// 生成 App 图标：蓝紫渐变圆角方块 + 白色"波形+话筒"符号。用法: make_icon <输出 .iconset 目录>
import AppKit

let out = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.50, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.47, green: 0.27, blue: 0.96, alpha: 1),
    ])!.draw(in: path, angle: -55)
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (n, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(n).png"))
}
