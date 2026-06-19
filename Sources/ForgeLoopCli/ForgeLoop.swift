import Foundation
import ForgeLoopAgent
import ForgeLoopAI
import ForgeLoopDiagnostics

public enum ForgeLoop {
    public static func runCodingTUI(
        cwd: String? = nil,
        modelOverride: String? = nil,
        diagnostics: Diagnostics = Diagnostics()
    ) async throws {
        let resolved = try await resolveAgentAuth(modelOverride: modelOverride)
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        try await runCodingTUIInternal(
            model: resolved.model,
            cwd: workDir,
            diagnostics: diagnostics
        )
    }

    public static func runLogin(
        credentialStore: CredentialStore = CredentialStore(),
        inputProvider: @escaping @Sendable () -> String? = { readHiddenInput(prompt: "Enter your API key: ") }
    ) async throws {
        guard let input = inputProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !input.isEmpty else {
            throw LoginError.missingAPIKey
        }

        credentialStore.save(apiKey: input)

        // Verify the key works by registering providers
        _ = await registerBuiltins(storedAPIKey: input)

        print("Login successful. Credentials saved to ~/.config/forgeloop/credentials.json")
    }
}
