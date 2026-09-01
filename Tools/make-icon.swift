import AppKit

/// Рисует иконку приложения во всех нужных размерах.
/// Координаты заданы в холсте 1024 и масштабируются множителем.

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size) / 1024.0
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Плитка со скруглением, как у системных иконок.
    let tile = CGRect(x: 62 * s, y: 62 * s, width: 900 * s, height: 900 * s)
    ctx.saveGState()
    ctx.addPath(rounded(tile, 200 * s))
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.60, green: 0.30, blue: 0.92, alpha: 1),
        CGColor(srgbRed: 0.88, green: 0.24, blue: 0.55, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Столбики уровня — самый узнаваемый знак звучащей музыки, и он
    // не расплывается в мелких размерах, в отличие от нотного знака.
    let heights: [CGFloat] = [250, 430, 330, 520, 300]
    let barWidth: CGFloat = 78
    let gap: CGFloat = 40
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 * s - total * s / 2
    let baseline = 330 * s

    for height in heights {
        let bar = CGRect(x: x, y: baseline, width: barWidth * s, height: height * s)
        ctx.addPath(rounded(bar, barWidth * s / 2))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillPath()
        x += (barWidth + gap) * s
    }

    return ctx.makeImage()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    guard let image = drawIcon(size: size) else { continue }
    let url = URL(fileURLWithPath: "\(out)/\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("нарисовано размеров: \(sizes.count)")
