import AppKit

enum TrayGlyph {
    static func image(recording: Bool, dark: Bool) -> NSImage {
        raster(template: !recording) { rect in
            drawOat(in: rect, color: recording ? (dark ? .white : .black) : .black)
            if recording {
                drawRecordingDot(in: rect, dark: dark)
            }
        }
    }

    private static func drawOat(in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 80, y: rect.height / 80)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 28, y: 5, width: 24, height: 45), xRadius: 12, yRadius: 12).fill()

        let husk = NSBezierPath()
        husk.move(to: NSPoint(x: 5, y: 40))
        husk.curve(
            to: NSPoint(x: 15.251, y: 64.749),
            controlPoint1: NSPoint(x: 5, y: 49.283),
            controlPoint2: NSPoint(x: 8.687, y: 58.185)
        )
        husk.curve(
            to: NSPoint(x: 40, y: 75),
            controlPoint1: NSPoint(x: 21.815, y: 71.313),
            controlPoint2: NSPoint(x: 30.717, y: 75)
        )
        husk.curve(
            to: NSPoint(x: 5, y: 40),
            controlPoint1: NSPoint(x: 40, y: 55.556),
            controlPoint2: NSPoint(x: 24.328, y: 40)
        )
        husk.close()
        husk.move(to: NSPoint(x: 40, y: 75))
        husk.curve(
            to: NSPoint(x: 64.749, y: 64.749),
            controlPoint1: NSPoint(x: 49.283, y: 75),
            controlPoint2: NSPoint(x: 58.185, y: 71.313)
        )
        husk.curve(
            to: NSPoint(x: 75, y: 40),
            controlPoint1: NSPoint(x: 71.313, y: 58.185),
            controlPoint2: NSPoint(x: 75, y: 49.283)
        )
        husk.curve(
            to: NSPoint(x: 40, y: 75),
            controlPoint1: NSPoint(x: 55.556, y: 40),
            controlPoint2: NSPoint(x: 40, y: 55.556)
        )
        husk.close()
        husk.fill()
        context.restoreGState()
    }

    private static func drawRecordingDot(in rect: NSRect, dark: Bool) {
        let size: CGFloat = 6.5
        let dot = NSRect(x: rect.maxX - size, y: rect.minY, width: size, height: size)
        (dark ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private static func raster(template: Bool, draw: @escaping (NSRect) -> Void) -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize)
        for scale in [1, 2, 3] {
            let pixels = 18 * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                context.imageInterpolation = .high
                context.shouldAntialias = true
                NSGraphicsContext.current = context
                let cg = context.cgContext
                cg.translateBy(x: 0, y: pointSize.height)
                cg.scaleBy(x: 1, y: -1)
                draw(NSRect(origin: .zero, size: pointSize))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = template
        return image
    }
}
