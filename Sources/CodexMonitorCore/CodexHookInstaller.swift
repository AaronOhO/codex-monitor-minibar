import Foundation

public struct CodexHookInstaller {
    private let hooksFileURL: URL
    private let configFileURL: URL
    private let bridgeCommand: String

    public init(
        hooksFileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json"),
        configFileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml"),
        bridgeCommand: String
    ) {
        self.hooksFileURL = hooksFileURL
        self.configFileURL = configFileURL
        self.bridgeCommand = bridgeCommand
    }

    public func install() throws {
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try installHooksJSON()
        try enableHooksFeature()
    }

    private func installHooksJSON() throws {
        var root = try readHooksRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for eventName in Self.eventNames {
            var entries = hooks[eventName] as? [[String: Any]] ?? []
            if !containsBridgeHook(entries) {
                entries.append(Self.bridgeEntry(command: bridgeCommand))
            }
            hooks[eventName] = entries
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksFileURL, options: .atomic)
    }

    private func readHooksRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksFileURL.path) else {
            return ["hooks": [String: Any]()]
        }
        let data = try Data(contentsOf: hooksFileURL)
        guard !data.isEmpty else {
            return ["hooks": [String: Any]()]
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["hooks": [String: Any]()]
        }
        return object
    }

    private func containsBridgeHook(_ entries: [[String: Any]]) -> Bool {
        entries.contains { entry in
            guard let hooks = entry["hooks"] as? [[String: Any]] else {
                return false
            }
            return hooks.contains { hook in
                hook["command"] as? String == bridgeCommand
            }
        }
    }

    private func enableHooksFeature() throws {
        let text: String
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            text = try String(contentsOf: configFileURL, encoding: .utf8)
        } else {
            text = ""
        }

        let updatedText = Self.enableHooksFeature(in: text)
        guard updatedText != text else {
            return
        }
        try FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updatedText.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    static func enableHooksFeature(in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var featuresStart: Int?
        var featuresEnd = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "[features]" {
                featuresStart = index
                continue
            }
            if featuresStart != nil, index > featuresStart!, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                featuresEnd = index
                break
            }
        }

        if let featuresStart {
            for index in (featuresStart + 1)..<featuresEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("hooks") {
                    lines[index] = "hooks = true"
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert("hooks = true", at: featuresStart + 1)
            return lines.joined(separator: "\n")
        }

        if !lines.isEmpty, lines.last != "" {
            lines.append("")
        }
        lines.append("[features]")
        lines.append("hooks = true")
        return lines.joined(separator: "\n")
    }

    private static func bridgeEntry(command: String) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                [
                    "command": command,
                    "statusMessage": "Updating CodexMonitor activity",
                    "timeout": 2,
                    "type": "command"
                ]
            ]
        ]
    }

    private static let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "SubagentStart",
        "SubagentStop",
        "Stop"
    ]
}
