import Foundation

public struct LocalTokenUsageBreakdown: Codable, Equatable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64

    public static let zero = LocalTokenUsageBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    public init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public mutating func add(_ other: LocalTokenUsageBreakdown) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

private extension LocalTokenUsageBreakdown {
    var isZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && outputTokens == 0
            && reasoningOutputTokens == 0
            && totalTokens == 0
    }

    func adding(_ other: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        LocalTokenUsageBreakdown(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }

    func clampedDelta(from baseline: LocalTokenUsageBreakdown?) -> LocalTokenUsageBreakdown {
        let baseline = baseline ?? .zero
        return LocalTokenUsageBreakdown(
            inputTokens: max(0, inputTokens - baseline.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - baseline.cachedInputTokens),
            outputTokens: max(0, outputTokens - baseline.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - baseline.reasoningOutputTokens),
            totalTokens: max(0, totalTokens - baseline.totalTokens)
        )
    }

    func clampedMin(_ other: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        LocalTokenUsageBreakdown(
            inputTokens: min(inputTokens, other.inputTokens),
            cachedInputTokens: min(cachedInputTokens, other.cachedInputTokens),
            outputTokens: min(outputTokens, other.outputTokens),
            reasoningOutputTokens: min(reasoningOutputTokens, other.reasoningOutputTokens),
            totalTokens: min(totalTokens, other.totalTokens)
        )
    }

    func clampedSubtract(_ other: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        LocalTokenUsageBreakdown(
            inputTokens: max(0, inputTokens - other.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - other.cachedInputTokens),
            outputTokens: max(0, outputTokens - other.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - other.reasoningOutputTokens),
            totalTokens: max(0, totalTokens - other.totalTokens)
        )
    }

    func isAtLeast(_ other: LocalTokenUsageBreakdown) -> Bool {
        inputTokens >= other.inputTokens
            && cachedInputTokens >= other.cachedInputTokens
            && outputTokens >= other.outputTokens
            && reasoningOutputTokens >= other.reasoningOutputTokens
            && totalTokens >= other.totalTokens
    }

    func isAtMost(_ other: LocalTokenUsageBreakdown) -> Bool {
        inputTokens <= other.inputTokens
            && cachedInputTokens <= other.cachedInputTokens
            && outputTokens <= other.outputTokens
            && reasoningOutputTokens <= other.reasoningOutputTokens
            && totalTokens <= other.totalTokens
    }
}

public struct LocalTokenUsageSnapshot: Equatable {
    public let days: [String: LocalTokenUsageBreakdown]
    public let indexedFileCount: Int
    public let processedFileCount: Int
    public let processedByteCount: UInt64

    public func usage(for dayKey: String) -> LocalTokenUsageBreakdown {
        days[dayKey] ?? .zero
    }
}

public final class CodexLocalTokenUsageStore: @unchecked Sendable {
    fileprivate static let indexVersion = 2

    private let codexHomeURL: URL
    private let stateURL: URL
    private let calendar: Calendar
    private let fileManager: FileManager

    public init(
        codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-monitor-minibar", isDirectory: true)
            .appendingPathComponent("token-usage-index.json"),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.codexHomeURL = codexHomeURL
        self.stateURL = stateURL
        self.calendar = calendar
        self.fileManager = fileManager
    }

