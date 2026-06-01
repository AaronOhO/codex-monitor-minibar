import Foundation

public enum ResetCountdownFormatter {
    public static func compactText(resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else {
            return "--"
        }

        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 {
            return "now"
        }

        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            if remainingHours == 0 {
                return "\(days)d"
            }
            return "\(days)d\(remainingHours)h"
        }

        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h\(remainingMinutes)"
    }
}
