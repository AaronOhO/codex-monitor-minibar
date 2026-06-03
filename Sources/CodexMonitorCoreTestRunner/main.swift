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

func testParsesPrimaryWithoutWindowDurationAsFiveHour() throws {
    let response = """
    {
      "id": "rate-limit-read-1",
      "result": {
        "rateLimits": {
          "primary": {
            "usedPercent": 1,
            "windowDurationMins": null,
            "resetsAt": 1780470005
          },
          "secondary": null
        }
      }
    }
    """.data(using: .utf8)!

    let snapshot = try RateLimitParser.parse(jsonRPCResponse: response)

    try expect(snapshot.fiveHour?.usedPercent == 1, "expected primary fallback as 5h")
    try expect(snapshot.fiveHour?.remainingPercent == 99, "expected primary fallback remaining")
    try expect(snapshot.fiveHour?.windowDurationMins == 300, "expected fallback 5h duration")
    try expect(snapshot.weekly == nil, "expected missing secondary to stay unavailable")
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

func testLocalTokenUsageIndexesAndSkipsUnchangedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessionsDirectory = directory.appendingPathComponent("sessions/2026/05/25", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

    let fileURL = sessionsDirectory.appendingPathComponent("rollout.jsonl")
    try (
        tokenCountLine(timestamp: "2026-05-25T16:30:00Z", total: 100, input: 80, cached: 50, output: 20, reasoning: 5)
            + #"{"timestamp":"2026-05-25T16:31:00Z","type":"response_item","payload":{}}"# + "\n"
    ).write(to: fileURL, atomically: true, encoding: .utf8)

    let store = CodexLocalTokenUsageStore(
        codexHomeURL: directory,
        stateURL: directory.appendingPathComponent("index.json"),
        calendar: calendar(timeZoneOffsetHours: 8)
    )

    let first = try store.refresh()
    try expect(first.indexedFileCount == 1, "expected one indexed file")
    try expect(first.processedFileCount == 1, "expected initial scan to process one file")
    try expect(first.usage(for: "2026-05-26").totalTokens == 100, "expected token event to use local day")
    try expect(first.usage(for: "2026-05-26").cachedInputTokens == 50, "expected cached tokens parsed")

    let second = try store.refresh()
    try expect(second.processedFileCount == 0, "expected unchanged file to be skipped")
    try expect(second.processedByteCount == 0, "expected unchanged file to read no bytes")
    try expect(second.usage(for: "2026-05-26").totalTokens == 100, "expected cached index result")
}

func testLocalTokenUsageProcessesOnlyAppendedCompleteLines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessionsDirectory = directory.appendingPathComponent("sessions/2026/05/25", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

    let fileURL = sessionsDirectory.appendingPathComponent("rollout.jsonl")
    try tokenCountLine(timestamp: "2026-05-25T01:00:00Z", total: 100, input: 80, cached: 20, output: 20, reasoning: 5)
        .write(to: fileURL, atomically: true, encoding: .utf8)

    let store = CodexLocalTokenUsageStore(
        codexHomeURL: directory,
        stateURL: directory.appendingPathComponent("index.json"),
        calendar: calendar(timeZoneOffsetHours: 0)
    )

    _ = try store.refresh()
    try append(tokenCountLine(timestamp: "2026-05-25T02:00:00Z", total: 200, input: 180, cached: 40, output: 20, reasoning: 10), to: fileURL)

    let appended = try store.refresh()
    try expect(appended.processedFileCount == 1, "expected appended file to be processed")
    try expect(appended.usage(for: "2026-05-25").totalTokens == 300, "expected appended token event once")

    try append(
        #"{"timestamp":"2026-05-25T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":280,"cached_input_tokens":70,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":300}}}}"#,
        to: fileURL
    )
    let incomplete = try store.refresh()
    try expect(incomplete.usage(for: "2026-05-25").totalTokens == 300, "expected incomplete line to be ignored")

    try append("\n", to: fileURL)
    let completed = try store.refresh()
    try expect(completed.usage(for: "2026-05-25").totalTokens == 600, "expected completed line to be indexed")
}

func testLocalTokenUsagePrefersTotalDeltaWhenLastUsageIsOverstated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessionsDirectory = directory.appendingPathComponent("sessions/2026/06/02", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

    let fileURL = sessionsDirectory.appendingPathComponent("rollout.jsonl")
    let first = tokenCountLine(
        timestamp: "2026-06-02T01:00:00Z",
        lastUsage: tokenUsageJSON(total: 100, input: 80, cached: 20, output: 20, reasoning: 5),
        totalUsage: tokenUsageJSON(total: 100, input: 80, cached: 20, output: 20, reasoning: 5)
    )
    let overstatedLast = tokenCountLine(
        timestamp: "2026-06-02T02:00:00Z",
        lastUsage: tokenUsageJSON(total: 1_000, input: 900, cached: 100, output: 100, reasoning: 50),
        totalUsage: tokenUsageJSON(total: 160, input: 140, cached: 25, output: 20, reasoning: 5)
    )
    try (first + overstatedLast).write(to: fileURL, atomically: true, encoding: .utf8)

    let store = CodexLocalTokenUsageStore(
        codexHomeURL: directory,
        stateURL: directory.appendingPathComponent("index.json"),
        calendar: calendar(timeZoneOffsetHours: 0)
    )

    let snapshot = try store.refresh()
    let usage = snapshot.usage(for: "2026-06-02")
    try expect(usage.totalTokens == 160, "expected cumulative total delta instead of overstated last usage")
    try expect(usage.inputTokens == 140, "expected input to follow cumulative total delta")
    try expect(usage.cachedInputTokens == 25, "expected cached input to follow cumulative total delta")
}

func testLocalTokenUsageSubtractsForkParentTotals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parentDirectory = directory.appendingPathComponent("sessions/2026/06/01", isDirectory: true)
    let childDirectory = directory.appendingPathComponent("sessions/2026/06/02", isDirectory: true)
    try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)

    let parentURL = parentDirectory.appendingPathComponent("parent.jsonl")
    let childURL = childDirectory.appendingPathComponent("child.jsonl")
    try (
        sessionMetaLine(sessionID: "parent-session", forkedFromID: nil, timestamp: "2026-06-01T10:00:00Z")
            + tokenCountLine(
                timestamp: "2026-06-01T10:01:00Z",
                lastUsage: nil,
                totalUsage: tokenUsageJSON(total: 100, input: 100, cached: 20, output: 0, reasoning: 0)
            )
    ).write(to: parentURL, atomically: true, encoding: .utf8)
    try (
        sessionMetaLine(sessionID: "child-session", forkedFromID: "parent-session", timestamp: "2026-06-01T10:01:00Z")
            + tokenCountLine(
                timestamp: "2026-06-02T02:00:00Z",
                lastUsage: nil,
                totalUsage: tokenUsageJSON(total: 130, input: 125, cached: 20, output: 5, reasoning: 0)
            )
    ).write(to: childURL, atomically: true, encoding: .utf8)

    let cutoff = Date(timeIntervalSince1970: 2_000)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: parentURL.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: childURL.path)

    let store = CodexLocalTokenUsageStore(
        codexHomeURL: directory,
        stateURL: directory.appendingPathComponent("index.json"),
        calendar: calendar(timeZoneOffsetHours: 0)
    )

    let snapshot = try store.refresh(since: cutoff)
    let usage = snapshot.usage(for: "2026-06-02")
    try expect(snapshot.indexedFileCount == 1, "expected only child file in today's index")
    try expect(usage.totalTokens == 30, "expected fork child to subtract inherited parent total")
    try expect(usage.inputTokens == 25, "expected fork child input delta")
    try expect(usage.outputTokens == 5, "expected fork child output delta")
}

