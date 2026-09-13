import Foundation
import UIKit

/// Provider-agnostic entry point for in-app AI features.
enum AIAssistant {
    enum AssistantError: LocalizedError {
        case missingAPIKey
        case invalidImage
        case emptyResult
        case httpStatus(Int, String)
        case unauthorized
        case timedOut
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings to use in-app AI."
            case .invalidImage:
                return "Couldn’t encode the photo."
            case .emptyResult:
                return "AI returned an empty reply."
            case .httpStatus(let code, let body):
                return body.isEmpty ? "AI HTTP \(code)" : "AI HTTP \(code): \(body)"
            case .unauthorized:
                return "Invalid AI API key for the selected provider."
            case .timedOut:
                return "AI took too long to respond. Try again in a moment."
            case .decoding(let message):
                return message
            }
        }
    }

    static var hasConfiguredKey: Bool { AIProviderStore.hasConfiguredKey }

    static func estimateFood(
        from image: UIImage,
        foodNameHint: String? = nil,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIRecipeImportDraft {
        let provider = AIProviderStore.selected
        guard let apiKey = AIProviderStore.apiKey(for: provider), !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey
        }
        let prompt = AIFoodEstimateService.prompt(foodNameHint: foodNameHint)

        switch provider {
        case .cursor:
            return try await CursorFoodEstimateClient.shared.estimateFood(
                from: image,
                apiKey: apiKey,
                prompt: prompt,
                onStatus: onStatus
            )
        case .openai, .anthropic, .gemini:
            onStatus("Preparing photo…")
            let jpeg = try DirectAIClient.jpegPayload(from: image)
            onStatus("Sending to AI…")
            let text = try await DirectAIClient.shared.complete(
                provider: provider,
                apiKey: apiKey,
                prompt: prompt,
                image: jpeg,
                onStatus: onStatus
            )
            return try AIFoodEstimateService.parse(text)
        }
    }

    static func importRecipe(
        sourceText: String,
        sourceURL: String?,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIRecipeImportDraft {
        let provider = AIProviderStore.selected
        guard let apiKey = AIProviderStore.apiKey(for: provider), !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey
        }
        let prompt = AIRecipeImportService.prompt(sourceText: sourceText, sourceURL: sourceURL)

        switch provider {
        case .cursor:
            return try await CursorRecipeImportClient.shared.importRecipe(
                sourceText: sourceText,
                sourceURL: sourceURL,
                apiKey: apiKey,
                onStatus: onStatus
            )
        case .openai, .anthropic, .gemini:
            onStatus("Sending to AI…")
            let text = try await DirectAIClient.shared.complete(
                provider: provider,
                apiKey: apiKey,
                prompt: prompt,
                image: nil,
                onStatus: onStatus
            )
            return try AIRecipeImportService.parse(text)
        }
    }

    static func estimateBodyFat(
        images: [UIImage],
        profile: AIBodyFatEstimateService.ProfileContext,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> AIBodyFatEstimateResult {
        let provider = AIProviderStore.selected
        guard let apiKey = AIProviderStore.apiKey(for: provider), !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey
        }
        guard !images.isEmpty else { throw AssistantError.invalidImage }

        let prompt = AIBodyFatEstimateService.prompt(profile: profile, imageCount: min(images.count, 4))

        switch provider {
        case .cursor:
            return try await CursorBodyFatEstimateClient.shared.estimateBodyFat(
                images: images,
                prompt: prompt,
                apiKey: apiKey,
                onStatus: onStatus
            )
        case .openai, .anthropic, .gemini:
            onStatus("Preparing photos…")
            let payloads = try DirectAIClient.jpegPayloads(from: images)
            onStatus("Sending to AI…")
            let text = try await DirectAIClient.shared.complete(
                provider: provider,
                apiKey: apiKey,
                prompt: prompt,
                images: payloads,
                onStatus: onStatus
            )
            return try AIBodyFatEstimateService.parse(text)
        }
    }
}
