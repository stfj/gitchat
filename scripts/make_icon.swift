// Generates the gitchat app icon: a white chat bubble holding a git-branch
// glyph on a green gradient. Run from the repo root:
//   swift scripts/make_icon.swift gitchat/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "gitchat/Assets.xcassets/AppIcon.appiconset"

func drawIcon(into ctx: CGContext, canvas: CGFloat) {
    let s = canvas / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // Rounded-square plate (Apple grid: ~824pt art on a 1024 canvas).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(platePath)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.42, green: 0.89, blue: 0.49, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.03, green: 0.66, blue: 0.32, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])

    // Speech bubble.
    ctx.setFillColor(NSColor.white.cgColor)
    let bubble = CGRect(x: 512 - 235, y: 442, width: 470, height: 310)
    ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 105, cornerHeight: 105, transform: nil))
    ctx.fillPath()

    // Tail, drooping toward bottom-left.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 352, y: 500))
    ctx.addCurve(to: CGPoint(x: 292, y: 342),
                 control1: CGPoint(x: 348, y: 430),
                 control2: CGPoint(x: 322, y: 372))
    ctx.addCurve(to: CGPoint(x: 470, y: 452),
                 control1: CGPoint(x: 372, y: 356),
                 control2: CGPoint(x: 432, y: 402))
    ctx.closePath()
    ctx.fillPath()

    // Git-branch glyph inside the bubble.
    let green = NSColor(calibratedRed: 0.03, green: 0.58, blue: 0.28, alpha: 1).cgColor
    ctx.setStrokeColor(green)
    ctx.setFillColor(green)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)

    let a = CGPoint(x: 435, y: 520)   // bottom node (main)
    let b = CGPoint(x: 435, y: 672)   // top node (main)
    let c = CGPoint(x: 600, y: 640)   // branch node

    ctx.beginPath()
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()

    ctx.beginPath()
    ctx.move(to: CGPoint(x: 435, y: 552))
    ctx.addCurve(to: c,
                 control1: CGPoint(x: 440, y: 610),
                 control2: CGPoint(x: 520, y: 640))
    ctx.strokePath()

    for p in [a, b, c] {
        ctx.fillEllipse(in: CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68))
    }
    // Punch a white core so nodes read as commit dots.
    ctx.setFillColor(NSColor.white.cgColor)
    for p in [a, b, c] {
        ctx.fillEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
    }

    ctx.restoreGState()
}

func writePNG(px: Int, name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("bitmap context failed for \(px)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    drawIcon(into: gctx.cgContext, canvas: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed for \(px)px")
    }
    try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

let sizes: [(Int, String)] = [
    (16, "icon_16.png"), (32, "icon_16@2x.png"),
    (32, "icon_32.png"), (64, "icon_32@2x.png"),
    (128, "icon_128.png"), (256, "icon_128@2x.png"),
    (256, "icon_256.png"), (512, "icon_256@2x.png"),
    (512, "icon_512.png"), (1024, "icon_512@2x.png"),
]
for (px, name) in sizes { writePNG(px: px, name: name) }

let contents = """
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: outDir + "/Contents.json", atomically: true, encoding: .utf8)
print("wrote 10 icon sizes + Contents.json to \(outDir)")
