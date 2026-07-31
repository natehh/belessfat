import Foundation

/// Cursor Cloud Agents client for recipe import (text → structured ingredients).
actor CursorRecipeImportClient {
    static let shared = CursorRecipeImportClient()

    private let api = CursorCloudAgentClient.shared

    enum ClientError: LocalizedError {
        case missingAPIKey
        case emptySource
        case agent(CursorCloudAgentClient.AgentError)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings to import recipes with AI."
            case .emptySource:
                return "No recipe text to send."
            case .agent(let error):
                return error.errorDescription
            }
        }
    }

    func importRecipe(
        sourceText: String,
        sourceURL: String?,
        apiKey: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIRecipeImportDraft {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptySource }

        let prompt = AIRecipeImportService.prompt(sourceText: text, sourceURL: sourceURL)

        do {
            let (agentId, runId) = try await ensureRun(
                apiKey: trimmedKey,
                prompt: prompt,
                onStatus: onStatus
            )
            let resultText = try await api.awaitAssistantText(
                apiKey: trimmedKey,
                agentId: agentId,
                runId: runId,
                onStatus: onStatus
            )
            return try AIRecipeImportService.parse(resultText)
        } catch let error as CursorCloudAgentClient.AgentError {
            throw ClientError.agent(error)
        }
    }

    private func ensureRun(
        apiKey: String,
        prompt: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> (agentId: String, runId: String) {
        if let existingId = RecipeImportAgentStore.agentId {
            do {
                onStatus("Reusing standing agent…")
                let runId = try await api.createRun(
                    apiKey: apiKey,
                    agentId: existingId,
                    prompt: prompt
                )
                return (existingId, runId)
            } catch {
                if await api.shouldRecreate(after: error) {
                    onStatus("Standing agent expired — recreating…")
                    RecipeImportAgentStore.agentId = nil
                } else {
                    throw error
                }
            }
        }

        onStatus("Creating standing agent (first time can take a minute)…")
        let created = try await api.createAgent(
            apiKey: apiKey,
            prompt: standingBootstrapPrompt,
            name: "belessfat · Recipe import"
        )
        RecipeImportAgentStore.agentId = created.agentId

        onStatus("Starting recipe import run…")
        let runId = try await api.createRun(
            apiKey: apiKey,
            agentId: created.agentId,
            prompt: prompt
        )
        return (created.agentId, runId)
    }

    private var standingBootstrapPrompt: String {
        """
        You are a standing recipe importer for the belessfat app.
        Keep this role. When given webpage or recipe text, extract title, servings, and normalized ingredients for food-database search. Reply with ONLY the requested JSON object — no markdown, no commentary. Do not invent database ids or nutrition macros. Do not browse the web or use tools unless required to read attached content.
        """
    }
}
