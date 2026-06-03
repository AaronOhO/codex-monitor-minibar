import Foundation

public enum CodexRateLimitClientError: LocalizedError {
    case executableMissing(String)
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            "Codex executable not found at \(path)"
        case .startFailed(let message):
            "Codex app-server failed to start: \(message)"
        case .requestFailed(let message):
            "Codex app-server request failed: \(message)"
        case .malformed(let message):
            "Codex app-server returned invalid data: \(message)"
        case .timeout(let method):
            "Codex app-server timed out waiting for \(method)"
        }
    }
}

public struct CodexRateLimitClient {
    private let codexExecutablePath: String
    private let controlSocketPath: String
    private let timeoutSeconds: TimeInterval

    public init(
        codexExecutablePath: String = "/Applications/Codex.app/Contents/Resources/codex",
        controlSocketPath: String = "\(NSHomeDirectory())/.codex/app-server-control/app-server-control.sock",
        timeoutSeconds: TimeInterval = 6
    ) {
        self.codexExecutablePath = codexExecutablePath
        self.controlSocketPath = controlSocketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func readRateLimits() async throws -> RateLimitSnapshot {
        let shouldTryControlSocket = FileManager.default.fileExists(atPath: controlSocketPath)
        do {
            return try await readRateLimits(useControlSocket: shouldTryControlSocket)
        } catch {
            guard shouldTryControlSocket else {
                throw error
            }
            return try await readRateLimits(useControlSocket: false)
        }
    }

    private func readRateLimits(useControlSocket: Bool) async throws -> RateLimitSnapshot {
        let rpc = try CodexAppServerRPC(
            codexExecutablePath: codexExecutablePath,
            controlSocketPath: controlSocketPath,
            useControlSocket: useControlSocket,
            timeoutSeconds: timeoutSeconds
        )
        defer {
            rpc.shutdown()
        }

        try await rpc.initialize()
        let response = try await rpc.request(method: "account/rateLimits/read")
        return try RateLimitParser.parse(jsonRPCResponse: response)
    }
}

private final class CodexAppServerRPC {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stderrLock = NSLock()
    private var stderrText = ""
    private var nextID = 1
    private let timeoutSeconds: TimeInterval

    init(
        codexExecutablePath: String,
        controlSocketPath: String,
        useControlSocket: Bool,
        timeoutSeconds: TimeInterval
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: codexExecutablePath) else {
            throw CodexRateLimitClientError.executableMissing(codexExecutablePath)
        }

        self.timeoutSeconds = timeoutSeconds

        process.executableURL = URL(fileURLWithPath: codexExecutablePath)
        if useControlSocket {
            process.arguments = ["app-server", "proxy", "--sock", controlSocketPath]
        } else {
            process.arguments = ["app-server", "--listen", "stdio://"]
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_MONITOR_MINIBAR"] = "1"
        process.environment = environment

        installStderrReader()

        do {
            try process.run()
        } catch {
            throw CodexRateLimitClientError.startFailed(error.localizedDescription)
        }
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "CodexMonitorMinibar",
                    "version": "0.1.3"
                ]
            ],
            timeoutSeconds: max(timeoutSeconds, 10)
        )
        try sendNotification(method: "initialized")
    }

    func request(method: String, params: Any = NSNull(), timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        let id = nextID
        nextID += 1
        try sendPayload([
            "id": id,
            "method": method,
            "params": params
        ])

        return try await withTimeout(seconds: timeoutSeconds ?? self.timeoutSeconds, method: method) {
            while let line = self.readStdoutLine() {
                guard !line.isEmpty else {
                    continue
                }
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if message["id"] == nil {
                    continue
                }
                guard self.jsonID(message["id"]) == id else {
                    continue
                }
                if let error = message["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw CodexRateLimitClientError.requestFailed(message)
                }
                return line
            }
            let stderr = self.collectedStderr()
            if stderr.isEmpty {
                throw CodexRateLimitClientError.malformed("stdout closed")
            }
            throw CodexRateLimitClientError.malformed("stdout closed: \(stderr)")
        }
    }

    func shutdown() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func installStderrReader() {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
    }

    private func readStdoutLine() -> Data? {
        var line = Data()
        while true {
            let byte = stdoutPipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty {
                return line.isEmpty ? nil : line
            }
            if byte[0] == 0x0A {
                return line
            }
            line.append(byte)
        }
    }

    private func sendNotification(method: String) throws {
        try sendPayload([
            "method": method,
            "params": [:]
        ])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        method: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                self.shutdown()
                throw CodexRateLimitClientError.timeout(method)
            }

            guard let result = try await group.next() else {
                throw CodexRateLimitClientError.timeout(method)
            }
            group.cancelAll()
            return result
        }
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let number as NSNumber:
            number.intValue
        default:
            nil
        }
    }

    private func appendStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return
        }
        stderrLock.lock()
        defer {
            stderrLock.unlock()
        }

        stderrText += text
        if stderrText.count > 2_000 {
            stderrText = String(stderrText.suffix(2_000))
        }
    }

    private func collectedStderr() -> String {
        stderrLock.lock()
        defer {
            stderrLock.unlock()
        }

        return stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
