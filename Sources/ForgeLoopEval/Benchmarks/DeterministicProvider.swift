import Foundation
import ForgeLoopAI

/// Maps `EvalCase.id` values from the built-in benchmark suites to deterministic
/// `FauxProvider` configurations.
///
/// This keeps the benchmark suite reproducible and free from real LLM costs.
/// When a case has no deterministic mapping, `make(for:)` returns `nil` so the
/// caller can fail loudly instead of silently using an unconfigured provider.
public enum DeterministicProvider {
    /// Returns the `FauxProvider` that can satisfy the given benchmark case,
    /// or `nil` if no deterministic mapping exists.
    ///
    /// - Parameters:
    ///   - evalCase: The benchmark case to provide for.
    ///   - api: The API name to register the provider under. Use a unique name
    ///     per run to avoid colliding with other registered providers.
    public static func make(for evalCase: EvalCase, api: String = "faux") -> FauxProvider? {
        switch evalCase.id {
        case "suite1-create-readme":
            return FauxProvider(
                api: api,
                mode: .toolCall(
                    name: "bash",
                    arguments: #"{"command": "/bin/sh", "args": ["-c", "printf '# Foo\n\nProject Foo.' > README.md"]}"#
                )
            )
        case "suite1-add-function":
            return FauxProvider(
                api: api,
                mode: .toolCall(
                    name: "bash",
                    arguments: #"{"command": "/bin/sh", "args": ["-c", "printf 'func sum(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n' > Math.swift"]}"#
                )
            )
        case "suite1-fix-typo":
            return FauxProvider(
                api: api,
                mode: .toolCall(
                    name: "edit",
                    arguments: #"{"path": "greeting.txt", "oldText": "Helo", "newText": "Hello"}"#
                )
            )
        default:
            return nil
        }
    }
}
