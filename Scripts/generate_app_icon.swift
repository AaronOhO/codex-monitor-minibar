import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output.icns>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconChunks: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

var chunks = Data()
for iconChunk in iconChunks {
    let image = renderIcon(size: iconChunk.pixels)
    let pngData = try pngData(from: image)
    appendChunk(type: iconChunk.type, payload: pngData, to: &chunks)
}

var icns = Data()
appendFourCC("icns", to: &icns)
appendUInt32(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)
try icns.write(to: outputURL, options: .atomic)

private func renderIcon(size: Int) -> NSBitmapImageRep {
    let side = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("unable to create icon bitmap")
    }
    bitmap.size = rect.size

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context

    NSColor.clear.setFill()
    rect.fill()

    let backgroundRect = rect.insetBy(dx: side * 0.045, dy: side * 0.045)
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: side * 0.215,
        yRadius: side * 0.215
    )
    drawShadow(offsetY: -side * 0.025, blur: side * 0.035, alpha: 0.28) {
        let gradient = NSGradient(
            starting: NSColor.white,
            ending: NSColor(calibratedWhite: 0.94, alpha: 1)
        )
        gradient?.draw(in: background, angle: -90)
        NSColor(calibratedWhite: 0.78, alpha: 0.45).setStroke()
        background.lineWidth = max(1, side * 0.006)
        background.stroke()
    }

    drawCapsuleBase(in: backgroundRect, side: side)
    drawQuotaCapsule(in: backgroundRect, side: side)
    drawCodexIcon(in: backgroundRect, side: side)
    drawStatusDots(in: backgroundRect, side: side)

    context?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func drawCapsuleBase(in rect: NSRect, side: CGFloat) {
    let baseRect = NSRect(
        x: rect.minX + side * 0.115,
        y: rect.minY + side * 0.275,
        width: rect.width - side * 0.23,
        height: side * 0.43
    )
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: baseRect.height / 2, yRadius: baseRect.height / 2)
    NSColor(calibratedRed: 0.02, green: 0.24, blue: 0.36, alpha: 0.62).setFill()
    basePath.fill()

    let highlightRect = baseRect.insetBy(dx: side * 0.035, dy: side * 0.055)
    let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: highlightRect.height / 2, yRadius: highlightRect.height / 2)
    NSColor.white.withAlphaComponent(0.10).setFill()
    highlightPath.fill()
}

private func drawQuotaCapsule(in rect: NSRect, side: CGFloat) {
    let capsuleRect = NSRect(
        x: rect.minX + side * 0.155,
        y: rect.minY + side * 0.315,
        width: rect.width - side * 0.31,
        height: side * 0.35
    )
    let path = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleRect.height / 2, yRadius: capsuleRect.height / 2)
    path.lineWidth = max(1, side * 0.045)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    NSColor.white.withAlphaComponent(0.28).setStroke()
    path.stroke()

    let perimeter = 2 * (capsuleRect.width - capsuleRect.height) + CGFloat.pi * capsuleRect.height
    path.setLineDash([perimeter * 0.68, perimeter], count: 2, phase: -perimeter * 0.18)
    NSColor(calibratedRed: 0.16, green: 0.92, blue: 0.55, alpha: 1).setStroke()
    path.stroke()
}

private func drawCodexIcon(in rect: NSRect, side: CGFloat) {
    let iconSize = side * 0.31
    let iconRect = NSRect(
        x: rect.midX - iconSize / 2,
        y: rect.midY - iconSize / 2 + side * 0.015,
        width: iconSize,
        height: iconSize
    )

    drawShadow(offsetY: -side * 0.008, blur: side * 0.018, alpha: 0.18) {
        let cloudPath = codexCloudPath(in: iconRect)
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.73, green: 0.61, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.98, alpha: 1)
            ]
        )
        gradient?.draw(in: cloudPath, angle: 110)
        NSColor(calibratedRed: 0.50, green: 0.63, blue: 1.0, alpha: 0.75).setStroke()
        cloudPath.lineWidth = max(1, side * 0.007)
        cloudPath.stroke()
        drawTerminalMark(in: iconRect, side: side)
    }
}

