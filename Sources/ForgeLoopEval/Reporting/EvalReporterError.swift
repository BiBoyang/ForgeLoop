import Foundation

/// Errors that can occur while generating an eval report.
public enum EvalReporterError: Error, LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode report as UTF-8 string"
        }
    }
}
