import Foundation

/// The first example benchmark suite.
///
/// `Suite1` contains small, deterministic coding tasks that are driven by
/// `FauxProvider` tool calls. The cases are intentionally simple so that the
/// suite can validate the `EvalRunner` + `EvalScorer` + `EvalReporter` pipeline
/// without depending on a real LLM.
public enum BenchmarkSuites {
    /// The first example suite.
    public static let suite1 = BenchmarkSuite(
        name: "Suite1",
        cases: [
            createREADME,
            addFunction,
            fixTypo
        ]
    )

    /// Create a `README.md` containing the project name.
    public static let createREADME = EvalCase(
        id: "suite1-create-readme",
        name: "Create README",
        description: "Agent creates a README.md with project name 'Foo'.",
        prompt: "Create a README.md with project name 'Foo'",
        initialFiles: [],
        assertions: [
            .fileExists(path: "README.md"),
            .fileContains(path: "README.md", substring: "Foo")
        ],
        timeout: .seconds(10),
        tags: ["smoke", "suite1"]
    )

    /// Add a `sum` function to an existing empty file.
    public static let addFunction = EvalCase(
        id: "suite1-add-function",
        name: "Add Function",
        description: "Agent adds a function that sums two integers to Math.swift.",
        prompt: "Add a function that sums two integers",
        initialFiles: [
            EvalFile(path: "Math.swift", content: "")
        ],
        assertions: [
            .fileContains(path: "Math.swift", substring: "func sum")
        ],
        timeout: .seconds(10),
        tags: ["smoke", "suite1"]
    )

    /// Fix a typo in an existing file.
    public static let fixTypo = EvalCase(
        id: "suite1-fix-typo",
        name: "Fix Typo",
        description: "Agent fixes 'Helo' to 'Hello' in greeting.txt.",
        prompt: "Fix the typo",
        initialFiles: [
            EvalFile(path: "greeting.txt", content: "Helo world")
        ],
        assertions: [
            .fileNotContains(path: "greeting.txt", substring: "Helo"),
            .fileContains(path: "greeting.txt", substring: "Hello")
        ],
        timeout: .seconds(10),
        tags: ["smoke", "suite1"]
    )
}
