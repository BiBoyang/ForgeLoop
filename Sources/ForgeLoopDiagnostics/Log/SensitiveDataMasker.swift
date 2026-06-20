import Foundation

/// Redacts potentially sensitive information from strings and log attributes.
///
/// The masker is a value type with no mutable state, so it can safely be shared
/// by concurrent log sinks without synchronization overhead.
public struct SensitiveDataMasker: Sendable {
    public init() {}

    /// Masks sensitive patterns in a string.
    ///
    /// Currently handled patterns:
    /// - API keys matching `sk-<alphanumeric>`.
    /// - Bearer tokens (`Bearer <token>` and `Authorization: Bearer <token>`).
    /// - The current user's home directory path is replaced with `~`.
    ///
    /// If `preservePrefixLength` is greater than 0 and the resulting string is
    /// longer, everything after the prefix is replaced with `***`. This is
    /// useful for long message content where a short preview is enough.
    public func mask(_ value: String, preservePrefixLength: Int = 0) -> String {
        var result = value

        result = maskAPIKeys(in: result)
        result = maskBearerTokens(in: result)
        result = maskHomeDirectory(in: result)

        if preservePrefixLength > 0 && result.count > preservePrefixLength {
            let prefix = result.prefix(preservePrefixLength)
            result = String(prefix) + "***"
        }

        return result
    }

    /// Masks sensitive values inside attributes.
    ///
    /// - `.masked(String)` values are passed through unchanged (already safe).
    /// - `.string(String)` values are run through `mask(_:)`.
    /// - Numeric and boolean values are returned as-is.
    public func maskAttributes(
        _ attributes: [String: TraceAttribute]
    ) -> [String: TraceAttribute] {
        attributes.mapValues { attribute in
            switch attribute {
            case .string(let value):
                return .string(mask(value))
            case .int, .bool, .double:
                return attribute
            case .masked:
                return attribute
            }
        }
    }

    private func maskAPIKeys(in value: String) -> String {
        value.replacingOccurrences(
            of: #"\bsk-[a-zA-Z0-9]{20,}\b"#,
            with: "***",
            options: .regularExpression
        )
    }

    private func maskBearerTokens(in value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"Authorization:\s*Bearer\s+[a-zA-Z0-9_\-\.]+"#,
            with: "Authorization: Bearer ***",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\bBearer\s+[a-zA-Z0-9_\-\.]+"#,
            with: "Bearer ***",
            options: .regularExpression
        )
        return result
    }

    private func maskHomeDirectory(in value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty && home != "/" else { return value }
        return value.replacingOccurrences(of: home, with: "~")
    }
}