    public func refresh(since minimumModificationDate: Date? = nil) throws -> LocalTokenUsageSnapshot {
        var index = loadIndex()
        var seenPaths = Set<String>()
        var processedFileCount = 0
        var processedByteCount: UInt64 = 0
        var sessionFileCache: [String: URL] = [:]
        var missingSessionIDs = Set<String>()
        var parentTotalsCache: [String: LocalTokenUsageBreakdown] = [:]
        var missingParentTotals = Set<String>()

        for url in sessionJSONLFiles(modifiedSince: minimumModificationDate) {
            let path = url.path
            seenPaths.insert(path)

            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let priorState = index.files[path]

            if let priorState, priorState.size == size, priorState.modifiedAt == modifiedAt {
                continue
            }

            let scanStart = appendOnlyScanStart(priorState: priorState, currentSize: size)
            let initialAccountingState = scanStart == 0 ? LocalTokenUsageAccountingState() : priorState?.accountingState ?? LocalTokenUsageAccountingState()
            let result = try scanFile(
                url: url,
                startOffset: scanStart,
                initialAccountingState: initialAccountingState,
                parentTotals: { [self] sessionID, forkTimestamp in
                    let cacheKey = "\(sessionID)\u{0}\(forkTimestamp)"
                    if let cached = parentTotalsCache[cacheKey] {
                        return cached
                    }
                    if missingParentTotals.contains(cacheKey) {
                        return nil
                    }
                    guard let totals = self.parentTotals(
                        sessionID: sessionID,
                        atOrBefore: forkTimestamp,
                        sessionFileCache: &sessionFileCache,
                        missingSessionIDs: &missingSessionIDs
                    ) else {
                        missingParentTotals.insert(cacheKey)
                        return nil
                    }
                    parentTotalsCache[cacheKey] = totals
                    return totals
                }
            )
            if result.bytesProcessed == 0, scanStart > 0 {
                if var nextState = priorState {
                    nextState.size = size
                    nextState.modifiedAt = modifiedAt
                    nextState.accountingState = result.accountingState
                    index.files[path] = nextState
                }
                continue
            }

            var nextState = priorState ?? LocalTokenUsageFileState()
            if scanStart == 0 {
                nextState.days = result.days
            } else {
                for (dayKey, usage) in result.days {
                    var dayUsage = nextState.days[dayKey] ?? .zero
                    dayUsage.add(usage)
                    nextState.days[dayKey] = dayUsage
                }
            }
            nextState.size = size
            nextState.modifiedAt = modifiedAt
            nextState.processedOffset = result.nextOffset
            nextState.accountingState = result.accountingState
            index.files[path] = nextState
            processedFileCount += 1
            processedByteCount += result.bytesProcessed
        }

        index.files = index.files.filter { seenPaths.contains($0.key) }
        try saveIndex(index)

        return LocalTokenUsageSnapshot(
            days: aggregateDays(from: index),
            indexedFileCount: index.files.count,
            processedFileCount: processedFileCount,
            processedByteCount: processedByteCount
        )
    }

    private func appendOnlyScanStart(priorState: LocalTokenUsageFileState?, currentSize: UInt64) -> UInt64 {
        guard let priorState else {
            return 0
        }
        if currentSize < priorState.processedOffset {
            return 0
        }
        return priorState.processedOffset
    }

