import Foundation
import UIKit

/// Cursor Cloud Agents client for quick food estimates and restaurant menus.
actor CursorMacroEstimateClient {
    static let shared = CursorMacroEstimateClient()

    enum Kind {
        case quickFood
        case menu
    }

    private let api = CursorCloudAgentClient.shared

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case agent(CursorCloudAgentClient.AgentError)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings."
            case .invalidImage:
                return "Couldn’t encode the photo."
            case .agent(let error):
                return error.errorDescription
            }
        }
    }

    func complete(
        kind: Kind,
        prompt: String,
        images: [UIImage],
        apiKey: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }

        let payloads: [(base64: String, mimeType: String)]
        if images.isEmpty {
            payloads = []
        } else {
            do {
                let maxCount = kind == .menu ? 8 : 4
                payloads = try DirectAIClient.jpegPayloads(from: images, maxCount: maxCount).map { ($0.base64, $0.mimeType) }
            } catch {
                throw ClientError.invalidImage
            }
        }

        do {
            let (agentId, runId) = try await ensureRun(
                kind: kind,
                apiKey: trimmedKey,
                prompt: prompt,
                images: payloads,
                onStatus: onStatus
            )
            return try await api.awaitAssistantText(
                apiKey: trimmedKey,
                agentId: agentId,
                runId: runId,
                onStatus: onStatus
            )
        } catch let error as CursorCloudAgentClient.AgentError {
            throw ClientError.agent(error)
        }
    }

    private func ensureRun(
        kind: Kind,
        apiKey: String,
        prompt: String,
        images: [(base64: String, mimeType: String)],
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> (agentId: String, runId: String) {
        if let existingId = kind.storedAgentId {
            do {
                onStatus("Reusing standing agent…")
                let runId = try await api.createRun(
                    apiKey: apiKey,
                    agentId: existingId,
                    prompt: prompt,
                    images: images
                )
                return (existingId, runId)
            } catch {
                if await api.shouldRecreate(after: error) {
                    onStatus("Standing agent expired — recreating…")
                    kind.storedAgentId = nil
                } else {
                    throw error
                }
            }
        }

        onStatus("Creating standing agent (first time can take a minute)…")
        let created = try await api.createAgent(
            apiKey: apiKey,
            prompt: kind.bootstrapPrompt,
            name: kind.agentName
        )
        kind.storedAgentId = created.agentId

        onStatus("Starting estimate…")
        let runId = try await api.createRun(
            apiKey: apiKey,
            agentId: created.agentId,
            prompt: prompt,
            images: images
        )
        return (created.agentId, runId)
    }
}

private extension CursorMacroEstimateClient.Kind {
    var storedAgentId: String? {
        get {
            switch self {
            case .quickFood: return QuickFoodEstimateAgentStore.agentId
            case .menu: return MenuEstimateAgentStore.agentId
            }
        }
        nonmutating set {
            switch self {
            case .quickFood: QuickFoodEstimateAgentStore.agentId = newValue
            case .menu: MenuEstimateAgentStore.agentId = newValue
            }
        }
    }

    var agentName: String {
        switch self {
        case .quickFood: return "belessfat · Quick food estimate"
        case .menu: return "belessfat · Menu estimate"
        }
    }

    var bootstrapPrompt: String {
        switch self {
        case .quickFood:
            return """
            You estimate one serving of a food for the belessfat calorie tracker.
            Use the photo and any description. If nutrition is already listed, use it.
            Reply with ONLY the requested JSON object — no markdown fences and no commentary.
            """
        case .menu:
            return """
            You read restaurant menus and estimate one serving of menu items for the belessfat calorie tracker.
            Use the item name, description, photos, and any nutrition already listed.
            If you cannot read a page, say so with the requested needs_menu JSON instead of inventing a menu.
            Reply with ONLY the requested JSON object — no markdown fences and no commentary.
            """
        }
    }
}
