import Foundation

/// Shared Cursor Cloud Agents API (Basic auth, long timeouts, stream then poll).
actor CursorCloudAgentClient {
    static let shared = CursorCloudAgentClient()

    private let baseURL = URL(string: "https://api.cursor.com/v1")!
    private let session: URLSession
    let defaultModelId = "composer-2.5"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "Accept": "application/json"
        ]
        self.session = URLSession(configuration: config)
    }

    enum AgentError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case unauthorized
        case httpStatus(Int, String)
        case decoding(String)
        case timedOut
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an AI API key in Settings."
            case .invalidResponse:
                return "Invalid response from AI provider."
            case .unauthorized:
                return "Invalid AI API key."
            case .httpStatus(let code, let body):
                return body.isEmpty ? "AI HTTP \(code)" : "AI HTTP \(code): \(body)"
            case .decoding(let message):
                return message
            case .timedOut:
                return "AI took too long to respond. Try again in a moment."
            case .emptyResult:
                return "AI returned an empty reply."
            }
        }
    }

    func createAgent(
        apiKey: String,
        prompt: String,
        modelId: String? = nil,
        name: String?
    ) async throws -> (agentId: String, runId: String?) {
        var body: [String: Any] = [
            "prompt": ["text": prompt],
            "model": ["id": modelId ?? defaultModelId]
        ]
        if let name { body["name"] = name }

        let data = try await post(path: "agents", apiKey: apiKey, body: body, timeout: 180)
        let decoded = try JSONDecoder().decode(CreateAgentResponse.self, from: data)
        guard let agentId = decoded.resolvedAgentId else {
            let snippet = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AgentError.decoding("Missing agent id: \(snippet.prefix(500))")
        }
        return (agentId, decoded.resolvedRunId)
    }

    func createRun(
        apiKey: String,
        agentId: String,
        prompt: String,
        imageBase64: String? = nil,
        mimeType: String? = nil
    ) async throws -> String {
        var images: [(base64: String, mimeType: String)] = []
        if let imageBase64, let mimeType {
            images = [(imageBase64, mimeType)]
        }
        return try await createRun(apiKey: apiKey, agentId: agentId, prompt: prompt, images: images)
    }

    func createRun(
        apiKey: String,
        agentId: String,
        prompt: String,
        images: [(base64: String, mimeType: String)]
    ) async throws -> String {
        var promptBody: [String: Any] = ["text": prompt]
        if !images.isEmpty {
            promptBody["images"] = images.map { image in
                [
                    "data": image.base64,
                    "mimeType": image.mimeType
                ]
            }
        }
        let body: [String: Any] = ["prompt": promptBody]
        let data = try await post(path: "agents/\(agentId)/runs", apiKey: apiKey, body: body, timeout: 180)
        let decoded = try JSONDecoder().decode(CreateRunResponse.self, from: data)
        guard let runId = decoded.resolvedRunId else {
            throw AgentError.decoding("Missing run id: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return runId
    }

    func awaitAssistantText(
        apiKey: String,
        agentId: String,
        runId: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        do {
            onStatus("Streaming reply…")
            let streamed = try await streamRun(apiKey: apiKey, agentId: agentId, runId: runId)
            if !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return streamed
            }
            onStatus("Stream empty — checking run status…")
        } catch let error as URLError where error.code == .timedOut {
            onStatus("Stream timed out — polling for result…")
        } catch {
            onStatus("Stream interrupted — polling for result…")
        }

        return try await pollRunResult(apiKey: apiKey, agentId: agentId, runId: runId, onStatus: onStatus)
    }

    func shouldRecreate(after error: Error) -> Bool {
        if let agentError = error as? AgentError {
            switch agentError {
            case .httpStatus(let code, let body):
                if code == 404 || code == 410 { return true }
                let lower = body.lowercased()
                return lower.contains("not found")
                    || lower.contains("inactive")
                    || lower.contains("expired")
                    || lower.contains("deleted")
                    || lower.contains("archived")
            default:
                return false
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("404")
            || message.contains("not found")
            || message.contains("inactive")
            || message.contains("archived")
    }

    // MARK: - Private

    private struct CreateAgentResponse: Decodable {
        let agent: AgentPayload?
        let run: RunPayload?
        let id: String?
        let agentId: String?
        let latestRunId: String?

        struct AgentPayload: Decodable {
            let id: String?
            let latestRunId: String?
        }

        struct RunPayload: Decodable {
            let id: String?
            let agentId: String?
        }

        var resolvedAgentId: String? {
            agent?.id ?? run?.agentId ?? id ?? agentId
        }

        var resolvedRunId: String? {
            run?.id ?? agent?.latestRunId ?? latestRunId
        }
    }

    private struct CreateRunResponse: Decodable {
        let id: String?
        let agentId: String?
        let run: RunNested?
        let agent: AgentNested?

        struct RunNested: Decodable {
            let id: String?
            let agentId: String?
        }

        struct AgentNested: Decodable {
            let id: String?
            let latestRunId: String?
        }

        var resolvedRunId: String? {
            id ?? run?.id ?? agent?.latestRunId
        }
    }

    private struct RunStatusResponse: Decodable {
        let id: String?
        let status: String?
        let result: String?
        let text: String?
        let summary: String?

        var assistantText: String? {
            let candidates = [result, text, summary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            return candidates.first { !$0.isEmpty }
        }

        var isTerminal: Bool {
            let s = (status ?? "").uppercased()
            return ["FINISHED", "COMPLETED", "ERROR", "FAILED", "CANCELLED", "CANCELED", "EXPIRED"].contains(s)
        }

        var isSuccess: Bool {
            let s = (status ?? "").uppercased()
            return ["FINISHED", "COMPLETED"].contains(s)
        }
    }

    private func getRun(apiKey: String, agentId: String, runId: String) async throws -> RunStatusResponse {
        let url = baseURL
            .appendingPathComponent("agents")
            .appendingPathComponent(agentId)
            .appendingPathComponent("runs")
            .appendingPathComponent(runId)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        applyAuth(apiKey, to: &request)
        let (data, response) = try await session.data(for: request)
        try throwIfNeeded(response: response, data: data)
        return try JSONDecoder().decode(RunStatusResponse.self, from: data)
    }

    private func streamRun(apiKey: String, agentId: String, runId: String) async throws -> String {
        let url = baseURL
            .appendingPathComponent("agents")
            .appendingPathComponent(agentId)
            .appendingPathComponent("runs")
            .appendingPathComponent(runId)
            .appendingPathComponent("stream")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600
        applyAuth(apiKey, to: &request)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw AgentError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.httpStatus(http.statusCode, "")
        }

        var eventName = "message"
        var dataLines: [String] = []
        var assembled = ""

        func flush() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines = []
            handleSSEEvent(name: eventName, data: payload, assembled: &assembled)
            eventName = "message"
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return assembled
    }

    private func pollRunResult(
        apiKey: String,
        agentId: String,
        runId: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let maxAttempts = 150
        for attempt in 1...maxAttempts {
            let run = try await getRun(apiKey: apiKey, agentId: agentId, runId: runId)
            let status = run.status ?? "unknown"
            onStatus("Run status: \(status)…")

            if run.isTerminal {
                if let text = run.assistantText, !text.isEmpty {
                    return text
                }
                if run.isSuccess {
                    throw AgentError.emptyResult
                }
                throw AgentError.httpStatus(0, "Agent run ended with status \(status)")
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
            if attempt == maxAttempts {
                throw AgentError.timedOut
            }
        }
        throw AgentError.timedOut
    }

    private func handleSSEEvent(name: String, data: String, assembled: inout String) {
        let event = name.lowercased()
        if event == "done" || data == "[DONE]" { return }
        if event == "error" { return }

        if event == "result" {
            if let raw = data.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let text = json["text"] as? String,
               !text.isEmpty {
                assembled = text
            }
            return
        }

        guard let raw = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            if !data.isEmpty, event == "assistant" || event == "message" {
                assembled += data
            }
            return
        }

        if let type = json["type"] as? String {
            if type == "assistant", let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let t = block["type"] as? String, t == "text", let text = block["text"] as? String {
                        assembled += text
                    }
                }
            }
            if type == "text-delta" || type == "assistant-delta",
               let text = (json["text"] as? String) ?? (json["delta"] as? String) {
                assembled += text
            }
        }

        if let subtype = json["subtype"] as? String, subtype == "text-delta",
           let text = json["text"] as? String {
            assembled += text
        }
    }

    private func post(path: String, apiKey: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        applyAuth(apiKey, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            try throwIfNeeded(response: response, data: data)
            return data
        } catch let error as URLError where error.code == .timedOut {
            throw AgentError.timedOut
        }
    }

    private func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw AgentError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            let clipped = message.count > 400 ? String(message.prefix(400)) + "…" : message
            throw AgentError.httpStatus(http.statusCode, clipped)
        }
    }

    private func applyAuth(_ apiKey: String, to request: inout URLRequest) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let basic = "\(trimmed):".data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
    }
}
