import Foundation

enum Gemini {
    struct Turn {
        let role: String   // "user" or "model"
        let text: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Yields text deltas as they arrive. Cancel the consuming Task to stop the request.
    static func stream(apiKey: String, model: String, system: String?, turns: [Turn])
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let req = try request(apiKey: apiKey, model: model, system: system, turns: turns)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw Failure(message: errorMessage(in: body) ?? "Gemini returned HTTP \(status).")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]",
                              let data = payload.data(using: .utf8) else { continue }
                        if let text = try delta(in: data) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Private

    private static func request(apiKey: String, model: String, system: String?, turns: [Turn]) throws -> URLRequest {
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: path) else {
            throw Failure(message: "Bad model name: \(model)")
        }

        var body: [String: Any] = [
            "contents": turns.map { ["role": $0.role, "parts": [["text": $0.text]]] },
            "generationConfig": ["temperature": 0.3]
        ]
        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        return req
    }

    /// One SSE frame -> the text it adds, or nil for frames carrying only metadata.
    private static func delta(in data: Data) throws -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let message = (json["error"] as? [String: Any])?["message"] as? String {
            throw Failure(message: message)
        }
        if let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw Failure(message: "Request blocked: \(reason).")
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return nil }

        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()

        if text.isEmpty, let finish = candidate["finishReason"] as? String,
           finish != "STOP", finish != "MAX_TOKENS" {
            throw Failure(message: "Stopped early: \(finish).")
        }
        return text.isEmpty ? nil : text
    }

    private static func errorMessage(in body: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String
    }
}
