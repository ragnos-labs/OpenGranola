import Foundation

/// AWS Bedrock Converse API client for LLM completions.
actor BedrockClient {

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    enum BedrockError: Error, LocalizedError {
        case httpError(Int, String)
        case missingCredentials
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let msg): "Bedrock API error (HTTP \(code)): \(msg)"
            case .missingCredentials: "AWS credentials not configured"
            case .emptyResponse: "Empty response from Bedrock"
            }
        }
    }

    /// Non-streaming completion via Bedrock Converse API.
    func complete(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        model: String,
        messages: [Message],
        maxTokens: Int = 512
    ) async throws -> String {
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw BedrockError.missingCredentials
        }

        // Separate system messages from conversation messages
        var systemBlocks: [[String: String]] = []
        var conversationMessages: [[String: Any]] = []

        for msg in messages {
            if msg.role == "system" {
                systemBlocks.append(["text": msg.content])
            } else {
                conversationMessages.append([
                    "role": msg.role,
                    "content": [["text": msg.content]]
                ])
            }
        }

        var body: [String: Any] = [
            "messages": conversationMessages,
            "inferenceConfig": [
                "maxTokens": maxTokens,
                "temperature": 0
            ] as [String: Any]
        ]
        if !systemBlocks.isEmpty {
            body["system"] = systemBlocks
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/converse")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        AWSSigV4.sign(
            request: &request,
            body: bodyData,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            region: region,
            service: "bedrock"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BedrockError.httpError(-1, "No HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BedrockError.httpError(httpResponse.statusCode, msg)
        }

        // Parse Converse API response: { output: { message: { content: [{ text: "..." }] } } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw BedrockError.emptyResponse
        }

        return text
    }
}
