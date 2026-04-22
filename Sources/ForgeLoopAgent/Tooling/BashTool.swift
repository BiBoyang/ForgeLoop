import Foundation
import ForgeLoopAI

public struct BashTool: Tool {
    public let name = "bash"
    public let defaultTimeoutMs: Int

    public init(defaultTimeoutMs: Int = 15_000) {
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        guard let args = parseArgs(arguments), let command = args["command"] else {
            return ToolResult.error(.missingArgument, message: "Missing required argument: command")
        }

        let timeoutMs = args["timeoutMs"].flatMap(Int.init) ?? defaultTimeoutMs

        let result = await ProcessRunner.run(
            command: command,
            cwd: cwd,
            timeoutMs: timeoutMs,
            cancellation: cancellation
        )

        if cancellation?.isCancelled == true {
            return ToolResult.error(.cancelled, message: "Command aborted")
        }

        if result.timedOut {
            return ToolResult.error(.timeout, message: "Command timed out after \(timeoutMs)ms")
        }

        var output = ""
        if !result.stdout.isEmpty {
            output += result.stdout
        }
        if !result.stderr.isEmpty {
            if !output.isEmpty {
                output += "\n"
            }
            output += "[stderr]\n" + result.stderr
        }

        let isError = result.exitCode != 0
        if output.isEmpty {
            output = isError ? "Exit code: \(result.exitCode)" : "(no output)"
        }

        return ToolResult(output: output, isError: isError, errorCode: isError ? .executionFailed : nil)
    }
}

private func parseBashArgs(_ json: String) -> [String: String]? {
    guard let data = json.data(using: .utf8) else { return nil }
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    var result: [String: String] = [:]
    for (key, value) in dict {
        if let str = value as? String {
            result[key] = str
        } else if let num = value as? NSNumber {
            result[key] = num.stringValue
        } else if let bool = value as? Bool {
            result[key] = bool ? "true" : "false"
        }
    }
    return result
}
