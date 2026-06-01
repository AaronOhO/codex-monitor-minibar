import Foundation

public struct DailyWeeklyUsageState: Codable, Equatable {
    public let dayKey: String
    public let baselineUsedPercent: Double

    public init(dayKey: String, baselineUsedPercent: Double) {
        self.dayKey = dayKey
        self.baselineUsedPercent = Self.clamp(baselineUsedPercent)
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(100, value))
    }
}

public struct DailyWeeklyUsageResult: Equatable {
    public let state: DailyWeeklyUsageState
    public let usedTodayPercent: Double
}

public enum DailyWeeklyUsageTracker {
    public static func mergedState(
        primary: DailyWeeklyUsageState?,
        fallback: DailyWeeklyUsageState?,
        dayKey: String
    ) -> DailyWeeklyUsageState? {
        let sameDayStates = [primary, fallback]
            .compactMap { $0 }
            .filter { $0.dayKey == dayKey }

        if let earliestBaseline = sameDayStates.min(by: { $0.baselineUsedPercent < $1.baselineUsedPercent }) {
            return earliestBaseline
        }

        return primary ?? fallback
    }

    public static func update(
        currentUsedPercent: Double,
        state: DailyWeeklyUsageState?,
        dayKey: String
    ) -> DailyWeeklyUsageResult {
        let current = clamp(currentUsedPercent)
        let baseline = state?.dayKey == dayKey ? state?.baselineUsedPercent ?? current : current
        let nextState = DailyWeeklyUsageState(dayKey: dayKey, baselineUsedPercent: baseline)

        return DailyWeeklyUsageResult(
            state: nextState,
            usedTodayPercent: clamp(current - baseline)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(100, value))
    }
}

public enum DailyWeeklyUsageText {
    public static func percent(_ value: Double) -> String {
        "\(Int(max(0, min(100, value)).rounded()))%"
    }
}
