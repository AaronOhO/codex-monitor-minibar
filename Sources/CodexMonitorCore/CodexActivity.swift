import Foundation

public enum CodexActivityStatus: Int, Equatable {
    case none = 0
    case idle = 1
    case running = 2
    case needsAttention = 3
}

public struct CodexHookEvent: Codable, Equatable {
    public let hookEventName: String
    public let sessionID: String
    public let turnID: String?
    public let cwd: String
    public let toolName: String?
    public let toolFailed: Bool

    public init(
        hookEventName: String,
        sessionID: String,
        turnID: String?,
        cwd: String,
        toolName: String?,
        toolFailed: Bool = false
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.toolName = toolName
        self.toolFailed = toolFailed
    }
}

public struct CodexSessionActivity: Equatable {
    public let sessionID: String
    public let cwd: String
    public let status: CodexActivityStatus
    public let lastEventName: String
    public let toolName: String?
    public let updatedAt: Date
}

public struct CodexActivitySummary: Equatable {
    public let status: CodexActivityStatus
    public let menuTitle: String
}

public enum CodexHookEventParser {
    public static func parse(_ data: Data) throws -> CodexHookEvent {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHookEventParserError.invalidPayload
        }
        guard let eventName = payload["hook_event_name"] as? String else {
            throw CodexHookEventParserError.missingField("hook_event_name")
        }
        guard let sessionID = payload["session_id"] as? String else {
            throw CodexHookEventParserError.missingField("session_id")
        }
        guard let cwd = payload["cwd"] as? String else {
            throw CodexHookEventParserError.missingField("cwd")
        }

        return CodexHookEvent(
            hookEventName: eventName,
            sessionID: sessionID,
            turnID: payload["turn_id"] as? String,
            cwd: cwd,
            toolName: payload["tool_name"] as? String,
            toolFailed: toolResponseFailed(payload["tool_response"])
        )
    }

    private static func toolResponseFailed(_ value: Any?) -> Bool {
        switch value {
        case let dictionary as [String: Any]:
            return dictionaryLooksFailed(dictionary)
                || dictionary.values.contains { toolResponseFailed($0) }
        case let array as [Any]:
            return array.contains { toolResponseFailed($0) }
        default:
            return false
        }
    }

    private static func dictionaryLooksFailed(_ dictionary: [String: Any]) -> Bool {
        for key in ["is_error", "isError"] where dictionary[key] as? Bool == true {
            return true
        }
        for key in ["success", "ok"] where dictionary[key] as? Bool == false {
            return true
        }
        for key in ["exit_code", "exitCode"] {
            if let code = dictionary[key] as? Int, code != 0 {
                return true
            }
            if let number = dictionary[key] as? NSNumber, number.intValue != 0 {
                return true
            }
        }
        return false
    }
}

public enum CodexHookEventParserError: LocalizedError {
    case invalidPayload
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "Codex hook payload is not a JSON object"
        case .missingField(let field):
            "Codex hook payload is missing \(field)"
        }
    }
}

public final class CodexActivityStore {
    private var sessionsByID: [String: CodexSessionActivity] = [:]
    private let retentionSeconds: TimeInterval

    public init(retentionSeconds: TimeInterval = 30 * 60) {
        self.retentionSeconds = retentionSeconds
    }

    public func record(_ event: CodexHookEvent, at date: Date = Date()) {
        sessionsByID[event.sessionID] = CodexSessionActivity(
            sessionID: event.sessionID,
            cwd: event.cwd,
            status: status(for: event),
            lastEventName: event.hookEventName,
            toolName: event.toolName,
            updatedAt: date
        )
    }

    public func sessions(now: Date = Date()) -> [CodexSessionActivity] {
        pruneExpired(now: now)
        return sessionsByID.values.sorted { left, right in
            left.updatedAt > right.updatedAt
        }
    }

    public func aggregateStatus(now: Date = Date()) -> CodexActivityStatus {
        let activeSessions = sessions(now: now)
        return aggregateStatus(for: activeSessions)
    }

    public func summary(now: Date = Date()) -> CodexActivitySummary {
        let activeSessions = sessions(now: now)
        let status = aggregateStatus(for: activeSessions)
        return CodexActivitySummary(
            status: status,
            menuTitle: menuTitle(status: status, sessions: activeSessions)
        )
    }

    private func aggregateStatus(for activeSessions: [CodexSessionActivity]) -> CodexActivityStatus {
        if activeSessions.contains(where: { $0.status == .needsAttention }) {
            return .needsAttention
        }
        if activeSessions.contains(where: { $0.status == .running }) {
            return .running
        }
        if activeSessions.contains(where: { $0.status == .idle }) {
            return .idle
        }
        return .none
    }

    private func status(for event: CodexHookEvent) -> CodexActivityStatus {
        if event.hookEventName == "PermissionRequest" {
            return .needsAttention
        }
        if event.hookEventName == "Stop" || event.hookEventName == "SubagentStop" {
            return .idle
        }
        return .running
    }

    private func menuTitle(status: CodexActivityStatus, sessions: [CodexSessionActivity]) -> String {
        switch status {
        case .needsAttention:
            let session = sessions.first { $0.status == .needsAttention }
            let reason = session?.toolName ?? session?.lastEventName ?? "permission required"
            return "Activity: needs attention (\(reason))"
        case .running:
            return "Activity: running"
        case .idle:
            return "Activity: idle"
        case .none:
            return "Activity: none"
        }
    }

    private func pruneExpired(now: Date) {
        sessionsByID = sessionsByID.filter { _, session in
            now.timeIntervalSince(session.updatedAt) <= retentionSeconds
        }
    }
}

public enum CodexHookSocket {
    public static func path(uid: uid_t = getuid()) -> String {
        "/tmp/codex-monitor-\(uid).sock"
    }
}
