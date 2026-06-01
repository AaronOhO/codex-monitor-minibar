import Foundation

public enum QuotaWindow: Equatable {
    case fiveHour
    case weekly
}

public struct QuotaInfo: Equatable {
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetsAt: Date?
    public let windowDurationMins: Int
}

public struct RateLimitSnapshot: Equatable {
    public let fiveHour: QuotaInfo?
    public let weekly: QuotaInfo?
    public let planType: String?
    public let limitName: String?
}

public enum RateLimitParser {
    public static func classify(windowDurationMins: Int) -> QuotaWindow? {
        if (240...360).contains(windowDurationMins) {
            return .fiveHour
        }
        if windowDurationMins >= 7 * 24 * 60 {
            return .weekly
        }
        return nil
    }

    public static func parse(jsonRPCResponse data: Data) throws -> RateLimitSnapshot {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(JSONRPCEnvelope.self, from: data)
        var fiveHour: QuotaInfo?
        var weekly: QuotaInfo?

        for window in [envelope.result.rateLimits.primary, envelope.result.rateLimits.secondary].compactMap({ $0 }) {
            guard let duration = window.windowDurationMins else {
                continue
            }
            let quota = QuotaInfo(
                usedPercent: clampPercent(window.usedPercent),
                remainingPercent: clampPercent(100 - window.usedPercent),
                resetsAt: window.resetsAt?.date,
                windowDurationMins: duration
            )

            switch classify(windowDurationMins: duration) {
            case .fiveHour:
                fiveHour = quota
            case .weekly:
                weekly = quota
            case nil:
                continue
            }
        }

        return RateLimitSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            planType: envelope.result.rateLimits.planType,
            limitName: envelope.result.rateLimits.limitName
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }
}

private struct JSONRPCEnvelope: Decodable {
    let result: RateLimitsResult
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
    let limitName: String?
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let planType: String?
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: RPCDate?
}

private struct RPCDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Int.self) {
            self.date = Date(timeIntervalSince1970: TimeInterval(seconds))
            return
        }
        if let seconds = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: seconds)
            return
        }
        let stringValue = try container.decode(String.self)
        if let date = ISO8601DateFormatter().date(from: stringValue) {
            self.date = date
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported reset date: \(stringValue)"
        )
    }
}
