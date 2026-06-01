import CodexMonitorCore
import Darwin
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func expectClose(_ actual: Double?, _ expected: Double, _ message: String) throws {
    guard let actual, abs(actual - expected) < 0.0001 else {
        throw TestFailure.failed(message)
    }
}

func testParsesPrimaryAndSecondaryRateLimitsFromCodexResponse() throws {
    let response = """
    {
      "id": "rate-limit-read-1",
      "result": {
        "rateLimits": {
          "limitId": "codex",
          "limitName": null,
          "primary": {
            "usedPercent": 13,
            "windowDurationMins": 300,
            "resetsAt": 1780240618
          },
          "secondary": {
            "usedPercent": 70,
            "windowDurationMins": 10080,
            "resetsAt": 1780827418
          },
          "planType": "pro"
        }
      }
    }
    """.data(using: .utf8)!

    let snapshot = try RateLimitParser.parse(jsonRPCResponse: response)

    try expect(snapshot.planType == "pro", "expected planType pro")
    try expect(snapshot.fiveHour?.usedPercent == 13, "expected 5h used 13")
    try expect(snapshot.fiveHour?.remainingPercent == 87, "expected 5h remaining 87")
    try expect(snapshot.fiveHour?.windowDurationMins == 300, "expected 5h duration 300")
    try expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1780240618), "expected 5h reset date")
    try expect(snapshot.weekly?.usedPercent == 70, "expected weekly used 70")
    try expect(snapshot.weekly?.remainingPercent == 30, "expected weekly remaining 30")
    try expect(snapshot.weekly?.windowDurationMins == 10080, "expected weekly duration 10080")
    try expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1780827418), "expected weekly reset date")
}

func testClampsDisplayedPercentages() throws {
    let response = """
    {
      "id": "rate-limit-read-1",
      "result": {
        "rateLimits": {
          "primary": {
            "usedPercent": 125,
            "windowDurationMins": 300,
            "resetsAt": "2026-05-31T14:15:00Z"
          },
          "secondary": {
            "usedPercent": -10,
            "windowDurationMins": 10080,
            "resetsAt": "2026-05-31T15:34:00Z"
          }
        }
      }
    }
    """.data(using: .utf8)!

    let snapshot = try RateLimitParser.parse(jsonRPCResponse: response)

    try expect(snapshot.fiveHour?.usedPercent == 100, "expected 5h used clamp")
    try expect(snapshot.fiveHour?.remainingPercent == 0, "expected 5h remaining clamp")
    try expect(snapshot.weekly?.usedPercent == 0, "expected weekly used clamp")
    try expect(snapshot.weekly?.remainingPercent == 100, "expected weekly remaining clamp")
}

func testParsesDecimalUsedPercentWithoutTruncating() throws {
    let response = """
    {
      "id": "rate-limit-read-1",
      "result": {
        "rateLimits": {
          "primary": {
            "usedPercent": 12.34,
            "windowDurationMins": 300,
            "resetsAt": "2026-05-31T14:15:00Z"
          }
        }
      }
    }
    """.data(using: .utf8)!

    let snapshot = try RateLimitParser.parse(jsonRPCResponse: response)

    try expectClose(snapshot.fiveHour?.usedPercent, 12.34, "expected decimal used percent")
    try expectClose(snapshot.fiveHour?.remainingPercent, 87.66, "expected decimal remaining percent")
}

func testClassifiesQuotaWindowsByDuration() throws {
    try expect(RateLimitParser.classify(windowDurationMins: 240) == .fiveHour, "expected 240 as 5h")
    try expect(RateLimitParser.classify(windowDurationMins: 300) == .fiveHour, "expected 300 as 5h")
    try expect(RateLimitParser.classify(windowDurationMins: 360) == .fiveHour, "expected 360 as 5h")
    try expect(RateLimitParser.classify(windowDurationMins: 10080) == .weekly, "expected 10080 as weekly")
    try expect(RateLimitParser.classify(windowDurationMins: 42) == nil, "expected 42 as unknown")
}

func testFormatsResetCountdownCompactly() throws {
    let now = Date(timeIntervalSince1970: 0)

    try expect(
        ResetCountdownFormatter.compactText(resetsAt: now.addingTimeInterval(2 * 60 * 60 + 18 * 60), now: now) == "2h18",
        "expected hour countdown as 2h18"
    )
    try expect(
        ResetCountdownFormatter.compactText(resetsAt: now.addingTimeInterval(18 * 60), now: now) == "18m",
        "expected minute countdown as 18m"
    )
    try expect(
        ResetCountdownFormatter.compactText(resetsAt: now.addingTimeInterval(-1), now: now) == "now",
        "expected elapsed countdown as now"
    )
    try expect(
        ResetCountdownFormatter.compactText(resetsAt: nil, now: now) == "--",
        "expected missing countdown as --"
    )
    try expect(
        ResetCountdownFormatter.compactText(resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60 + 21 * 60 * 60), now: now) == "6d21h",
        "expected day countdown as 6d21h"
    )
}