func testLocalTokenUsageSkipsFilesOlderThanCutoff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessionsDirectory = directory.appendingPathComponent("sessions/2026/06/02", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

    let oldFileURL = sessionsDirectory.appendingPathComponent("old.jsonl")
    let newFileURL = sessionsDirectory.appendingPathComponent("new.jsonl")
    try tokenCountLine(timestamp: "2026-06-02T01:00:00Z", total: 500, input: 400, cached: 100, output: 100, reasoning: 25)
        .write(to: oldFileURL, atomically: true, encoding: .utf8)
    try tokenCountLine(timestamp: "2026-06-02T02:00:00Z", total: 100, input: 80, cached: 20, output: 20, reasoning: 5)
        .write(to: newFileURL, atomically: true, encoding: .utf8)

    let cutoff = Date(timeIntervalSince1970: 2_000)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: oldFileURL.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: newFileURL.path)

    let store = CodexLocalTokenUsageStore(
        codexHomeURL: directory,
        stateURL: directory.appendingPathComponent("index.json"),
        calendar: calendar(timeZoneOffsetHours: 0)
    )

    let snapshot = try store.refresh(since: cutoff)
    try expect(snapshot.indexedFileCount == 1, "expected only the recent file to be indexed")
    try expect(snapshot.processedFileCount == 1, "expected only the recent file to be processed")
    try expect(snapshot.usage(for: "2026-06-02").totalTokens == 100, "expected old modified file to be skipped")
}

