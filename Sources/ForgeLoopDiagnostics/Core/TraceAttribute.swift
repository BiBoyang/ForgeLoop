/// A typed attribute value attached to traces or logs.
///
/// Use `.masked` for values that have already been redacted, so sinks can
/// treat them safely without attempting additional masking.
public enum TraceAttribute: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
    case masked(String)
}
