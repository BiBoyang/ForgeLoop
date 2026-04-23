import Foundation
import ForgeLoopAgent
import ForgeLoopAI

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
        print("Enter your API key: ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            throw LoginError.missingAPIKey
        }

        let store = CredentialStore()
        store.save(apiKey: input)

        // Verify the key works by registering providers
        _ = await registerBuiltins(storedAPIKey: input)

        print("Login successful. Credentials saved to ~/.config/forgeloop/credentials.json")
    }
}
