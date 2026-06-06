// Renders the Plume app icon — a white feather ("plume") on a blue→indigo
// gradient squircle — into a macOS .iconset folder.
//
//   swift Scripts/icon_gen.swift <output.iconset>
//
// Each call recompiles in a second or two; the icon is regenerated rarely
// (via Scripts/make_icon.sh), not on every build, so the cost is fine.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Plume.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx
    let cg = nsctx.cgContext

    // Work in a top-left origin so the layout reads top-to-bottom.
    cg.translateBy(x: 0, y: s)
    cg.scaleBy(x: 1, y: -1)

    // Background: gradient-filled continuous-corner squircle.
    let r = 0.2237 * s
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: r, cornerHeight: r, transform: nil)
    cg.saveGState()
    cg.addPath(bg); cg.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.00, green: 0.70, blue: 1.00, alpha: 1),  // #00B2FF
        CGColor(red: 0.43, green: 0.36, blue: 1.00, alpha: 1),  // #6E5BFF
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                          end: CGPoint(x: s, y: s), options: [])
    cg.restoreGState()

    // Feather, tilted for a bit of motion.
    cg.saveGState()
    cg.translateBy(x: s / 2, y: s / 2)
    cg.rotate(by: -18 * .pi / 180)
    cg.translateBy(x: -s / 2, y: -s / 2)

    let cx = 0.5 * s
    let yTop = 0.17 * s
    let yBase = 0.72 * s          // where the vane ends and the quill begins
    let yQuill = 0.85 * s
    let hw = 0.165 * s            // vane half-width at its widest

    // Vane: a pointed leaf (two mirrored cubic curves).
    let vane = CGMutablePath()
    vane.move(to: CGPoint(x: cx, y: yTop))
    vane.addCurve(to: CGPoint(x: cx, y: yBase),
                  control1: CGPoint(x: cx - hw, y: 0.31 * s),
                  control2: CGPoint(x: cx - hw, y: 0.61 * s))
    vane.addCurve(to: CGPoint(x: cx, y: yTop),
                  control1: CGPoint(x: cx + hw, y: 0.61 * s),
                  control2: CGPoint(x: cx + hw, y: 0.31 * s))
    vane.closeSubpath()
    cg.addPath(vane)
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cg.fillPath()

    // White quill extending below the vane.
    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cg.setLineWidth(max(1, 0.022 * s))
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: cx, y: yBase - 0.02 * s))
    cg.addLine(to: CGPoint(x: cx, y: yQuill))
    cg.strokePath()

    // Rachis (central spine) in indigo, splitting the white vane.
    let spine = CGColor(red: 0.30, green: 0.32, blue: 0.85, alpha: 1)
    cg.setStrokeColor(spine)
    cg.setLineWidth(max(1, 0.018 * s))
    cg.move(to: CGPoint(x: cx, y: yTop + 0.02 * s))
    cg.addLine(to: CGPoint(x: cx, y: yBase))
    cg.strokePath()

    // Barbs: thin indigo cuts angled up from the spine, tapering at the tips.
    cg.setLineWidth(max(0.6, 0.013 * s))
    for f: CGFloat in [0.33, 0.43, 0.53, 0.63] {
        let y = f * s
        let t = (y - yTop) / (yBase - yTop)
        let w = hw * sin(.pi * t) * 0.92      // 0 at tips, widest at the middle
        cg.move(to: CGPoint(x: cx, y: y))
        cg.addLine(to: CGPoint(x: cx - w, y: y - 0.05 * s))
        cg.move(to: CGPoint(x: cx, y: y + 0.02 * s))
        cg.addLine(to: CGPoint(x: cx + w, y: y - 0.03 * s))
        cg.strokePath()
    }

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in sizes {
    let data = render(size).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("wrote \(sizes.count) PNGs to \(outDir)")
