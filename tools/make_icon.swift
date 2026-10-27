#!/usr/bin/env swift
// Draws Irctell's app icon and writes every size the asset catalog needs:
//   swift tools/make_icon.swift Irctell/Assets.xcassets/AppIcon.appiconset
// A speech bubble with IRC's # for chat, a second one behind it for the
// conversation, and sound waves for reading messages aloud, on a blue
// rounded square drawn to Apple's macOS icon grid.

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A speech bubble: a rounded rectangle with a tail at the lower left, or
/// none. The tail starts well inside the rectangle, so the two are one shape.
func bubble(_ rect: CGRect, radius: CGFloat, tail: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    guard tail > 0 else { return path }
    let start = rect.minX + radius * 0.75
    path.move(to: CGPoint(x: start, y: rect.minY + radius * 0.6))
    path.addLine(to: CGPoint(x: start, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.minX + radius * 0.15, y: rect.minY - tail),
                      control: CGPoint(x: start, y: rect.minY - tail * 0.6))
    path.addQuadCurve(to: CGPoint(x: start + tail * 1.1, y: rect.minY),
                      control: CGPoint(x: start + tail * 0.35, y: rect.minY - tail * 0.45))
    path.addLine(to: CGPoint(x: start + tail * 1.1, y: rect.minY + radius * 0.6))
    path.closeSubpath()
    return path
}

func drawIcon(in context: CGContext) {
    // Apple's grid: an 824-point square in the 1024 canvas, room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1E3A8A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [color(0x38BDF8), color(0x2563EB), color(0x312E81)] as CFArray,
                                locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 220, y: 924), end: CGPoint(x: 800, y: 100), options: [])
    // A soft light from the top, as on glass.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(sheen, startCenter: CGPoint(x: 400, y: 900), startRadius: 0,
                               endCenter: CGPoint(x: 400, y: 900), endRadius: 560, options: [])

    // The other side of the conversation, behind.
    let back = bubble(CGRect(x: 470, y: 610, width: 330, height: 215), radius: 85, tail: 0)
    context.addPath(back)
    context.setFillColor(color(0xFFFFFF, 0.38))
    context.fillPath()

    // The main bubble, with a shadow of its own.
    let front = bubble(CGRect(x: 180, y: 330, width: 450, height: 320), radius: 110, tail: 95)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0B1B4D, 0.45))
    context.addPath(front)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // IRC's channel sign, in the background's blue.
    context.saveGState()
    let hash = CGMutablePath()
    let center = CGPoint(x: 405, y: 490)
    let length: CGFloat = 190, gap: CGFloat = 70, slant: CGFloat = 22
    for offset in [-gap / 2, gap / 2] {
        hash.move(to: CGPoint(x: center.x + offset - slant, y: center.y - length / 2))
        hash.addLine(to: CGPoint(x: center.x + offset + slant, y: center.y + length / 2))
        hash.move(to: CGPoint(x: center.x - length / 2, y: center.y + offset))
        hash.addLine(to: CGPoint(x: center.x + length / 2, y: center.y + offset))
    }
    context.addPath(hash)
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let ink = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [color(0x0EA5E9), color(0x3730A3)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(ink, start: CGPoint(x: center.x, y: center.y + 100),
                               end: CGPoint(x: center.x, y: center.y - 100), options: [])
    context.restoreGState()

    // Sound waves: the messages read aloud.
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineCap(.round)
    let waveCenter = CGPoint(x: 640, y: 420)
    for (index, radius) in [CGFloat(80), 145, 210].enumerated() {
        context.setLineWidth(32)
        context.setAlpha(1 - CGFloat(index) * 0.22)
        context.addArc(center: waveCenter, radius: radius, startAngle: -.pi / 4.5, endAngle: .pi / 4.5, clockwise: false)
        context.strokePath()
    }
    context.setAlpha(1)
    context.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: points * scale).write(to: folder.appending(path: name))
        images.append(#"    {"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : {\"author\":\"xcode\",\"version\":1}\n}\n"
try! contents.write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) images to \(folder.path)")
