import Foundation
import ForgeLoopCli
import ForgeLoopDiagnostics
import ForgeLoopEval

@main
struct ForgeLoopCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        // Parse flags and subcommand
        var overrideModel: String?
        var traceLevel: String?
        var traceFile: String?
        var remainingArgs: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--model", i + 1 < args.count {
                overrideModel = args[i + 1]
                i += 2
            } else if args[i] == "--trace-level", i + 1 < args.count {
                traceLevel = args[i + 1]
                i += 2
            } else if args[i] == "--trace-file", i + 1 < args.count {
                traceFile = args[i + 1]
                i += 2
            } else {
                remainingArgs.append(args[i])
                i += 1
            }
        }

        let diagnostics = makeDiagnostics(
            traceLevel: traceLevel ?? ProcessInfo.processInfo.environment["FORGELOOP_TRACE_LEVEL"],
            traceFile: traceFile ?? ProcessInfo.processInfo.environment["FORGELOOP_TRACE_FILE"]
        )

        let subcommand = remainingArgs.first

        switch subcommand {
        case nil:
            let cliModel = overrideModel
            await runOrExit {
                try await ForgeLoop.runCodingTUI(modelOverride: cliModel, diagnostics: diagnostics)
            }
        case "login":
            await runOrExit {
                try await ForgeLoop.runLogin()
            }
        case "eval":
            let evalArgs = Array(remainingArgs.dropFirst())
            do {
                let success = try await EvalCommand().run(
                    arguments: evalArgs,
                    diagnostics: diagnostics
                )
                if !success {
                    Foundation.exit(1)
                }
            } catch {
                FileHandle.standardError.write(Data("forgeloop eval: \(error)\n".utf8))
                Foundation.exit(1)
            }
        case "-h", "--help":
            printUsage()
        default:
            let unknown = subcommand ?? ""
            FileHandle.standardError.write(Data("forgeloop: unknown subcommand '\(unknown)'\n".utf8))
            printUsage()
            Foundation.exit(2)
        }
    }

    static func runOrExit(_ body: @escaping @Sendable () async throws -> Void) async {
        do {
            try await body()
        } catch {
            FileHandle.standardError.write(Data("forgeloop: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func printUsage() {
        print("""
        forgeloop replica

        usage:
          forgeloop [--model <id>] [--trace-level <level>] [--trace-file <path>]  launch coding tui scaffold
          forgeloop login                                                          save API key to credentials
          forgeloop eval [--suite <name>] [--provider <name>] [--format <format>] [--output <path>]  run benchmark suite
          forgeloop --help                                                         show help

        trace options:
          --trace-level debug|info|warn|error    enable trace/log output at the given level
          --trace-file <path>                    write trace/log output to a file (default: stderr)
          FORGELOOP_TRACE_LEVEL                  environment variable equivalent to --trace-level
          FORGELOOP_TRACE_FILE                   environment variable equivalent to --trace-file

        tip:
          type /exit in TUI to quit
        """)
    }

    static func makeDiagnostics(traceLevel: String?, traceFile: String?) -> Diagnostics {
        guard let traceLevel else { return Diagnostics() }
        let level: TraceLevel
        switch traceLevel.lowercased() {
        case "debug": level = .debug
        case "info": level = .info
        case "warn", "warning": level = .warn
        case "error": level = .error
        default: level = .debug
        }

        let sink: LogSystem
        if let traceFile {
            sink = FileLogSink(fileURL: URL(fileURLWithPath: traceFile))
        } else {
            sink = ConsoleLogSink()
        }
        let log = LevelFilteringLogSink(minimumLevel: level, sink: sink)

        return Diagnostics(
            trace: LoggingTraceSystem(log: log),
            log: log
        )
    }
}

private struct LevelFilteringLogSink: LogSystem {
    private let minimumLevel: TraceLevel
    private let sink: LogSystem

    init(minimumLevel: TraceLevel, sink: LogSystem) {
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async {
        guard levelOrder(level) >= levelOrder(minimumLevel) else { return }
        await sink.log(level: level, message: message, attributes: attributes)
    }

    private func levelOrder(_ level: TraceLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}
