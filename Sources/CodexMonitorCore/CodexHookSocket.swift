import Darwin
import Foundation

public enum CodexHookSocketError: LocalizedError {
    case pathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "Unix socket path is too long: \(path)"
        case .socketFailed(let code):
            "Unable to create Unix socket: \(String(cString: strerror(code)))"
        case .bindFailed(let code):
            "Unable to bind Unix socket: \(String(cString: strerror(code)))"
        case .listenFailed(let code):
            "Unable to listen on Unix socket: \(String(cString: strerror(code)))"
        case .connectFailed(let code):
            "Unable to connect Unix socket: \(String(cString: strerror(code)))"
        case .writeFailed(let code):
            "Unable to write Unix socket: \(String(cString: strerror(code)))"
        }
    }
}

public enum CodexHookSocketClient {
    public static func send(_ event: CodexHookEvent, path: String = CodexHookSocket.path()) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CodexHookSocketError.socketFailed(errno)
        }
        defer {
            close(descriptor)
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        try withSocketAddress(path: path) { address, length in
            guard connect(descriptor, address, length) == 0 else {
                throw CodexHookSocketError.connectFailed(errno)
            }
        }

        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var written = 0
            while written < buffer.count {
                let count = write(descriptor, baseAddress.advanced(by: written), buffer.count - written)
                guard count > 0 else {
                    throw CodexHookSocketError.writeFailed(errno)
                }
                written += count
            }
        }
    }
}

public final class CodexHookSocketServer {
    private let path: String
    private let queue = DispatchQueue(label: "CodexHookSocketServer")
    private let handler: (CodexHookEvent) -> Void
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = CodexHookSocket.path(), handler: @escaping (CodexHookEvent) -> Void) {
        self.path = path
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stop()
        unlink(path)

        let createdDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard createdDescriptor >= 0 else {
            throw CodexHookSocketError.socketFailed(errno)
        }

        do {
            try setNonBlocking(createdDescriptor)
            try withSocketAddress(path: path) { address, length in
                guard bind(createdDescriptor, address, length) == 0 else {
                    throw CodexHookSocketError.bindFailed(errno)
                }
            }
            guard listen(createdDescriptor, 16) == 0 else {
                throw CodexHookSocketError.listenFailed(errno)
            }
        } catch {
            close(createdDescriptor)
            throw error
        }

        descriptor = createdDescriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: createdDescriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        readSource.setCancelHandler { [path] in
            close(createdDescriptor)
            unlink(path)
        }
        source = readSource
        readSource.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func acceptConnections() {
        while true {
            let clientDescriptor = accept(descriptor, nil, nil)
            guard clientDescriptor >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            try? setBlocking(clientDescriptor)
            readEvent(from: clientDescriptor)
            close(clientDescriptor)
        }
    }

    private func readEvent(from clientDescriptor: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(clientDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) {
                    break
                }
                continue
            }
            break
        }

        let lines = data.split(separator: 0x0A)
        for line in lines {
            guard let event = try? JSONDecoder().decode(CodexHookEvent.self, from: Data(line)) else {
                continue
            }
            handler(event)
        }
    }
}

private func withSocketAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < maxPathLength else {
        throw CodexHookSocketError.pathTooLong(path)
    }

    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
            for index in 0..<pathBytes.count {
                destination[index] = CChar(bitPattern: pathBytes[index])
            }
            destination[pathBytes.count] = 0
        }
    }

    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else {
        throw CodexHookSocketError.socketFailed(errno)
    }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw CodexHookSocketError.socketFailed(errno)
    }
}

private func setBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else {
        throw CodexHookSocketError.socketFailed(errno)
    }
    guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
        throw CodexHookSocketError.socketFailed(errno)
    }
}