private func codexCloudPath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let x = rect.minX
    let y = rect.minY
    let w = rect.width
    let h = rect.height

    path.move(to: NSPoint(x: x + w * 0.14, y: y + h * 0.43))
    path.curve(
        to: NSPoint(x: x + w * 0.30, y: y + h * 0.77),
        controlPoint1: NSPoint(x: x + w * 0.03, y: y + h * 0.55),
        controlPoint2: NSPoint(x: x + w * 0.10, y: y + h * 0.74)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.58, y: y + h * 0.76),
        controlPoint1: NSPoint(x: x + w * 0.35, y: y + h * 1.00),
        controlPoint2: NSPoint(x: x + w * 0.55, y: y + h * 0.94)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.82, y: y + h * 0.55),
        controlPoint1: NSPoint(x: x + w * 0.75, y: y + h * 0.90),
        controlPoint2: NSPoint(x: x + w * 0.93, y: y + h * 0.77)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.78, y: y + h * 0.27),
        controlPoint1: NSPoint(x: x + w * 0.98, y: y + h * 0.45),
        controlPoint2: NSPoint(x: x + w * 0.93, y: y + h * 0.25)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.44, y: y + h * 0.16),
        controlPoint1: NSPoint(x: x + w * 0.67, y: y + h * 0.02),
        controlPoint2: NSPoint(x: x + w * 0.51, y: y + h * 0.02)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.18, y: y + h * 0.28),
        controlPoint1: NSPoint(x: x + w * 0.30, y: y + h * 0.12),
        controlPoint2: NSPoint(x: x + w * 0.15, y: y + h * 0.15)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.14, y: y + h * 0.43),
        controlPoint1: NSPoint(x: x + w * 0.08, y: y + h * 0.32),
        controlPoint2: NSPoint(x: x + w * 0.07, y: y + h * 0.39)
    )
    path.close()
    return path
}

private func drawTerminalMark(in rect: NSRect, side: CGFloat) {
    let lineWidth = max(1.5, side * 0.028)
    let chevron = NSBezierPath()
    chevron.lineWidth = lineWidth
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.62))
    chevron.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.50))
    chevron.line(to: NSPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.38))

    let cursor = NSBezierPath()
    cursor.lineWidth = lineWidth
    cursor.lineCapStyle = .round
    cursor.move(to: NSPoint(x: rect.minX + rect.width * 0.54, y: rect.minY + rect.height * 0.42))
    cursor.line(to: NSPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.42))

    NSColor.white.setStroke()
    chevron.stroke()
    cursor.stroke()
}

private func drawStatusDots(in rect: NSRect, side: CGFloat) {
    let dot = side * 0.09
    let gap = side * 0.04
    let totalWidth = dot * 3 + gap * 2
    let startX = rect.midX - totalWidth / 2
    let y = rect.minY + side * 0.105
    let colors = [
        NSColor.systemRed,
        NSColor.systemYellow,
        NSColor.systemGreen
    ]

    for index in 0..<3 {
        let dotRect = NSRect(
            x: startX + CGFloat(index) * (dot + gap),
            y: y,
            width: dot,
            height: dot
        )
        drawShadow(offsetY: -side * 0.006, blur: side * 0.012, alpha: 0.22) {
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -side * 0.006, dy: -side * 0.006)).fill()
            colors[index].setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}

private func drawShadow(offsetY: CGFloat, blur: CGFloat, alpha: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.shadowBlurRadius = blur
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexMonitorIcon", code: 1)
    }
    return data
}

private func appendChunk(type: String, payload: Data, to data: inout Data) {
    appendFourCC(type, to: &data)
    appendUInt32(UInt32(payload.count + 8), to: &data)
    data.append(payload)
}

private func appendFourCC(_ string: String, to data: inout Data) {
    data.append(contentsOf: string.utf8.prefix(4))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}
