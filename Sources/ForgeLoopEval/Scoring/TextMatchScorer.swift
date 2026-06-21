import Foundation

/// Shared text-matching utilities used by content-based scorers.
///
/// `TextMatchScorer` is a pure, stateless helper. It does not conform to
/// `EvalScorer` because there is no plain-text assertion type; instead it
/// centralizes the boolean matching logic shared by `FileContentScorer` and
/// `CommandOutputScorer`.
public struct TextMatchScorer: Sendable {
    public init() {}

    /// Returns `true` when `text` contains `substring`.
    public func contains(_ text: String, substring: String) -> Bool {
        text.contains(substring)
    }

    /// Returns `true` when `text` does not contain `substring`.
    public func notContains(_ text: String, substring: String) -> Bool {
        !text.contains(substring)
    }

    /// Returns `true` when `text` is exactly equal to `expected`.
    public func equals(_ text: String, expected: String) -> Bool {
        text == expected
    }
}
