import Foundation
import ForgeLoopAI

public struct SessionRecord: Codable {
    public var modelID: String
    public var messages: [Message]
    public var savedAt: Date
    public var messageCount: Int
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

    public func save(name: String, modelID: String, messages: [Message]) throws {
        let directory = sessionsDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
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

        let fileURL = directory.appendingPathComponent("\(name).json")
        try data.write(to: fileURL)
    }

    public func load(name: String) throws -> SessionRecord? {
        let fileURL = sessionsDirectory().appendingPathComponent("\(name).json")
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
        let fileURL = sessionsDirectory().appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        try FileManager.default.removeItem(at: fileURL)
        return true
    }
}
