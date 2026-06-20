import Foundation

/// An assertion checked against the workspace after an eval case runs.
public enum EvalAssertion: Sendable, Codable, Equatable {
    /// File content contains the given substring.
    case fileContains(path: String, substring: String)
    /// File content does not contain the given substring.
    case fileNotContains(path: String, substring: String)
    /// File content equals the expected string exactly.
    case fileEquals(path: String, expected: String)
    /// File exists at the given path.
    case fileExists(path: String)
    /// Command exits with status code 0.
    case commandSucceeds(command: [String])
    /// Command output contains the given substring.
    case commandOutputContains(command: [String], substring: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case substring
        case expected
        case command
    }

    private enum Kind: String, Codable {
        case fileContains
        case fileNotContains
        case fileEquals
        case fileExists
        case commandSucceeds
        case commandOutputContains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fileContains:
            let path = try container.decode(String.self, forKey: .path)
            let substring = try container.decode(String.self, forKey: .substring)
            self = .fileContains(path: path, substring: substring)
        case .fileNotContains:
            let path = try container.decode(String.self, forKey: .path)
            let substring = try container.decode(String.self, forKey: .substring)
            self = .fileNotContains(path: path, substring: substring)
        case .fileEquals:
            let path = try container.decode(String.self, forKey: .path)
            let expected = try container.decode(String.self, forKey: .expected)
            self = .fileEquals(path: path, expected: expected)
        case .fileExists:
            let path = try container.decode(String.self, forKey: .path)
            self = .fileExists(path: path)
        case .commandSucceeds:
            let command = try container.decode([String].self, forKey: .command)
            self = .commandSucceeds(command: command)
        case .commandOutputContains:
            let command = try container.decode([String].self, forKey: .command)
            let substring = try container.decode(String.self, forKey: .substring)
            self = .commandOutputContains(command: command, substring: substring)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fileContains(let path, let substring):
            try container.encode(Kind.fileContains, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(substring, forKey: .substring)
        case .fileNotContains(let path, let substring):
            try container.encode(Kind.fileNotContains, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(substring, forKey: .substring)
        case .fileEquals(let path, let expected):
            try container.encode(Kind.fileEquals, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(expected, forKey: .expected)
        case .fileExists(let path):
            try container.encode(Kind.fileExists, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .commandSucceeds(let command):
            try container.encode(Kind.commandSucceeds, forKey: .kind)
            try container.encode(command, forKey: .command)
        case .commandOutputContains(let command, let substring):
            try container.encode(Kind.commandOutputContains, forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encode(substring, forKey: .substring)
        }
    }
}
