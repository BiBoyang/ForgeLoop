import Foundation

public struct SSEMessage: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// SSE parser implemented as a value type.
///
/// Because `SSEParser` is a `struct`, each call site owns its own mutable copy.
/// All mutation happens through `mutating` methods, making the type naturally
/// `Sendable` without requiring `@unchecked` or external synchronization.
public struct SSEParser: Sendable {
    private var lineBuffer = ""
    private var event = "message"
    private var dataLines: [String] = []
    private var id: String?
    private var pending: [SSEMessage] = []

    public init() {}

    public mutating func ingest(bytes: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { return }
        ingest(text)
    }

    public mutating func ingest(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            var line = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line)
        }
    }

    public mutating func drain() -> [SSEMessage] {
        let out = pending
        pending.removeAll()
        return out
    }

    public mutating func finish() -> [SSEMessage] {
        if !lineBuffer.isEmpty {
            var trailing = lineBuffer
            lineBuffer.removeAll()
            if trailing.hasSuffix("\r") { trailing.removeLast() }
            handle(line: trailing)
        }

        if !dataLines.isEmpty || event != "message" {
            pending.append(SSEMessage(event: event, data: dataLines.joined(separator: "\n"), id: id))
            event = "message"
            dataLines.removeAll()
            id = nil
        }
        return drain()
    }

    private mutating func handle(line: String) {
        if line.isEmpty {
            if !dataLines.isEmpty || event != "message" {
                pending.append(SSEMessage(event: event, data: dataLines.joined(separator: "\n"), id: id))
            }
            event = "message"
            dataLines.removeAll()
            id = nil
            return
        }

        if line.hasPrefix(":") { return }
        guard let colon = line.firstIndex(of: ":") else { return }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        case "id": id = value
        default: break
        }
    }
}
