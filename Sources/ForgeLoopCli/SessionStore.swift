import Foundation
import ForgeLoopAI

public struct SessionRecord: Codable {
    public var modelID: String
    public var messages: [Message]
    public var savedAt: Date
    public var messageCount: Int
}

public enum SessionStoreError: Error, CustomStringConvertible {
    case invalidName(String)

    public var description: String {
        switch self {
        case .invalidName(let reason):
            return "Invalid session name: \(reason)"
        }
    }
}

public struct SessionStore: Sendable {
    private let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/forgeloop/sessions", isDirectory: true)
    }

    public func sessionsDirectory() -> URL {
        directoryURL
    }

    /// 校验 session 名：只允许 A-Z a-z 0-9 _ -，且不能以 . 开头，不能包含路径分隔符。
    private func validateSessionName(_ name: String) throws {
        guard !name.isEmpty else {
            throw SessionStoreError.invalidName("name must not be empty")
        }
        guard !name.hasPrefix(".") else {
            throw SessionStoreError.invalidName("name must not start with '.'")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard name.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw SessionStoreError.invalidName("name may only contain letters, digits, '_' or '-'")
        }
    }

    private func fileURL(for name: String) throws -> URL {
        try validateSessionName(name)
        return sessionsDirectory().appendingPathComponent("\(name).json")
    }

    public func save(name: String, modelID: String, messages: [Message]) throws {
        let fileURL = try fileURL(for: name)
        let directory = fileURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let record = SessionRecord(
            modelID: modelID,
            messages: messages,
            savedAt: Date(),
            messageCount: messages.count
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(record)

        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func load(name: String) throws -> SessionRecord? {
        let fileURL = try fileURL(for: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SessionRecord.self, from: data)
    }

    public func list() throws -> [String] {
        let directory = sessionsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    @discardableResult
    public func delete(name: String) throws -> Bool {
        let fileURL = try fileURL(for: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        try FileManager.default.removeItem(at: fileURL)
        return true
    }
}