    private func scanFile(
        url: URL,
        startOffset: UInt64,
        initialAccountingState: LocalTokenUsageAccountingState,
        parentTotals: (String, String) -> LocalTokenUsageBreakdown?
    ) throws -> LocalTokenUsageFileScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: startOffset)

        var days: [String: LocalTokenUsageBreakdown] = [:]
        var accountingState = initialAccountingState
        var buffer = Data()
        var processedBytes: UInt64 = 0

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 10) {
                let line = buffer[..<newlineIndex]
                if !line.isEmpty, let parsedLine = parseSessionLine(Data(line)) {
                    switch parsedLine {
                    case .sessionMeta(let metadata):
                        accountingState.resolveForkBaselineIfNeeded(
                            metadata: metadata,
                            parentTotals: parentTotals
                        )
                    case .tokenCount(let record):
                        if let usage = accountingState.apply(last: record.lastUsage, total: record.totalUsage) {
                            let dayKey = self.dayKey(for: record.timestamp)
                            var dayUsage = days[dayKey] ?? .zero
                            dayUsage.add(usage)
                            days[dayKey] = dayUsage
                        }
                    }
                }

                let nextIndex = buffer.index(after: newlineIndex)
                processedBytes += UInt64(buffer.distance(from: buffer.startIndex, to: nextIndex))
                buffer.removeSubrange(buffer.startIndex..<nextIndex)
            }
        }

        return LocalTokenUsageFileScanResult(
            days: days,
            nextOffset: startOffset + processedBytes,
            bytesProcessed: processedBytes,
            accountingState: accountingState
        )
    }

    private func parseSessionLine(_ data: Data) -> LocalTokenUsageSessionLine? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        if type == "session_meta" {
            let payload = object["payload"] as? [String: Any]
            return .sessionMeta(LocalTokenUsageSessionMetadata(
                sessionID: stringValue(payload?["session_id"])
                    ?? stringValue(payload?["sessionId"])
                    ?? stringValue(payload?["id"])
                    ?? stringValue(object["session_id"])
                    ?? stringValue(object["sessionId"])
                    ?? stringValue(object["id"]),
                forkedFromID: stringValue(payload?["forked_from_id"])
                    ?? stringValue(payload?["forkedFromId"])
                    ?? stringValue(payload?["parent_session_id"])
                    ?? stringValue(payload?["parentSessionId"]),
                forkTimestampText: stringValue(payload?["timestamp"])
                    ?? stringValue(object["timestamp"])
            ))
        }

        guard
            type == "event_msg",
            let timestampText = object["timestamp"] as? String,
            let timestamp = parseTimestamp(timestampText),
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any]
        else {
            return nil
        }

        return .tokenCount(LocalTokenUsageTokenRecord(
            timestamp: timestamp,
            timestampText: timestampText,
            lastUsage: (info["last_token_usage"] as? [String: Any]).map(parseUsage),
            totalUsage: (info["total_token_usage"] as? [String: Any]).map(parseUsage)
        ))
    }

    private func parseUsage(_ usage: [String: Any]) -> LocalTokenUsageBreakdown {
        let input = int64Value(usage["input_tokens"])
        let cached = int64Value(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])
        let output = int64Value(usage["output_tokens"])
        let reasoning = int64Value(usage["reasoning_output_tokens"])
        let total = int64Value(usage["total_tokens"])
        return LocalTokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total > 0 ? total : input + output
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    private func int64Value(_ value: Any?) -> Int64 {
        if let intValue = value as? Int {
            return Int64(intValue)
        }
        if let int64Value = value as? Int64 {
            return int64Value
        }
        if let numberValue = value as? NSNumber {
            return numberValue.int64Value
        }
        return 0
    }

    private func parseTimestamp(_ text: String) -> Date? {
        if let date = Self.timestampFormatterWithFractionalSeconds.date(from: text) {
            return date
        }
        return Self.timestampFormatter.date(from: text)
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func sessionJSONLFiles(modifiedSince minimumModificationDate: Date?) -> [URL] {
        let roots = [
            codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ]

        return roots.flatMap { root -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "jsonl" else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else {
                    return nil
                }
                if let minimumModificationDate,
                   let modificationDate = values?.contentModificationDate,
                   modificationDate < minimumModificationDate {
                    return nil
                }
                return url
            }
        }
    }

    private func parentTotals(
        sessionID: String,
        atOrBefore cutoffTimestampText: String,
        sessionFileCache: inout [String: URL],
        missingSessionIDs: inout Set<String>
    ) -> LocalTokenUsageBreakdown? {
        guard let fileURL = sessionFileURL(
            for: sessionID,
            sessionFileCache: &sessionFileCache,
            missingSessionIDs: &missingSessionIDs
        ) else {
            return nil
        }
        return tokenTotals(fileURL: fileURL, atOrBefore: cutoffTimestampText)
    }

    private func sessionFileURL(
        for sessionID: String,
        sessionFileCache: inout [String: URL],
        missingSessionIDs: inout Set<String>
    ) -> URL? {
        if let cached = sessionFileCache[sessionID] {
            return cached
        }
        if missingSessionIDs.contains(sessionID) {
            return nil
        }

        for url in sessionJSONLFiles(modifiedSince: nil) {
            guard let parsedSessionID = parseSessionID(fileURL: url) else {
                continue
            }
            sessionFileCache[parsedSessionID] = url
            if parsedSessionID == sessionID {
                return url
            }
        }

        missingSessionIDs.insert(sessionID)
        return nil
    }

    private func parseSessionID(fileURL: URL) -> String? {
        var sessionID: String?
        try? scanCompleteLines(fileURL: fileURL, startOffset: 0) { line, shouldStop in
            guard case .sessionMeta(let metadata) = parseSessionLine(line) else {
                return
            }
            sessionID = metadata.sessionID
            shouldStop = sessionID != nil
        }
        return sessionID
    }

    private func tokenTotals(fileURL: URL, atOrBefore cutoffTimestampText: String) -> LocalTokenUsageBreakdown? {
        let cutoffDate = parseTimestamp(cutoffTimestampText)
        var accountingState = LocalTokenUsageAccountingState()
        var totals: LocalTokenUsageBreakdown?

        try? scanCompleteLines(fileURL: fileURL, startOffset: 0) { line, shouldStop in
            guard case .tokenCount(let record) = parseSessionLine(line) else {
                return
            }
            let isAtOrBefore: Bool
            if let cutoffDate {
                isAtOrBefore = record.timestamp <= cutoffDate
            } else {
                isAtOrBefore = record.timestampText <= cutoffTimestampText
            }
            guard isAtOrBefore else {
                shouldStop = true
                return
            }
            _ = accountingState.apply(last: record.lastUsage, total: record.totalUsage)
            totals = accountingState.previousTotals
        }

        return totals
    }

    private func scanCompleteLines(
        fileURL: URL,
        startOffset: UInt64,
        onLine: (Data, inout Bool) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: startOffset)

        var buffer = Data()
        var shouldStop = false
        while !shouldStop, let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            buffer.append(chunk)
            while !shouldStop, let newlineIndex = buffer.firstIndex(of: 10) {
                let line = buffer[..<newlineIndex]
                if !line.isEmpty {
                    onLine(Data(line), &shouldStop)
                }

                let nextIndex = buffer.index(after: newlineIndex)
                buffer.removeSubrange(buffer.startIndex..<nextIndex)
            }
        }
    }

    private func aggregateDays(from index: LocalTokenUsageIndex) -> [String: LocalTokenUsageBreakdown] {
        var days: [String: LocalTokenUsageBreakdown] = [:]
        for fileState in index.files.values {
            for (dayKey, usage) in fileState.days {
                var dayUsage = days[dayKey] ?? .zero
                dayUsage.add(usage)
                days[dayKey] = dayUsage
            }
        }
        return days
    }

    private func loadIndex() -> LocalTokenUsageIndex {
        guard let data = try? Data(contentsOf: stateURL) else {
            return LocalTokenUsageIndex()
        }
        guard let index = try? JSONDecoder().decode(LocalTokenUsageIndex.self, from: data),
              index.version == Self.indexVersion
        else {
            return LocalTokenUsageIndex()
        }
        return index
    }

    private func saveIndex(_ index: LocalTokenUsageIndex) throws {
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(index)
        try data.write(to: stateURL, options: .atomic)
    }

    private static let timestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

