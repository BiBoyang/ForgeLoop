import Foundation
import ForgeLoopAI

public final class ModelStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configDir = home.appendingPathComponent(".config/forgeloop", isDirectory: true)
            self.fileURL = configDir.appendingPathComponent("model.json")
        }
    }

    public func load() -> Model? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Model.self, from: data)
    }

    public func save(_ model: Model) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(model) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
