import Foundation

/// AWS Bedrock embedding client using Amazon Titan Embed Text v2 (512d).
actor BedrockEmbeddingClient {

    private let modelId = "amazon.titan-embed-text-v2:0"
    private let dimensions = 512

    enum EmbeddingError: Error, LocalizedError {
        case httpError(Int, String)
        case missingCredentials
        case decodingError

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let msg): "Bedrock Embed error (HTTP \(code)): \(msg)"
            case .missingCredentials: "AWS credentials not configured"
            case .decodingError: "Failed to decode embedding response"
            }
        }
    }

    /// Embed a single text via Bedrock InvokeModel.
    func embed(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        text: String
    ) async throws -> [Float] {
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw EmbeddingError.missingCredentials
        }

        let body: [String: Any] = [
            "inputText": text,
            "dimensions": dimensions,
            "normalize": true
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let encodedModel = modelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelId
        let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/invoke")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            throw EmbeddingError.httpError(-1, "No HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EmbeddingError.httpError(httpResponse.statusCode, msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else {
            throw EmbeddingError.decodingError
        }

        return embedding.map { Float($0) }
    }

    /// Embed multiple texts with bounded concurrency.
    func embedBatch(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        texts: [String],
        maxConcurrency: Int = 8
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var results: [(Int, [Float])] = []

        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            var submitted = 0

            for (index, text) in texts.enumerated() {
                if submitted >= maxConcurrency {
                    if let result = try await group.next() {
                        results.append(result)
                    }
                }

                group.addTask {
                    let embedding = try await self.embed(
                        accessKeyId: accessKeyId,
                        secretAccessKey: secretAccessKey,
                        region: region,
                        text: text
                    )
                    return (index, embedding)
                }
                submitted += 1
            }

            for try await result in group {
                results.append(result)
            }
        }

        return results.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
