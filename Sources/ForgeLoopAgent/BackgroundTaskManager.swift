import Foundation
import ForgeLoopAI

/// Error thrown when a background task cannot be started.
public enum BackgroundTaskStartError: Error, Sendable {
    /// The configured maximum number of concurrent background tasks has been reached.
    case maxConcurrentReached(limit: Int)
}

public enum BackgroundTaskStatus: String, Sendable {
    case running
    case success
    case failed
    case cancelled
}

public struct BackgroundTaskRecord: Sendable {
    public let id: String
    public let command: String
    public let startedAt: Date
    public var status: BackgroundTaskStatus
    public var finishedAt: Date?
    public var output: String
    public var exitCode: Int32?
    public var cancelledBy: String?

    public init(
        id: String,
        command: String,
        startedAt: Date,
        status: BackgroundTaskStatus,
        finishedAt: Date? = nil,
        output: String = "",
        exitCode: Int32? = nil,
        cancelledBy: String? = nil
    ) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
        self.status = status
        self.finishedAt = finishedAt
        self.output = output
        self.exitCode = exitCode
        self.cancelledBy = cancelledBy
    }
}

public actor BackgroundTaskManager {
    /// Default lifetime for a background task (5 minutes).
    public static let defaultTimeoutMs = 300_000

    private var tasks: [String: BackgroundTaskRecord] = [:]
    private var handles: [String: CancellationHandle] = [:]
    private var activeCount: Int = 0
    private var completionHandler: (@Sendable (BackgroundTaskRecord) async -> Void)?

    /// Maximum number of tasks allowed to run at the same time.
    public let maxConcurrent: Int
    /// Maximum number of completed/running records to retain. Oldest completed records are pruned first.
    public let maxRetained: Int

    public init(maxConcurrent: Int = 8, maxRetained: Int = 50) {
        self.maxConcurrent = max(maxConcurrent, 1)
        self.maxRetained = max(maxRetained, 1)
    }

    public func setCompletionHandler(_ handler: @escaping @Sendable (BackgroundTaskRecord) async -> Void) {
        completionHandler = handler
    }

    @discardableResult
    public func start(command: String, cwd: String, timeoutMs: Int? = nil) throws -> String {
        guard activeCount < maxConcurrent else {
            throw BackgroundTaskStartError.maxConcurrentReached(limit: maxConcurrent)
        }

        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let cancellation = CancellationHandle()
        let record = BackgroundTaskRecord(
            id: id,
            command: command,
            startedAt: Date(),
            status: .running
        )
        tasks[id] = record
        handles[id] = cancellation
        activeCount += 1

        let effectiveTimeout = timeoutMs ?? Self.defaultTimeoutMs

        Task {
            let result = await ProcessRunner.run(
                command: command,
                cwd: cwd,
                timeoutMs: effectiveTimeout,
                cancellation: cancellation
            )

            // If the task was already cancelled, leave its record untouched and avoid double-decrementing.
            guard let current = tasks[id], current.status == .running else { return }

            var updated = record
            if result.timedOut {
                updated.status = .failed
                updated.exitCode = result.exitCode
            } else {
                updated.status = result.exitCode == 0 ? .success : .failed
                updated.exitCode = result.exitCode
            }
            updated.finishedAt = Date()

            var output = ""
            if result.timedOut {
                output += "[timeout] Command timed out after \(effectiveTimeout)ms"
            }
            if !result.stdout.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stdout
            }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += "[stderr]\n" + result.stderr
            }
            updated.output = output

            tasks[id] = updated
            handles.removeValue(forKey: id)
            activeCount -= 1
            pruneRetainedTasks()
            await completionHandler?(updated)
        }

        return id
    }

    /// Removes oldest completed records while keeping the completed count within `maxRetained`.
    /// Running records are never removed. Oldest is determined by `finishedAt` (falling back to
    /// `startedAt`), with id ordering as a stable tie-breaker.
    private func pruneRetainedTasks() {
        let completed = tasks.values.filter { $0.status != .running }
        guard completed.count > maxRetained else { return }

        let sorted = completed.sorted {
            let lhs = $0.finishedAt ?? $0.startedAt
            let rhs = $1.finishedAt ?? $1.startedAt
            if lhs == rhs { return $0.id < $1.id }
            return lhs < rhs
        }
        for record in sorted.prefix(sorted.count - maxRetained) {
            tasks.removeValue(forKey: record.id)
        }
    }

    public func status(id: String? = nil) -> [BackgroundTaskRecord] {
        if let id = id {
            return tasks[id].map { [$0] } ?? []
        }
        return tasks.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func cancel(id: String, by source: String = "user") {
        guard let handle = handles.removeValue(forKey: id),
              var task = tasks[id], task.status == .running else { return }

        handle.cancel(reason: "cancelled by \(source)")
        task.status = .cancelled
        task.finishedAt = Date()
        task.cancelledBy = source
        tasks[id] = task
        activeCount -= 1
        pruneRetainedTasks()
    }

    @discardableResult
    public func cancelAll(by source: String = "user") -> Int {
        let runningIDs = tasks.values
            .filter { $0.status == .running }
            .map(\.id)

        for id in runningIDs {
            cancel(id: id, by: source)
        }
        return runningIDs.count
    }

    public func allTaskIDs() -> [String] {
        Array(tasks.keys).sorted()
    }
}