public enum LocalTokenUsageText {
    public static func compact(_ count: Int64) -> String {
        let value = Double(count)
        if count >= 100_000_000 {
            return "\(Int((value / 1_000_000).rounded()))M"
        }
        if count >= 10_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        }
        if count >= 10_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return "\(count)"
    }
}

private struct LocalTokenUsageIndex: Codable {
    var version = CodexLocalTokenUsageStore.indexVersion
    var files: [String: LocalTokenUsageFileState] = [:]
}

private struct LocalTokenUsageFileState: Codable, Equatable {
    var size: UInt64 = 0
    var modifiedAt: TimeInterval = 0
    var processedOffset: UInt64 = 0
    var days: [String: LocalTokenUsageBreakdown] = [:]
    var accountingState = LocalTokenUsageAccountingState()
}

private struct LocalTokenUsageFileScanResult {
    let days: [String: LocalTokenUsageBreakdown]
    let nextOffset: UInt64
    let bytesProcessed: UInt64
    let accountingState: LocalTokenUsageAccountingState
}

private enum LocalTokenUsageSessionLine {
    case sessionMeta(LocalTokenUsageSessionMetadata)
    case tokenCount(LocalTokenUsageTokenRecord)
}

private struct LocalTokenUsageSessionMetadata {
    let sessionID: String?
    let forkedFromID: String?
    let forkTimestampText: String?
}

