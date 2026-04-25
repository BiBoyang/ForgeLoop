import Foundation
import ForgeLoopAI

public struct AttachmentID: Sendable, Hashable {
    public let value: String

    public init() {
        self.value = UUID().uuidString
    }

    public init(_ value: String) {
        self.value = value
    }
}

public enum AttachmentKind: Sendable, Equatable {
    case text(String)
    case filePath(String)
}

public struct AttachmentRecord: Sendable, Identifiable, Equatable {
    public let id: AttachmentID
    public let kind: AttachmentKind

    public init(id: AttachmentID = AttachmentID(), kind: AttachmentKind) {
        self.id = id
        self.kind = kind
    }

    public var displayPreview: String {
        switch kind {
        case .text(let content):
            let normalized = content
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let trimmed = normalized.trimmingCharacters(in: .whitespaces)
            let preview = trimmed.count > 40 ? String(trimmed.prefix(40)) + "..." : trimmed
            return "[text] \(preview)"
        case .filePath(let path):
            return "[file] \(path)"
        }
    }
}

@MainActor
public final class AttachmentStore: @unchecked Sendable {
    private var _records: [AttachmentRecord] = []
    private let lock = NSLock()

    public init() {}

    public var records: [AttachmentRecord] {
        lock.withLock { _records }
    }

    public var isEmpty: Bool {
        lock.withLock { _records.isEmpty }
    }

    public var count: Int {
        lock.withLock { _records.count }
    }

    @discardableResult
    public func addText(_ text: String) -> AttachmentRecord {
        let record = AttachmentRecord(kind: .text(text))
        lock.withLock { _records.append(record) }
        return record
    }

    @discardableResult
    public func addFilePath(_ path: String) -> AttachmentRecord {
        let record = AttachmentRecord(kind: .filePath(path))
        lock.withLock { _records.append(record) }
        return record
    }

    public func list() -> [AttachmentRecord] {
        lock.withLock { Array(_records) }
    }

    @discardableResult
    public func remove(id: AttachmentID) -> Bool {
        lock.withLock {
            guard let index = _records.firstIndex(where: { $0.id == id }) else {
                return false
            }
            _records.remove(at: index)
            return true
        }
    }

    @discardableResult
    public func remove(at index: Int) -> Bool {
        lock.withLock {
            guard _records.indices.contains(index) else { return false }
            _records.remove(at: index)
            return true
        }
    }

    public func clear() {
        lock.withLock { _records.removeAll() }
    }

    public func snapshot() -> [AttachmentRecord] {
        lock.withLock { Array(_records) }
    }
}

// MARK: - Prompt Injection

public func injectAttachments(into text: String, attachments: [AttachmentRecord]) -> String {
    guard !attachments.isEmpty else { return text }

    var parts: [String] = []
    for attachment in attachments {
        switch attachment.kind {
        case .text(let content):
            parts.append(content)
        case .filePath(let path):
            parts.append("[Attached file: \(path)]")
        }
    }
    if !text.isEmpty {
        parts.append(text)
    }
    return parts.joined(separator: "\n\n")
}
