import Foundation
import UIKit

/// Cursor Cloud Agents client for food photo estimates.
actor CursorFoodEstimateClient {
    static let shared = CursorFoodEstimateClient()

    private let api = CursorCloudAgentClient.shared

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case agent(CursorCloudAgentClient.AgentError)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings to estimate from a photo."
            case .invalidImage:
                return "Couldn’t encode the photo."
            case .agent(let error):
                return error.errorDescription
            }
        }
    }

    func estimateFood(
        from image: UIImage,
        apiKey: String,
        prompt: String = AIFoodEstimateService.prompt(),
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIRecipeImportDraft {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }

        let jpeg = try jpegPayload(from: image)

        do {
            let (agentId, runId) = try await ensureRun(
                apiKey: trimmedKey,
                prompt: prompt,
                imageBase64: jpeg.base64,
                mimeType: jpeg.mimeType,
                onStatus: onStatus
            )
            let resultText = try await api.awaitAssistantText(
                apiKey: trimmedKey,
                agentId: agentId,
                runId: runId,
                onStatus: onStatus
            )
            return try AIFoodEstimateService.parse(resultText)
        } catch let error as CursorCloudAgentClient.AgentError {
            throw ClientError.agent(error)
        }
    }

    private func ensureRun(
        apiKey: String,
        prompt: String,
        imageBase64: String,
        mimeType: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> (agentId: String, runId: String) {
        if let existingId = FoodEstimateAgentStore.agentId {
            do {
                onStatus("Reusing standing agent…")
                let runId = try await api.createRun(
                    apiKey: apiKey,
                    agentId: existingId,
                    prompt: prompt,
                    imageBase64: imageBase64,
                    mimeType: mimeType
                )
                return (existingId, runId)
            } catch {
                if await api.shouldRecreate(after: error) {
                    onStatus("Standing agent expired — recreating…")
                    FoodEstimateAgentStore.agentId = nil
                } else {
                    throw error
                }
            }
        }

        onStatus("Creating standing agent (first time can take a minute)…")
        let created = try await api.createAgent(
            apiKey: apiKey,
            prompt: standingBootstrapPrompt,
            name: "belessfat · Food estimate"
        )
        FoodEstimateAgentStore.agentId = created.agentId

        onStatus("Starting estimate run…")
        let runId = try await api.createRun(
            apiKey: apiKey,
            agentId: created.agentId,
            prompt: prompt,
            imageBase64: imageBase64,
            mimeType: mimeType
        )
        return (created.agentId, runId)
    }

    private var standingBootstrapPrompt: String {
        """
        You are a standing food identifier for the belessfat app.
        Keep this role for the conversation. When the user sends a photo and estimate instructions: identify only foods and ingredients that are visible (or named by the user); do not add invisible cooking oil, butter, dressings, sauces, marinades, or other prep unless they are clearly visible or explicitly mentioned; estimate a realistic amount for each item from visual cues, preferring the weight unit requested in the run prompt (ounces or grams); if an amount is uncertain, use the midpoint of a plausible range, not the high end; do not invent calories, macros, or database ids — the app looks those up. Reply with ONLY the requested JSON object — no markdown fences, no commentary, no step-by-step writeup. Do not search the web or use tools unless required to read the image.
        """
    }

    private func jpegPayload(from image: UIImage) throws -> (base64: String, mimeType: String) {
        let scaled = resized(image, maxDimension: 1280)
        guard let data = scaled.jpegData(compressionQuality: 0.72) else {
            throw ClientError.invalidImage
        }
        return (data.base64EncodedString(), "image/jpeg")
    }

    private func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