private struct LocalTokenUsageTokenRecord {
    let timestamp: Date
    let timestampText: String
    let lastUsage: LocalTokenUsageBreakdown?
    let totalUsage: LocalTokenUsageBreakdown?
}

private struct LocalTokenUsageAccountingState: Codable, Equatable {
    var previousTotals: LocalTokenUsageBreakdown?
    var rawTotalsBaseline: LocalTokenUsageBreakdown?
    var inheritedTotals: LocalTokenUsageBreakdown?
    var remainingInheritedTotals: LocalTokenUsageBreakdown?
    var unresolvedForkTotalWatermark: LocalTokenUsageBreakdown?
    var forkBaselineResolved = false
    var hasUnresolvedForkBaseline = false
    var sawDivergentTotals = false

    mutating func resolveForkBaselineIfNeeded(
        metadata: LocalTokenUsageSessionMetadata,
        parentTotals: (String, String) -> LocalTokenUsageBreakdown?
    ) {
        guard !forkBaselineResolved,
              let parentSessionID = metadata.forkedFromID,
              let forkTimestampText = metadata.forkTimestampText
        else {
            return
        }

        forkBaselineResolved = true
        if let totals = parentTotals(parentSessionID, forkTimestampText) {
            inheritedTotals = totals
            remainingInheritedTotals = totals
            hasUnresolvedForkBaseline = false
        } else {
            hasUnresolvedForkBaseline = true
        }
    }

    mutating func apply(
        last rawLast: LocalTokenUsageBreakdown?,
        total rawTotal: LocalTokenUsageBreakdown?
    ) -> LocalTokenUsageBreakdown? {
        let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && rawTotal != nil
        if hasUnresolvedForkBaseline, let rawTotal {
            defer {
                unresolvedForkTotalWatermark = rawTotal
            }
            guard let rawLast, let watermark = unresolvedForkTotalWatermark else {
                return nil
            }

            let totalDelta = rawTotal.clampedDelta(from: watermark)
            let adjustedDelta = rawLast.clampedMin(totalDelta)
            previousTotals = (previousTotals ?? .zero).adding(adjustedDelta)
            rawTotalsBaseline = previousTotals
            return adjustedDelta.isZero ? nil : adjustedDelta
        }

        let delta: LocalTokenUsageBreakdown
        if !handledUnresolvedForkTotal,
           let rawTotal,
           inheritedTotals != nil,
           !hasUnresolvedForkBaseline
        {
            let currentTotals = currentTotals(from: rawTotal)
            delta = totalDelta(to: currentTotals)
            previousTotals = (previousTotals ?? .zero).adding(delta)
            rawTotalsBaseline = currentTotals
            if rawTotalsBaseline != previousTotals {
                sawDivergentTotals = true
            }
            remainingInheritedTotals = nil
        } else if !handledUnresolvedForkTotal, let rawLast {
            let hadRemainingInheritedTotals = remainingInheritedTotals != nil
            var adjustedDelta = adjustedLastDelta(rawLast)

            if let rawTotal, !hasUnresolvedForkBaseline {
                let currentTotals = currentTotals(from: rawTotal)
                let totalDelta = currentTotals.clampedDelta(from: rawTotalsBaseline)
                if !hadRemainingInheritedTotals,
                   shouldPreferTotalDelta(
                       currentTotal: currentTotals,
                       totalDelta: totalDelta,
                       lastDelta: rawLast
                   )
                {
                    adjustedDelta = totalDelta
                    remainingInheritedTotals = nil
                }
                previousTotals = (previousTotals ?? .zero).adding(adjustedDelta)
                rawTotalsBaseline = currentTotals
                if rawTotalsBaseline != previousTotals {
                    sawDivergentTotals = true
                }
            } else {
                previousTotals = (previousTotals ?? .zero).adding(adjustedDelta)
                rawTotalsBaseline = previousTotals
            }

            delta = adjustedDelta
        } else if !handledUnresolvedForkTotal, let rawTotal {
            let currentTotals = currentTotals(from: rawTotal)
            delta = totalDelta(to: currentTotals)
            previousTotals = (previousTotals ?? .zero).adding(delta)
            rawTotalsBaseline = currentTotals
            if rawTotalsBaseline != previousTotals {
                sawDivergentTotals = true
            }
            remainingInheritedTotals = nil
        } else {
            return nil
        }

        return delta.isZero ? nil : delta
    }