func testDailyWeeklyUsageStartsAtZeroForFirstObservation() throws {
    let result = DailyWeeklyUsageTracker.update(currentUsedPercent: 4.25, state: nil, dayKey: "2026-05-31")

    try expect(result.usedTodayPercent == 0.0, "expected first observation to start at zero")
    try expect(result.state.dayKey == "2026-05-31", "expected state day key to be saved")
    try expect(result.state.baselineUsedPercent == 4.25, "expected current used percent as baseline")
}

func testDailyWeeklyUsageTracksIncreaseFromTodayBaseline() throws {
    let state = DailyWeeklyUsageState(dayKey: "2026-05-31", baselineUsedPercent: 4.25)

    let result = DailyWeeklyUsageTracker.update(currentUsedPercent: 7.75, state: state, dayKey: "2026-05-31")

    try expect(result.usedTodayPercent == 3.5, "expected today usage delta")
    try expect(result.state == state, "expected same-day baseline to stay stable")
}

func testDailyWeeklyUsageClampsWhenCurrentFallsBelowBaseline() throws {
    let state = DailyWeeklyUsageState(dayKey: "2026-05-31", baselineUsedPercent: 70)

    let result = DailyWeeklyUsageTracker.update(currentUsedPercent: 2, state: state, dayKey: "2026-05-31")

    try expect(result.usedTodayPercent == 0, "expected negative delta clamp")
}

func testDailyWeeklyUsageResetsBaselineOnNewDay() throws {
    let state = DailyWeeklyUsageState(dayKey: "2026-05-30", baselineUsedPercent: 4)

    let result = DailyWeeklyUsageTracker.update(currentUsedPercent: 9, state: state, dayKey: "2026-05-31")

    try expect(result.usedTodayPercent == 0, "expected new day to start at zero")
    try expect(result.state.dayKey == "2026-05-31", "expected new day key")
    try expect(result.state.baselineUsedPercent == 9, "expected new day baseline")
}

func testDailyWeeklyUsageFormatsPercentAsWholePercent() throws {
    try expect(DailyWeeklyUsageText.percent(0) == "0%", "expected zero as whole percent")
    try expect(DailyWeeklyUsageText.percent(1.234) == "1%", "expected whole percent rounding down")
    try expect(DailyWeeklyUsageText.percent(1.5) == "2%", "expected whole percent rounding up")
}

