import Foundation

/// A `LogSystem` that writes formatted log lines to a file with rotation.
///
/// `FileLogSink` is an actor so all file operations are serialized. File I/O
/// errors are swallowed internally to prevent diagnostic failures from
/// propagating into the main application flow.
public actor FileLogSink: LogSystem {
    private let fileURL: URL
    private let maxFileSize: Int
    private let maxFiles: Int
    private let formatter: JSONLogFormatter

    public init(
        fileURL: URL,
        maxFileSize: Int = 10 * 1024 * 1024,
        maxFiles: Int = 3,
        formatter: JSONLogFormatter = JSONLogFormatter()
    ) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
        self.maxFiles = maxFiles
        self.formatter = formatter
    }

    public func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) {
        let line = formatter.format(
            level: level,
            message: message,
            attributes: attributes,
            timestamp: Date()
        )

        do {
            try ensureDirectoryExists()
            try rotateIfNeeded()
            try append(line: line)
        } catch {
            // Swallow file I/O errors to keep diagnostics from breaking
            // the main flow.
        }
    }

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func rotateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = attributes[.size] as? Int ?? 0
        guard size >= maxFileSize else { return }

        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.lastPathComponent

        // Delete the oldest backup if it exists.
        let oldest = directory.appendingPathComponent("\(baseName).\(maxFiles)")
        if FileManager.default.fileExists(atPath: oldest.path) {
            try? FileManager.default.removeItem(at: oldest)
        }

        // Shift existing backups up by one index.
        for index in (1..<maxFiles).reversed() {
            let source = directory.appendingPathComponent("\(baseName).\(index)")
            let destination = directory.appendingPathComponent("\(baseName).\(index + 1)")
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        }

        // Move the current log to .1 and start fresh.
        let firstBackup = directory.appendingPathComponent("\(baseName).1")
        try? FileManager.default.moveItem(at: fileURL, to: firstBackup)
    }

    private func append(line: String) throws {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL)
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}
