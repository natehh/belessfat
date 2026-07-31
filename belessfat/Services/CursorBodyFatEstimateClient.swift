import Foundation
import UIKit

/// Cursor Cloud Agents client for body-fat photo estimates (multi-image).
actor CursorBodyFatEstimateClient {
    static let shared = CursorBodyFatEstimateClient()

    private let api = CursorCloudAgentClient.shared

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case agent(CursorCloudAgentClient.AgentError)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings to estimate body fat."
            case .invalidImage:
                return "Couldn’t encode the photo."
            case .agent(let error):
                return error.errorDescription
            }
        }
    }

    func estimateBodyFat(
        images: [UIImage],
        prompt: String,
        apiKey: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIBodyFatEstimateResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }

        let payloads: [(base64: String, mimeType: String)]
        do {
            payloads = try DirectAIClient.jpegPayloads(from: images).map { ($0.base64, $0.mimeType) }
        } catch {
            throw ClientError.invalidImage
        }

        do {
            let (agentId, runId) = try await ensureRun(
                apiKey: trimmedKey,
                prompt: prompt,
                images: payloads,
                onStatus: onStatus
            )
            let resultText = try await api.awaitAssistantText(
                apiKey: trimmedKey,
                agentId: agentId,
                runId: runId,
                onStatus: onStatus
            )
            return try AIBodyFatEstimateService.parse(resultText)
        } catch let error as CursorCloudAgentClient.AgentError {
            throw ClientError.agent(error)
        }
    }

    private func ensureRun(
        apiKey: String,
        prompt: String,
        images: [(base64: String, mimeType: String)],
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> (agentId: String, runId: String) {
        if let existingId = BodyFatEstimateAgentStore.agentId {
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
                    BodyFatEstimateAgentStore.agentId = nil
                } else {
                    throw error
                }
            }
        }

        onStatus("Creating standing agent (first time can take a minute)…")
        let created = try await api.createAgent(
            apiKey: apiKey,
            prompt: standingBootstrapPrompt,
            name: "belessfat · Body fat estimate"
        )
        BodyFatEstimateAgentStore.agentId = created.agentId

        onStatus("Starting body-fat estimate…")
        let runId = try await api.createRun(
            apiKey: apiKey,
            agentId: created.agentId,
            prompt: prompt,
            images: images
        )
        return (created.agentId, runId)
    }

    private var standingBootstrapPrompt: String {
        """
        You are a standing visual body-fat estimator for the belessfat app.
        Keep this role. When given photos and estimate instructions, reply with ONLY the requested JSON object — no markdown, no commentary. Do not browse the web or use tools unless required to read images.
        """
    }
}