func testRateLimitClientFallsBackToStdioWhenControlSocketProxyCloses() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executableURL = directory.appendingPathComponent("fake-codex")
    let controlSocketURL = directory.appendingPathComponent("app-server-control.sock")
    try Data().write(to: controlSocketURL)
    let script = """
    #!/bin/sh
    if [ "$1" = "app-server" ] && [ "$2" = "proxy" ]; then
      exit 0
    fi

    printf '%s\\n' '{"id":1,"result":{}}'
    printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":"2026-05-31T14:15:00Z"},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":"2026-06-01T14:15:00Z"}}}}'
    sleep 1
    """
    try script.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let client = CodexRateLimitClient(
        codexExecutablePath: executableURL.path,
        controlSocketPath: controlSocketURL.path,
        timeoutSeconds: 3
    )
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<RateLimitSnapshot, Error>?
    Task {
        do {
            result = .success(try await client.readRateLimits())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()

    let snapshot = try result?.get()
    try expect(snapshot?.fiveHour?.usedPercent == 20, "expected stdio fallback 5h used percent")
    try expect(snapshot?.weekly?.remainingPercent == 60, "expected stdio fallback weekly remaining percent")
}

func testCodexActivityTracksSessionsIndependentlyAndPrioritizesAttention() throws {
    let store = CodexActivityStore()
    let now = Date(timeIntervalSince1970: 100)

    store.record(CodexHookEvent(hookEventName: "UserPromptSubmit", sessionID: "session-a", turnID: "turn-1", cwd: "/tmp/a", toolName: nil), at: now)
    store.record(CodexHookEvent(hookEventName: "Stop", sessionID: "session-b", turnID: "turn-1", cwd: "/tmp/b", toolName: nil), at: now.addingTimeInterval(1))

    try expect(store.aggregateStatus(now: now.addingTimeInterval(2)) == .running, "expected running session to make aggregate green")

    store.record(CodexHookEvent(hookEventName: "PermissionRequest", sessionID: "session-b", turnID: "turn-2", cwd: "/tmp/b", toolName: "exec_command"), at: now.addingTimeInterval(3))

    try expect(store.aggregateStatus(now: now.addingTimeInterval(4)) == .needsAttention, "expected permission request to outrank running")
    try expect(store.sessions(now: now.addingTimeInterval(4)).count == 2, "expected both sessions to be retained")
}

func testCodexHookEventParsesSessionKeyFromHookJSON() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "abc-session",
      "turn_id": "abc-turn",
      "cwd": "/Users/example/project",
      "tool_name": "exec_command"
    }
    """.data(using: .utf8)!

    let event = try CodexHookEventParser.parse(payload)

    try expect(event.sessionID == "abc-session", "expected session_id as session key")
    try expect(event.hookEventName == "PreToolUse", "expected hook event name")
    try expect(event.toolName == "exec_command", "expected tool name")
}

func testCodexHookSocketDeliversEvents() throws {
    let path = "/private/tmp/codex-monitor-test-\(UUID().uuidString).sock"
    let semaphore = DispatchSemaphore(value: 0)
    var received: CodexHookEvent?
    let server = CodexHookSocketServer(path: path) { event in
        received = event
        semaphore.signal()
    }
    try server.start()
    defer {
        server.stop()
    }

    try CodexHookSocketClient.send(
        CodexHookEvent(hookEventName: "PreToolUse", sessionID: "socket-session", turnID: "turn-1", cwd: "/tmp/socket", toolName: "exec_command"),
        path: path
    )

    try expect(semaphore.wait(timeout: .now() + 2) == .success, "expected socket event to arrive")
    try expect(received?.sessionID == "socket-session", "expected socket event session id")
}

func testCodexHookInstallerMergesHooksAndEnablesFeature() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hooksURL = directory.appendingPathComponent("hooks.json")
    let configURL = directory.appendingPathComponent("config.toml")

    try """
    {
      "hooks": {
        "PostToolUse": [
          {
            "matcher": "Edit|Write|apply_patch",
            "hooks": [
              {
                "command": "existing-command",
                "type": "command"
              }
            ]
          }
        ]
      }
    }
    """.write(to: hooksURL, atomically: true, encoding: .utf8)
    try """
    [features]
    memories = true
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let installer = CodexHookInstaller(
        hooksFileURL: hooksURL,
        configFileURL: configURL,
        bridgeCommand: "/tmp/CodexMonitorHookBridge"
    )
    try installer.install()
    try installer.install()

    let hooksData = try Data(contentsOf: hooksURL)
    let hooksObject = try JSONSerialization.jsonObject(with: hooksData) as? [String: Any]
    let hooks = hooksObject?["hooks"] as? [String: Any]
    let postToolUse = hooks?["PostToolUse"] as? [[String: Any]]
    let sessionStart = hooks?["SessionStart"] as? [[String: Any]]

    try expect(postToolUse?.contains { entry in
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
            return false
        }
        return entryHooks.contains { $0["command"] as? String == "existing-command" }
    } == true, "expected existing hook to be retained")
    try expect(postToolUse?.filter { entry in
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
            return false
        }
        return entryHooks.contains { $0["command"] as? String == "/tmp/CodexMonitorHookBridge" }
    }.count == 1, "expected bridge hook to be installed once")
    try expect(sessionStart?.count == 1, "expected session start hook")

    let configText = try String(contentsOf: configURL, encoding: .utf8)
    try expect(configText.contains("hooks = true"), "expected hooks feature enabled")
}

let tests = [
    ("parse rate limits", testParsesPrimaryAndSecondaryRateLimitsFromCodexResponse),
    ("clamp percentages", testClampsDisplayedPercentages),
    ("parse decimal percentages", testParsesDecimalUsedPercentWithoutTruncating),
    ("classify windows", testClassifiesQuotaWindowsByDuration),
    ("reset countdown", testFormatsResetCountdownCompactly),
    ("daily weekly first observation", testDailyWeeklyUsageStartsAtZeroForFirstObservation),
    ("daily weekly increase", testDailyWeeklyUsageTracksIncreaseFromTodayBaseline),
    ("daily weekly clamp", testDailyWeeklyUsageClampsWhenCurrentFallsBelowBaseline),
    ("daily weekly new day", testDailyWeeklyUsageResetsBaselineOnNewDay),
    ("daily weekly percent text", testDailyWeeklyUsageFormatsPercentAsWholePercent),
    ("rate limit client stdio fallback", testRateLimitClientFallsBackToStdioWhenControlSocketProxyCloses),
    ("codex activity multi-session aggregation", testCodexActivityTracksSessionsIndependentlyAndPrioritizesAttention),
    ("codex hook event parsing", testCodexHookEventParsesSessionKeyFromHookJSON),
    ("codex hook socket delivery", testCodexHookSocketDeliversEvents),
    ("codex hook installer", testCodexHookInstallerMergesHooksAndEnablesFeature)
]

if CommandLine.arguments.contains("--live-rpc") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        do {
            let client = CodexRateLimitClient()
            let snapshot = try await client.readRateLimits()
            print("LIVE 5H \(snapshot.fiveHour?.remainingPercent.description ?? "--")%")
            print("LIVE WEEK \(snapshot.weekly?.remainingPercent.description ?? "--")%")
        } catch {
            fputs("LIVE FAIL \(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
        fflush(stdout)
    }
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
