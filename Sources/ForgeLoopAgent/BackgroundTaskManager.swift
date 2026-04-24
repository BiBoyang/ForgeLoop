import Foundation
import ForgeLoopAI

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
    private var tasks: [String: BackgroundTaskRecord] = [:]
    private var handles: [String: CancellationHandle] = [:]
    private var completionHandler: (@Sendable (BackgroundTaskRecord) async -> Void)?

    public init() {}

    public func setCompletionHandler(_ handler: @escaping @Sendable (BackgroundTaskRecord) async -> Void) {
        completionHandler = handler
    }

    @discardableResult
    public func start(command: String, cwd: String) -> String {
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

        Task {
            let result = await ProcessRunner.run(
                command: command,
                cwd: cwd,
                timeoutMs: nil,
                cancellation: cancellation
            )

            // 如果已被取消，不覆盖状态（防止竞争）
            guard let current = tasks[id], current.status == .running else { return }

            var updated = record
            updated.status = result.exitCode == 0 ? .success : .failed
            updated.finishedAt = Date()
            updated.exitCode = result.exitCode

            var output = ""
            if !result.stdout.isEmpty {
                output += result.stdout
            }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += "[stderr]\n" + result.stderr
            }
            updated.output = output

            tasks[id] = updated
            handles.removeValue(forKey: id)
            await completionHandler?(updated)
        }

        return id
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
