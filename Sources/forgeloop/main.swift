import Foundation
import ForgeLoopCli

@main
struct ForgeLoopCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        // Parse flags and subcommand
        var overrideModel: String?
        var remainingArgs: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--model", i + 1 < args.count {
                overrideModel = args[i + 1]
                i += 2
            } else {
                remainingArgs.append(args[i])
                i += 1
            }
        }

        let subcommand = remainingArgs.first

        switch subcommand {
        case nil:
            let cliModel = overrideModel
            await runOrExit {
                try await ForgeLoop.runCodingTUI(modelOverride: cliModel)
            }
        case "login":
            await runOrExit {
                try await ForgeLoop.runLogin()
            }
        case "-h", "--help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("forgeloop: unknown subcommand '\(subcommand!)'\n".utf8))
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
          forgeloop [--model <id>]  launch coding tui scaffold
          forgeloop login            login scaffold
          forgeloop --help           show help

        tip:
          type /exit in TUI to quit
        """)
    }
}
