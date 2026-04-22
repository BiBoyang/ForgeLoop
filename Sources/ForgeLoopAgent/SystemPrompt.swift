import Foundation

public func buildSystemPrompt(cwd: String, date: String? = nil) -> String {
    let currentDate: String = {
        if let date { return date }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()

    return """
    You are an expert coding assistant operating inside kw, a coding agent harness.
    Help the user by understanding requirements, editing code carefully, and verifying results.
    Current date: \(currentDate)
    Current working directory: \(cwd)
    """
}