    private mutating func adjustedLastDelta(_ rawDelta: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        guard let remaining = remainingInheritedTotals else {
            return rawDelta
        }

        let adjusted = rawDelta.clampedSubtract(remaining)
        let nextRemaining = remaining.clampedSubtract(rawDelta)
        remainingInheritedTotals = nextRemaining.isZero ? nil : nextRemaining
        return adjusted
    }

    private func currentTotals(from rawTotal: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        if let inheritedTotals {
            return rawTotal.clampedSubtract(inheritedTotals)
        }
        return rawTotal
    }

    private func totalDelta(to currentTotals: LocalTokenUsageBreakdown) -> LocalTokenUsageBreakdown {
        if sawDivergentTotals, let rawTotalsBaseline, let previousTotals {
            let rawDelta = currentTotals.clampedDelta(from: rawTotalsBaseline)
            let countedDelta = currentTotals.clampedDelta(from: previousTotals)
            return LocalTokenUsageBreakdown(
                inputTokens: currentTotals.inputTokens >= rawTotalsBaseline.inputTokens ? rawDelta.inputTokens : countedDelta.inputTokens,
                cachedInputTokens: currentTotals.cachedInputTokens >= rawTotalsBaseline.cachedInputTokens ? rawDelta.cachedInputTokens : countedDelta.cachedInputTokens,
                outputTokens: currentTotals.outputTokens >= rawTotalsBaseline.outputTokens ? rawDelta.outputTokens : countedDelta.outputTokens,
                reasoningOutputTokens: currentTotals.reasoningOutputTokens >= rawTotalsBaseline.reasoningOutputTokens ? rawDelta.reasoningOutputTokens : countedDelta.reasoningOutputTokens,
                totalTokens: currentTotals.totalTokens >= rawTotalsBaseline.totalTokens ? rawDelta.totalTokens : countedDelta.totalTokens
            )
        }
        return currentTotals.clampedDelta(from: rawTotalsBaseline)
    }

    private func shouldPreferTotalDelta(
        currentTotal: LocalTokenUsageBreakdown,
        totalDelta: LocalTokenUsageBreakdown,
        lastDelta: LocalTokenUsageBreakdown
    ) -> Bool {
        guard !sawDivergentTotals, let rawTotalsBaseline else {
            return false
        }
        return currentTotal.isAtLeast(rawTotalsBaseline) && totalDelta.isAtMost(lastDelta)
    }
}
