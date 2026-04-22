import Foundation
import ForgeLoopAgent

public enum ForgeLoop {
    public static func runCodingTUI(cwd: String? = nil, modelOverride: String? = nil) async throws {
        let resolved = try await resolveAgentAuth(modelOverride: modelOverride)
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        try await runCodingTUIInternal(
            model: resolved.model,
            cwd: workDir
        )
    }

    public static func runLogin() async throws {
        print("login flow is not implemented in the scaffold yet.")
    }
}
