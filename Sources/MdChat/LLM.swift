import Foundation

/// One SSE reader, two request shapes. Gemini uses `streamGenerateContent`;
/// Muse Spark speaks OpenAI-compatible `/chat/completions`.
enum LLM {
    struct Turn {
        let role: String   // "user" or "model"
        let text: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Event {
        case text(String)
        case usage(Usage)
    }

    static func stream(provider: Provider,
                       apiKey: String,
                       model: String,
                       system: String?,
                       turns: [Turn]) -> AsyncThrowingStream<Event, Error>
    {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let req = try request(provider: provider, apiKey: apiKey,
                                          model: model, system: system, turns: turns)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw Failure(message: errorMessage(in: body)
                                      ?? "\(provider.displayName) returned HTTP \(status).")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        for event in try events(provider: provider, in: data) {
                            continuation.yield(event)
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

    // MARK: - Requests

    private static func request(provider: Provider,
                                apiKey: String,
                                model: String,
                                system: String?,
                                turns: [Turn]) throws -> URLRequest
    {
        var req: URLRequest
        var body: [String: Any]

        switch provider {
        case .gemini:
            let path = "https://generativelanguage.googleapis.com/v1beta/models/"
                + model + ":streamGenerateContent?alt=sse"
            guard let url = URL(string: path) else {
                throw Failure(message: "Bad model name: \(model)")
            }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            body = [
                "contents": turns.map { ["role": $0.role, "parts": [["text": $0.text]]] },
                "generationConfig": ["temperature": 0.3]
            ]
            if let system, !system.isEmpty {
                body["systemInstruction"] = ["parts": [["text": system]]]
            }

        case .museSpark:
            guard let url = URL(string: "https://api.meta.ai/v1/chat/completions") else {
                throw Failure(message: "Bad endpoint.")
            }
            req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            var messages: [[String: Any]] = []
            if let system, !system.isEmpty {
                messages.append(["role": "system", "content": system])
            }
            messages += turns.map {
                ["role": $0.role == "model" ? "assistant" : "user", "content": $0.text]
            }
            body = [
                "model": model,
                "messages": messages,
                "stream": true,
                "stream_options": ["include_usage": true],
                "temperature": 0.3
            ]
        }

        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        return req
    }

    // MARK: - Frames

    /// One SSE frame -> the text it adds and/or the usage it reports. Both
    /// providers put usage in a trailing frame, so a frame can be text-only,
    /// usage-only, or neither.
    private static func events(provider: Provider, in data: Data) throws -> [Event] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let message = (json["error"] as? [String: Any])?["message"] as? String {
            throw Failure(message: message)
        }

        var out: [Event] = []

        switch provider {
        case .gemini:
            if let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                throw Failure(message: "Request blocked: \(reason).")
            }

            if let candidate = (json["candidates"] as? [[String: Any]])?.first {
                let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined()

                if text.isEmpty, let finish = candidate["finishReason"] as? String,
                   finish != "STOP", finish != "MAX_TOKENS" {
                    throw Failure(message: "Stopped early: \(finish).")
                }
                if !text.isEmpty { out.append(.text(text)) }
            }

            if let meta = json["usageMetadata"] as? [String: Any] {
                let input = meta["promptTokenCount"] as? Int ?? 0
                // Reasoning tokens are billed as output, so fold them in.
                let output = (meta["candidatesTokenCount"] as? Int ?? 0)
                    + (meta["thoughtsTokenCount"] as? Int ?? 0)
                if input > 0 || output > 0 {
                    out.append(.usage(Usage(inputTokens: input, outputTokens: output,
                                            estimated: false)))
                }
            }

        case .museSpark:
            if let choice = (json["choices"] as? [[String: Any]])?.first {
                if let reason = choice["finish_reason"] as? String, reason == "content_filter" {
                    throw Failure(message: "Response filtered by the provider.")
                }
                let chunk = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any]
                if let text = chunk?["content"] as? String, !text.isEmpty {
                    out.append(.text(text))
                }
            }

            if let usage = json["usage"] as? [String: Any] {
                let input = usage["prompt_tokens"] as? Int ?? 0
                let output = usage["completion_tokens"] as? Int ?? 0
                if input > 0 || output > 0 {
                    out.append(.usage(Usage(inputTokens: input, outputTokens: output,
                                            estimated: false)))
                }
            }
        }

        return out
    }

    private static func errorMessage(in body: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        if let message = (json?["error"] as? [String: Any])?["message"] as? String { return message }
        if let message = json?["message"] as? String { return message }
        return nil
    }
}
