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

    static func generate(apiKey: String, model: String, system: String?, turns: [Turn]) async throws -> String {
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
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
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard status == 200 else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure(message: detail ?? "Gemini returned HTTP \(status).")
        }

        guard let candidates = json?["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            let reason = (json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw Failure(message: reason.map { "Request blocked: \($0)." } ?? "Empty response from Gemini.")
        }

        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()

        if text.isEmpty {
            let finish = first["finishReason"] as? String ?? "unknown"
            throw Failure(message: "No text in response (finishReason: \(finish)).")
        }
        return text
    }
}
