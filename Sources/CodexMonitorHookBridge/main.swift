import CodexMonitorCore
import Darwin
import Foundation

let input = readHookInput()
guard !input.isEmpty else {
    exit(0)
}

do {
    let event = try CodexHookEventParser.parse(input)
    try CodexHookSocketClient.send(event)
} catch {
    exit(0)
}

private func readHookInput(maxBytes: Int = 1024 * 1024) -> Data {
    var data = Data()
    var byte: UInt8 = 0

    while data.count < maxBytes {
        let count = read(STDIN_FILENO, &byte, 1)
        if count <= 0 {
            break
        }
        data.append(byte)
        if byte == 0x0A {
            break
        }
    }

    return data
}
