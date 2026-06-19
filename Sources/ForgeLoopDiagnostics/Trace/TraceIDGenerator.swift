import Foundation

/// Generates trace and span identifiers.
///
/// Uses `UUID` by default; replace with a custom generator if a more compact
/// or ordered format is needed.
public enum TraceIDGenerator {
    public static func makeTraceID() -> String {
        UUID().uuidString
    }

    public static func makeSpanID() -> String {
        UUID().uuidString
    }
}
