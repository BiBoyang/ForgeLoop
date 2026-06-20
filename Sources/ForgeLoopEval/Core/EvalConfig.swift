import Foundation

/// Configuration for the eval runner.
public struct EvalConfig: Sendable, Codable, Equatable {
    public let defaultTimeout: Duration
    public let maxRetries: Int
    public let providerName: String

    public init(
        defaultTimeout: Duration = .seconds(60),
        maxRetries: Int = 0,
        providerName: String = "faux"
    ) {
        self.defaultTimeout = defaultTimeout
        self.maxRetries = maxRetries
        self.providerName = providerName
    }
}
