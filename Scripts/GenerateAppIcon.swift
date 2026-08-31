import AppKit
import Foundation

// macOS AppIcon 资源使用 1x/2x 像素图，并把最终展示所需的圆角写入源图。
let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let generatedSourceImage: NSImage? = CommandLine.arguments.count > 2
    ? NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    : nil

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func lemonPath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: size * 0.79, y: size * 0.53))
    path.curve(
        to: NSPoint(x: size * 0.28, y: size * 0.72),
        controlPoint1: NSPoint(x: size * 0.65, y: size * 0.78),
        controlPoint2: NSPoint(x: size * 0.39, y: size * 0.77)
    )
    path.curve(
        to: NSPoint(x: size * 0.20, y: size * 0.48),
        controlPoint1: NSPoint(x: size * 0.14, y: size * 0.64),
        controlPoint2: NSPoint(x: size * 0.14, y: size * 0.53)
    )
    path.curve(
        to: NSPoint(x: size * 0.79, y: size * 0.53),
        controlPoint1: NSPoint(x: size * 0.34, y: size * 0.25),
        controlPoint2: NSPoint(x: size * 0.66, y: size * 0.29)
    )
    path.close()
    return path
}

func drawLeaf(size: CGFloat) {
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: size * 0.63, y: size * 0.76))
    leaf.curve(
        to: NSPoint(x: size * 0.84, y: size * 0.90),
        controlPoint1: NSPoint(x: size * 0.74, y: size * 0.91),
        controlPoint2: NSPoint(x: size * 0.85, y: size * 0.96)
    )
    leaf.curve(
        to: NSPoint(x: size * 0.72, y: size * 0.70),
        controlPoint1: NSPoint(x: size * 0.86, y: size * 0.83),
        controlPoint2: NSPoint(x: size * 0.75, y: size * 0.73)
    )
    leaf.close()

    color(0.23, 0.57, 0.28).setFill()
    leaf.fill()

    let vein = NSBezierPath()
    vein.move(to: NSPoint(x: size * 0.67, y: size * 0.74))
    vein.curve(
        to: NSPoint(x: size * 0.81, y: size * 0.87),
        controlPoint1: NSPoint(x: size * 0.72, y: size * 0.79),
        controlPoint2: NSPoint(x: size * 0.77, y: size * 0.84)
    )
    vein.lineWidth = max(1, size * 0.014)
    color(0.58, 0.78, 0.34, 0.9).setStroke()
    vein.stroke()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: size * 0.61, y: size * 0.73))
    stem.curve(
        to: NSPoint(x: size * 0.67, y: size * 0.83),
        controlPoint1: NSPoint(x: size * 0.62, y: size * 0.77),
        controlPoint2: NSPoint(x: size * 0.65, y: size * 0.80)
    )
    stem.lineWidth = max(1, size * 0.025)
    color(0.35, 0.23, 0.10).setStroke()
    stem.stroke()
}

func drawLemonDetails(size: CGFloat, path: NSBezierPath) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()

    let highlight = NSBezierPath(
        ovalIn: NSRect(x: size * 0.30, y: size * 0.57, width: size * 0.24, height: size * 0.075)
    )
    color(1.0, 1.0, 0.86, 0.55).setFill()
    highlight.fill()

    let pore = NSBezierPath(
        ovalIn: NSRect(x: size * 0.69, y: size * 0.48, width: size * 0.028, height: size * 0.028)
    )
    color(0.86, 0.50, 0.04, 0.5).setFill()
    pore.fill()

    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // Apple 原生 macOS 图标约占画布 80%，透明外边距交给 Dock 统一排版。
    let iconSide = size * 0.80
    let iconRect = NSRect(
        x: (size - iconSide) / 2,
        y: (size - iconSide) / 2 + size * 0.008,
        width: iconSide,
        height: iconSide
    )
    let iconShape = NSBezierPath(
        roundedRect: iconRect,
        xRadius: iconSide * 0.223,
        yRadius: iconSide * 0.223
    )

    if let generatedSourceImage {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = max(1, size * 0.025)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        NSColor.white.setFill()
        iconShape.fill()
        NSShadow().set()

        NSGraphicsContext.saveGraphicsState()
        iconShape.addClip()
        generatedSourceImage.draw(
            in: iconRect,
            from: NSRect(origin: .zero, size: generatedSourceImage.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        return image
    }

    NSGraphicsContext.saveGraphicsState()
    iconShape.addClip()

    let background = NSGradient(colors: [
        color(0.15, 0.43, 0.78),
        color(0.08, 0.28, 0.61),
        color(0.035, 0.12, 0.32)
    ], atLocations: [0, 0.56, 1], colorSpace: .sRGB)!
    background.draw(in: rect, angle: -32)

    let glow = NSBezierPath(
        ovalIn: NSRect(x: -size * 0.18, y: size * 0.62, width: size * 0.72, height: size * 0.72)
    )
    color(0.39, 0.69, 1.0, 0.18).setFill()
    glow.fill()

    NSGraphicsContext.restoreGraphicsState()

    drawLeaf(size: size)

    let lemon = lemonPath(size: size)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = max(2, size * 0.035)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.025)
    shadow.set()
    NSGradient(colors: [
        color(1.0, 0.91, 0.20),
        color(1.0, 0.70, 0.06),
        color(0.92, 0.46, 0.015)
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: lemon, angle: -62)
    NSShadow().set()

    drawLemonDetails(size: size, path: lemon)

    image.unlockFocus()
    return image
}

func pngData(from image: NSImage) -> Data {
    let size = image.size
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("bitmap")
    }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in sizes {
    let data = pngData(from: drawIcon(size: size))
    let url = output.appendingPathComponent("icon_\(Int(size)).png")
    try data.write(to: url)
    fputs("wrote \(url.path)\n", stderr)
}