func testLocalTokenUsageCompactsCounts() throws {
    try expect(LocalTokenUsageText.compact(9_999) == "9999", "expected small count unchanged")
    try expect(LocalTokenUsageText.compact(12_300) == "12.3K", "expected K formatting")
    try expect(LocalTokenUsageText.compact(1_234_000) == "1.23M", "expected small M formatting")
    try expect(LocalTokenUsageText.compact(12_300_000) == "12.3M", "expected M formatting")
    try expect(LocalTokenUsageText.compact(123_000_000) == "123M", "expected large M formatting")
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
    test "$CODEX_MONITOR_MINIBAR" = "1" || exit 2

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

func calendar(timeZoneOffsetHours: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: timeZoneOffsetHours * 60 * 60)!
    return calendar
}

func tokenUsageJSON(total: Int64, input: Int64, cached: Int64, output: Int64, reasoning: Int64) -> String {
    #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)}"#
}

func tokenCountLine(timestamp: String, total: Int64, input: Int64, cached: Int64, output: Int64, reasoning: Int64) -> String {
    tokenCountLine(
        timestamp: timestamp,
        lastUsage: tokenUsageJSON(total: total, input: input, cached: cached, output: output, reasoning: reasoning),
        totalUsage: nil
    )
}

func tokenCountLine(timestamp: String, lastUsage: String?, totalUsage: String?) -> String {
    let fields = [
        lastUsage.map { #""last_token_usage":\#($0)"# },
        totalUsage.map { #""total_token_usage":\#($0)"# }
    ].compactMap { $0 }.joined(separator: ",")
    return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\#(fields)}}}"# + "\n"
}

func sessionMetaLine(sessionID: String, forkedFromID: String?, timestamp: String) -> String {
    let forkField = forkedFromID.map { #","forked_from_id":"\#($0)""# } ?? ""
    return #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"session_id":"\#(sessionID)","timestamp":"\#(timestamp)"\#(forkField)}}"# + "\n"
}

func append(_ text: String, to fileURL: URL) throws {
    let handle = try FileHandle(forWritingTo: fileURL)
    defer {
        try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

let tests = [
    ("parse rate limits", testParsesPrimaryAndSecondaryRateLimitsFromCodexResponse),
    ("clamp percentages", testClampsDisplayedPercentages),
    ("parse decimal percentages", testParsesDecimalUsedPercentWithoutTruncating),
    ("parse missing primary duration", testParsesPrimaryWithoutWindowDurationAsFiveHour),
    ("classify windows", testClassifiesQuotaWindowsByDuration),
    ("reset countdown", testFormatsResetCountdownCompactly),
    ("local token usage index skip", testLocalTokenUsageIndexesAndSkipsUnchangedFiles),
    ("local token usage append", testLocalTokenUsageProcessesOnlyAppendedCompleteLines),
    ("local token usage total delta", testLocalTokenUsagePrefersTotalDeltaWhenLastUsageIsOverstated),
    ("local token usage fork parent", testLocalTokenUsageSubtractsForkParentTotals),
    ("local token usage cutoff", testLocalTokenUsageSkipsFilesOlderThanCutoff),
    ("local token usage text", testLocalTokenUsageCompactsCounts),
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
