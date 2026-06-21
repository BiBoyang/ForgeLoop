import Foundation
import ForgeLoopDiagnostics

/// Errors thrown by `EvalCommand` while parsing arguments or producing a report.
public enum EvalCommandError: Error, LocalizedError {
    case missingValue(String)
    case unknownArgument(String)
    case unknownSuite(String)
    case unknownFormat(String)
    case missingOutputDirectory
    case writeFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .unknownArgument(let arg):
            return "Unknown argument: \(arg)"
        case .unknownSuite(let name):
            return "Unknown benchmark suite: \(name)"
        case .unknownFormat(let format):
            return "Unknown output format: \(format). Use 'json' or 'markdown'."
        case .missingOutputDirectory:
            return "Output directory does not exist"
        case .writeFailed(let error):
            return "Failed to write report: \(error.localizedDescription)"
        }
    }
}

/// Runs a benchmark suite from the command line and renders a report.
///
/// By default the command uses the built-in `FauxProvider` so that running the
/// suite does not incur real LLM costs. Pass `--provider <name>` to use a
/// registered provider.
public struct EvalCommand: Sendable {
    public init() {}

    /// Parse `arguments` and run the requested suite.
    ///
    /// - Returns: `true` if every case in the suite passed.
    /// - Throws: `EvalCommandError` for invalid arguments or report I/O issues.
    public func run(
        arguments: [String],
        diagnostics: Diagnostics = Diagnostics()
    ) async throws -> Bool {
        let options = try parse(arguments)

        if options.helpRequested {
            print(Self.helpText)
            return true
        }

        return try await run(
            suiteName: options.suiteName,
            providerName: options.providerName,
            format: options.format,
            outputPath: options.outputPath,
            diagnostics: diagnostics
        )
    }

    /// Run a suite by name.
    func run(
        suiteName: String,
        providerName: String,
        format: String,
        outputPath: String?,
        diagnostics: Diagnostics
    ) async throws -> Bool {
        let suite = try resolveSuite(named: suiteName)
        return try await run(
            suite: suite,
            providerName: providerName,
            format: format,
            outputPath: outputPath,
            diagnostics: diagnostics
        )
    }

    /// Run a concrete suite and render the report.
    func run(
        suite: BenchmarkSuite,
        providerName: String,
        format: String,
        outputPath: String?,
        diagnostics: Diagnostics
    ) async throws -> Bool {
        let runner = EvalRunner(
            config: EvalConfig(providerName: providerName),
            diagnostics: diagnostics
        )

        var results: [EvalResult] = []
        for evalCase in suite.cases {
            let result = await runner.run(evalCase)
            results.append(result)
        }

        let report = try await renderReport(results: results, format: format)

        if let outputPath {
            let url = URL(fileURLWithPath: outputPath)
            let parentDir = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parentDir.path) else {
                throw EvalCommandError.missingOutputDirectory
            }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw EvalCommandError.writeFailed(error)
            }
        } else {
            print(report)
        }

        return results.allSatisfy(\.passed)
    }

    // MARK: - Parsing

    private struct Options {
        var helpRequested = false
        var suiteName = "Suite1"
        var providerName = "faux"
        var format = "markdown"
        var outputPath: String?
    }

    private func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-h", "--help":
                options.helpRequested = true
                index += 1
            case "--suite":
                guard index + 1 < arguments.count else {
                    throw EvalCommandError.missingValue("--suite")
                }
                options.suiteName = arguments[index + 1]
                index += 2
            case "--provider":
                guard index + 1 < arguments.count else {
                    throw EvalCommandError.missingValue("--provider")
                }
                options.providerName = arguments[index + 1]
                index += 2
            case "--format":
                guard index + 1 < arguments.count else {
                    throw EvalCommandError.missingValue("--format")
                }
                options.format = arguments[index + 1]
                index += 2
            case "--output":
                guard index + 1 < arguments.count else {
                    throw EvalCommandError.missingValue("--output")
                }
                options.outputPath = arguments[index + 1]
                index += 2
            default:
                throw EvalCommandError.unknownArgument(arg)
            }
        }
        return options
    }

    // MARK: - Helpers

    private func resolveSuite(named name: String) throws -> BenchmarkSuite {
        switch name {
        case "Suite1":
            return BenchmarkSuites.suite1
        default:
            throw EvalCommandError.unknownSuite(name)
        }
    }

    private func renderReport(results: [EvalResult], format: String) async throws -> String {
        switch format.lowercased() {
        case "json":
            return try await JSONEvalReporter().report(results: results)
        case "markdown", "md":
            return try await MarkdownEvalReporter().report(results: results)
        default:
            throw EvalCommandError.unknownFormat(format)
        }
    }

    private static let helpText = """
    forgeloop eval

    Run a benchmark suite and render a report.

    usage:
      forgeloop eval [--suite <name>] [--provider <name>] [--format <format>] [--output <path>]

    options:
      --suite <name>      Benchmark suite to run (default: Suite1)
      --provider <name>   Provider to use for agent calls (default: faux)
      --format <format>   Report format: json or markdown (default: markdown)
      --output <path>     Write report to file instead of stdout
      --help              Show this help
    """
}
