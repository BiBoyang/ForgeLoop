import Foundation

/// A single eval/benchmark case describing an agent task and its expected outcomes.
public struct EvalCase: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let prompt: String
    public let initialFiles: [EvalFile]
    public let assertions: [EvalAssertion]
    public let timeout: Duration
    public let tags: [String]

    public init(
        id: String,
        name: String,
        description: String,
        prompt: String,
        initialFiles: [EvalFile] = [],
        assertions: [EvalAssertion] = [],
        timeout: Duration = .seconds(60),
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
        self.initialFiles = initialFiles
        self.assertions = assertions
        self.timeout = timeout
        self.tags = tags
    }
}

/// An initial file placed into the eval workspace before the agent runs.
public struct EvalFile: Sendable, Codable, Equatable {
    public let path: String
    public let content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}
