import Foundation

/// Formats log entries as single-line JSON objects.
public struct JSONLogFormatter: Sendable {
    public init() {}

    /// Produce a single-line JSON string for the given log entry.
    public func format(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute],
        timestamp: Date
    ) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let entry = LogEntry(
            timestamp: dateFormatter.string(from: timestamp),
            level: level.jsonValue,
            message: message,
            attributes: attributes.jsonDictionary
        )

        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed_to_encode_log_entry\"}"
        }
        return line
    }
}

private struct LogEntry: Encodable {
    let timestamp: String
    let level: String
    let message: String
    let attributes: [String: LogAttributeValue]
}

private enum LogAttributeValue: Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        }
    }
}

extension TraceAttribute {
    fileprivate var logValue: LogAttributeValue {
        switch self {
        case .string(let value), .masked(let value):
            return .string(value)
        case .int(let value):
            return .int(value)
        case .bool(let value):
            return .bool(value)
        case .double(let value):
            return .double(value)
        }
    }
}

extension Dictionary where Key == String, Value == TraceAttribute {
    fileprivate var jsonDictionary: [String: LogAttributeValue] {
        mapValues { $0.logValue }
    }
}

extension TraceLevel {
    fileprivate var jsonValue: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}
