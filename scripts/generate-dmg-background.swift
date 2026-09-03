#!/usr/bin/env swift
import AppKit
import Foundation

// Renders assets/dmg/background.{png,tiff} to match the Paper
// "DMG Background" artboard: wheat field, plant-the-oat copy,
// dashed path top-left → bottom-right plant spot.

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : FileManager.default.currentDirectoryPath + "/assets/dmg")

let repoRoot = URL(fileURLWithPath: CommandLine.arguments.count > 2
  ? CommandLine.arguments[2]
  : FileManager.default.currentDirectoryPath)

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let logicalWidth = 800
let logicalHeight = 500

// Icon centers (Finder positions in pack-dmg.sh) — y from top
let appsCenter = CGPoint(x: 640, y: 360)

func cocoaY(_ topY: CGFloat) -> CGFloat { CGFloat(logicalHeight) - topY }

func loadWallpaper() -> NSImage? {
  let url = repoRoot.appendingPathComponent("website/assets/wallpaper.jpg")
  guard FileManager.default.fileExists(atPath: url.path) else { return nil }
  return NSImage(contentsOf: url)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
  let pxW = Int((CGFloat(logicalWidth) * scale).rounded())
  let pxH = Int((CGFloat(logicalHeight) * scale).rounded())
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pxW,
    pixelsHigh: pxH,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    fatalError("Could not allocate bitmap")
  }
  rep.size = NSSize(width: logicalWidth, height: logicalHeight)

  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  let bounds = NSRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
  let cream = NSColor(calibratedRed: 0.969, green: 0.945, blue: 0.894, alpha: 1)

  if let wallpaper = loadWallpaper() {
    let imgSize = wallpaper.size
    let scaleFactor = max(bounds.width / imgSize.width, bounds.height / imgSize.height)
    let drawSize = NSSize(width: imgSize.width * scaleFactor, height: imgSize.height * scaleFactor)
    let drawOrigin = NSPoint(
      x: (bounds.width - drawSize.width) / 2,
      y: (bounds.height - drawSize.height) / 2
    )
    wallpaper.draw(
      in: NSRect(origin: drawOrigin, size: drawSize),
      from: .zero,
      operation: .copy,
      fraction: 1
    )
  } else {
    NSColor(calibratedRed: 0.75, green: 0.68, blue: 0.42, alpha: 1).setFill()
    bounds.fill()
  }

  if let ctx = NSGraphicsContext.current?.cgContext {
    let colors = [
      NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.125, alpha: 0.18).cgColor,
      NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.125, alpha: 0).cgColor,
    ] as CFArray
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors,
      locations: [0, 1]
    )!
    ctx.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: CGFloat(logicalHeight)),
      end: CGPoint(x: 0, y: CGFloat(logicalHeight) - 220),
      options: []
    )
  }

  let title = "plant the oat to install" as NSString
  let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Avenir Next Demi Bold", size: 26)
      ?? NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: cream,
    .kern: 0.4,
  ]
  let titleSize = title.size(withAttributes: titleAttrs)
  title.draw(
    at: NSPoint(x: bounds.width - 40 - titleSize.width, y: cocoaY(36) - titleSize.height),
    withAttributes: titleAttrs
  )

  let sub = "Drag into Applications" as NSString
  let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Avenir Next Medium", size: 13)
      ?? NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: cream.withAlphaComponent(0.72),
  ]
  let subSize = sub.size(withAttributes: subAttrs)
  sub.draw(
    at: NSPoint(x: bounds.width - 40 - subSize.width, y: cocoaY(68) - subSize.height),
    withAttributes: subAttrs
  )

  let pathColor = cream.withAlphaComponent(0.75)
  pathColor.setStroke()

  let start = CGPoint(x: 210, y: cocoaY(185))
  let end = CGPoint(x: 560, y: cocoaY(340))
  let c1 = CGPoint(x: 340, y: cocoaY(240))
  let c2 = CGPoint(x: 460, y: cocoaY(300))

  let curve = NSBezierPath()
  curve.lineWidth = 2.5
  curve.lineCapStyle = .round
  let pattern: [CGFloat] = [8, 8]
  curve.setLineDash(pattern, count: 2, phase: 0)
  curve.move(to: start)
  curve.curve(to: end, controlPoint1: c1, controlPoint2: c2)
  curve.stroke()

  let angle = atan2(end.y - c2.y, end.x - c2.x)
  let head = NSBezierPath()
  head.move(to: end)
  head.line(to: CGPoint(
    x: end.x - 14 * cos(angle) + 8 * sin(angle),
    y: end.y - 14 * sin(angle) - 8 * cos(angle)
  ))
  head.line(to: CGPoint(
    x: end.x - 14 * cos(angle) - 8 * sin(angle),
    y: end.y - 14 * sin(angle) + 8 * cos(angle)
  ))
  head.close()
  cream.withAlphaComponent(0.85).setFill()
  head.fill()

  let spotCenter = CGPoint(x: appsCenter.x, y: cocoaY(appsCenter.y))
  let spot = NSBezierPath(
    ovalIn: NSRect(x: spotCenter.x - 72, y: spotCenter.y - 72, width: 144, height: 144)
  )
  NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.055, alpha: 0.22).setFill()
  spot.fill()
  cream.withAlphaComponent(0.7).setStroke()
  spot.lineWidth = 2
  let dash: [CGFloat] = [7, 6]
  spot.setLineDash(dash, count: 2, phase: 0)
  spot.stroke()

  return rep
}

let rep1x = render(scale: 1)
let rep2x = render(scale: 2)

guard let png1 = rep1x.representation(using: .png, properties: [:]),
      let png2 = rep2x.representation(using: .png, properties: [:]) else {
  fatalError("PNG encode failed")
}
try png1.write(to: outDir.appendingPathComponent("background.png"))
try png2.write(to: outDir.appendingPathComponent("background@2x.png"))

let tiff = NSMutableData()
guard let dest = CGImageDestinationCreateWithData(
  tiff as CFMutableData,
  "public.tiff" as CFString,
  2,
  nil
) else {
  fatalError("Could not create TIFF destination")
}
let opts1: [CFString: Any] = [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72]
let opts2: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
CGImageDestinationAddImage(dest, rep1x.cgImage!, opts1 as CFDictionary)
CGImageDestinationAddImage(dest, rep2x.cgImage!, opts2 as CFDictionary)
CGImageDestinationFinalize(dest)
try (tiff as Data).write(to: outDir.appendingPathComponent("background.tiff"))

print("Wrote DMG backgrounds to \(outDir.path)")
print("  \(rep1x.pixelsWide)x\(rep1x.pixelsHigh) / \(rep2x.pixelsWide)x\(rep2x.pixelsHigh)")
if loadWallpaper() == nil {
  print("WARNING: website/assets/wallpaper.jpg not found")
}
