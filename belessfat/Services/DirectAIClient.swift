import Foundation
import UIKit

/// Direct chat/vision APIs for OpenAI, Anthropic, and Gemini.
actor DirectAIClient {
    static let shared = DirectAIClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    struct ImagePayload: Sendable {
        let base64: String
        let mimeType: String
    }

    func complete(
        provider: AIProvider,
        apiKey: String,
        prompt: String,
        image: ImagePayload?,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let images = image.map { [$0] } ?? []
        return try await complete(
            provider: provider,
            apiKey: apiKey,
            prompt: prompt,
            images: images,
            onStatus: onStatus
        )
    }

    func complete(
        provider: AIProvider,
        apiKey: String,
        prompt: String,
        images: [ImagePayload],
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        onStatus("Waiting for reply…")
        switch provider {
        case .openai:
            return try await openAI(apiKey: apiKey, prompt: prompt, images: images)
        case .anthropic:
            return try await anthropic(apiKey: apiKey, prompt: prompt, images: images)
        case .gemini:
            return try await gemini(apiKey: apiKey, prompt: prompt, images: images)
        case .cursor:
            throw AIAssistant.AssistantError.decoding("Cursor is handled separately.")
        }
    }

    static func jpegPayloads(from images: [UIImage], maxCount: Int = 4) throws -> [ImagePayload] {
        let limited = Array(images.prefix(maxCount))
        guard !limited.isEmpty else { throw AIAssistant.AssistantError.invalidImage }
        return try limited.map { try jpegPayload(from: $0) }
    }

    static func jpegPayload(from image: UIImage) throws -> ImagePayload {
        let scaled = resized(image, maxDimension: 1280)
        guard let data = scaled.jpegData(compressionQuality: 0.72) else {
            throw AIAssistant.AssistantError.invalidImage
        }
        return ImagePayload(base64: data.base64EncodedString(), mimeType: "image/jpeg")
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
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

    // MARK: - OpenAI

    private func openAI(apiKey: String, prompt: String, images: [ImagePayload]) async throws -> String {
        var content: [Any] = [
            ["type": "text", "text": prompt]
        ]
        for image in images {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(image.mimeType);base64,\(image.base64)"
                ]
            ])
        }
        let body: [String: Any] = [
            "model": AIProvider.openai.defaultModelId,
            "temperature": 0.2,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        let data = try await postJSON(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: apiKey,
            auth: .bearer,
            extraHeaders: [:],
            body: body
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIAssistant.AssistantError.emptyResult
        }
        return text
    }

    // MARK: - Anthropic

    private func anthropic(apiKey: String, prompt: String, images: [ImagePayload]) async throws -> String {
        var content: [[String: Any]] = []
        for image in images {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.base64
                ]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": AIProvider.anthropic.defaultModelId,
            "max_tokens": 4096,
            "temperature": 0.2,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        let data = try await postJSON(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: apiKey,
            auth: .anthropic,
            extraHeaders: ["anthropic-version": "2023-06-01"],
            body: body
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = json["content"] as? [[String: Any]]
        else {
            throw AIAssistant.AssistantError.emptyResult
        }
        let text = blocks
            .compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIAssistant.AssistantError.emptyResult }
        return text
    }

    // MARK: - Gemini

    private func gemini(apiKey: String, prompt: String, images: [ImagePayload]) async throws -> String {
        var parts: [[String: Any]] = [["text": prompt]]
        for image in images {
            parts.append([
                "inlineData": [
                    "mimeType": image.mimeType,
                    "data": image.base64
                ]
            ])
        }
        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ]
        let model = AIProvider.gemini.defaultModelId
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw AIAssistant.AssistantError.decoding("Invalid Gemini URL.")
        }
        let data = try await postJSON(
            url: url,
            apiKey: apiKey,
            auth: .none,
            extraHeaders: [:],
            body: body
        )
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let partsOut = content["parts"] as? [[String: Any]]
        else {
            throw AIAssistant.AssistantError.emptyResult
        }
        let text = partsOut
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIAssistant.AssistantError.emptyResult }
        return text
    }

    // MARK: - HTTP

    private enum AuthStyle {
        case bearer
        case anthropic
        case none
    }

    private func postJSON(
        url: URL,
        apiKey: String,
        auth: AuthStyle,
        extraHeaders: [String: String],
        body: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        switch auth {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .none:
            break
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIAssistant.AssistantError.decoding("Invalid response.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIAssistant.AssistantError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                let clipped = message.count > 400 ? String(message.prefix(400)) + "…" : message
                throw AIAssistant.AssistantError.httpStatus(http.statusCode, clipped)
            }
            return data
        } catch let error as URLError where error.code == .timedOut {
            throw AIAssistant.AssistantError.timedOut
        }
    }
}
