import AppKit
import CodexMonitorCore

struct MenuBarImageRenderer {
    static func image(
        snapshot: RateLimitSnapshot?,
        weeklyUsedTodayPercent: Double?,
        isRefreshing: Bool,
        activityStatus: CodexActivityStatus
    ) -> NSImage {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let dailyText = dailyUsageText(
            weeklyUsedTodayPercent: weeklyUsedTodayPercent,
            isRefreshing: isRefreshing
        )
        let fiveHourText = quotaText(label: "5H", quota: snapshot?.fiveHour)
        let weeklyText = quotaText(label: "WK", quota: snapshot?.weekly)
        let text = "\(dailyText) | \(fiveHourText) | \(weeklyText)"
        let horizontalPadding: CGFloat = 10
        let activityWidth: CGFloat = 14
        let activityGap: CGFloat = 5
        let activityCenterOffsetX: CGFloat = -2
        let textWidth = textWidth(text, attributes: textAttributes)
        let size = NSSize(
            width: horizontalPadding * 2 + activityWidth + activityGap + textWidth,
            height: 22
        )
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        drawQuotaBorder(size: size, usedPercent: snapshot?.fiveHour?.usedPercent)
        drawActivityDot(status: activityStatus, center: NSPoint(x: horizontalPadding + activityWidth / 2 + activityCenterOffsetX, y: size.height / 2))
        text.draw(at: NSPoint(x: horizontalPadding + activityWidth + activityGap, y: 4), withAttributes: textAttributes)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func dailyUsageText(weeklyUsedTodayPercent: Double?, isRefreshing: Bool) -> String {
        if let weeklyUsedTodayPercent {
            return DailyWeeklyUsageText.percent(weeklyUsedTodayPercent)
        }
        return isRefreshing ? "..." : "--"
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

    private static func textWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private static func drawQuotaBorder(size: NSSize, usedPercent: Double?) {
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
            color(forUsedPercent: usedPercent).setStroke()
            borderPath.stroke()
            return
        }

        let perimeter = 2 * (rect.width - 2 * radius) + 2 * .pi * radius
        borderPath.setLineDash([perimeter * CGFloat(progress), perimeter], count: 2, phase: 0)
        color(forUsedPercent: usedPercent).setStroke()
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

    private static func color(forUsedPercent percent: Double) -> NSColor {
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
}
