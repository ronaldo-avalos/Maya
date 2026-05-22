#!/usr/bin/env swift
//
// make-background.swift — generate the Maya .dmg window background.
// -----------------------------------------------------------------
// Renders background.png (@1x) and background@2x.png into this script's
// own directory. build-release.sh feeds them to create-dmg; create-dmg
// auto-detects the @2x file and builds a Retina-aware background.
//
// Regenerate after a design tweak:
//     swift scripts/dmg-assets/make-background.swift
//
import AppKit

// Window geometry — must match the --window-size / --icon flags in
// build-release.sh. Icons sit at Finder y = 195 (top-left origin).
let W: CGFloat = 660
let H: CGFloat = 400
let iconCenterY: CGFloat = 195          // Finder coords, from the top

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)   // draw in points

    // 1 — soft vertical gradient: white at the top, faint indigo below.
    let top    = NSColor.white
    let bottom = NSColor(calibratedRed: 0.914, green: 0.914, blue: 0.984, alpha: 1)
    NSGradient(starting: bottom, ending: top)!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    // 2 — instruction line near the top.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.518, green: 0.518,
                                  blue: 0.604, alpha: 1),
        .paragraphStyle: para,
    ]
    "Drag Maya into the Applications folder"
        .draw(in: NSRect(x: 0, y: H - 66, width: W, height: 22),
              withAttributes: attrs)

    // 3 — indigo arrow pointing from the app toward Applications.
    let arrowY = H - iconCenterY                 // flip to bottom-left origin
    let shaftStartX: CGFloat = 286
    let tipX: CGFloat = 374
    let headLen: CGFloat = 19
    let headHalf: CGFloat = 11
    NSColor(calibratedRed: 0.392, green: 0.400, blue: 0.980, alpha: 0.65).set()

    let shaft = NSBezierPath()
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: shaftStartX, y: arrowY))
    shaft.line(to: NSPoint(x: tipX - headLen + 4, y: arrowY))
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: tipX, y: arrowY))
    head.line(to: NSPoint(x: tipX - headLen, y: arrowY + headHalf))
    head.line(to: NSPoint(x: tipX - headLen, y: arrowY - headHalf))
    head.close()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
save(render(scale: 1), to: "\(outDir)/background.png")
save(render(scale: 2), to: "\(outDir)/background@2x.png")
