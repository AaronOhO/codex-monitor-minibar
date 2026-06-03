import AppKit
import CodexMonitorCore

struct MenuBarImageRenderer {
    static func image(
        snapshot: RateLimitSnapshot?,
        todayTokenText: String?,
        isRefreshing: Bool,
        activityStatus: CodexActivityStatus,
        staleFiveHourQuota: Bool,
        staleWeeklyQuota: Bool
    ) -> NSImage {
        let dailyText = todayTokenText ?? (isRefreshing ? "TK ..." : "TK --")
        let fiveHourText = quotaText(label: "5H", quota: snapshot?.fiveHour)
        let weeklyText = quotaText(label: "WK", quota: snapshot?.weekly)
        let textSegments = [
            TextSegment(text: dailyText, color: NSColor.white),
            TextSegment(text: " | ", color: NSColor.white),
            TextSegment(text: fiveHourText, color: staleFiveHourQuota ? NSColor.systemRed : NSColor.white),
            TextSegment(text: " | ", color: NSColor.white),
            TextSegment(text: weeklyText, color: staleWeeklyQuota ? NSColor.systemRed : NSColor.white)
        ]
        let horizontalPadding: CGFloat = 9
        let activityWidth: CGFloat = 14
        let activityGap: CGFloat = 5
        let activityCenterOffsetX: CGFloat = -4
        let textWidth = textWidth(textSegments)
        let size = NSSize(
            width: horizontalPadding * 2 + activityWidth + activityGap + textWidth,
            height: 22
        )
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        drawQuotaBorder(size: size, usedPercent: snapshot?.fiveHour?.usedPercent, isStale: staleFiveHourQuota)
        drawActivityDot(status: activityStatus, center: NSPoint(x: horizontalPadding + activityWidth / 2 + activityCenterOffsetX, y: size.height / 2))
        drawTextSegments(textSegments, at: NSPoint(x: horizontalPadding + activityWidth + activityGap, y: 4))

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func quotaText(label: String, quota: QuotaInfo?) -> String {
        guard let quota else {
            return "\(label) -- --"
        }
        return "\(label) \(wholePercent(quota.remainingPercent)) \(ResetCountdownFormatter.compactText(resetsAt: quota.resetsAt))"
    }

    private static func wholePercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func textWidth(_ segments: [TextSegment]) -> CGFloat {
        ceil(segments.reduce(CGFloat.zero) { width, segment in
            width + (segment.text as NSString).size(withAttributes: attributes(color: segment.color)).width
        })
    }

    private static func drawTextSegments(_ segments: [TextSegment], at point: NSPoint) {
        var x = point.x
        for segment in segments {
            let attributes = attributes(color: segment.color)
            segment.text.draw(at: NSPoint(x: x, y: point.y), withAttributes: attributes)
            x += (segment.text as NSString).size(withAttributes: attributes).width
        }
    }

    private static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold),
            .foregroundColor: color
        ]
    }

    private static func drawQuotaBorder(size: NSSize, usedPercent: Double?, isStale: Bool) {
        let rect = NSRect(x: 1.25, y: 1.25, width: size.width - 2.5, height: size.height - 2.5)
        let radius = rect.height / 2
        let borderPath = capsulePath(rect: rect, radius: radius)
        borderPath.lineWidth = 2.5
        borderPath.lineCapStyle = .round
        borderPath.lineJoinStyle = .round

        NSColor.white.withAlphaComponent(0.28).setStroke()
        borderPath.stroke()

        guard let usedPercent, usedPercent > 0 else {
            return
        }

        let progress = max(0, min(100, usedPercent)) / 100
        if progress >= 1 {
            color(forUsedPercent: usedPercent, isStale: isStale).setStroke()
            borderPath.stroke()
            return
        }

        let perimeter = 2 * (rect.width - 2 * radius) + 2 * .pi * radius
        borderPath.setLineDash([perimeter * CGFloat(progress), perimeter], count: 2, phase: 0)
        color(forUsedPercent: usedPercent, isStale: isStale).setStroke()
        borderPath.stroke()
    }

    private static func drawActivityDot(status: CodexActivityStatus, center: NSPoint) {
        let diameter: CGFloat = 12.75
        let rect = NSRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        color(forActivityStatus: status).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static func capsulePath(rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.midY),
            radius: radius,
            startAngle: 90,
            endAngle: -90,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.midY),
            radius: radius,
            startAngle: -90,
            endAngle: -270,
            clockwise: true
        )
        path.close()
        return path
    }

    private static func color(forUsedPercent percent: Double, isStale: Bool) -> NSColor {
        if isStale {
            return NSColor.systemRed
        }
        if percent >= 85 {
            return NSColor.systemRed
        }
        if percent >= 65 {
            return NSColor.systemYellow
        }
        return NSColor.systemGreen
    }

    private static func color(forActivityStatus status: CodexActivityStatus) -> NSColor {
        switch status {
        case .needsAttention:
            return NSColor.systemRed
        case .running:
            return NSColor.systemGreen
        case .idle:
            return NSColor.systemYellow
        case .none:
            return NSColor.white.withAlphaComponent(0.72)
        }
    }

    private struct TextSegment {
        let text: String
        let color: NSColor
    }
}
