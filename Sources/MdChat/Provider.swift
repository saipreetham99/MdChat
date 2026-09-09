import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case gemini
    case museSpark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .museSpark: return "Muse Spark"
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.8-flash"
        case .museSpark: return "muse-spark-1.3-contributor"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: return "AIza…"
        case .museSpark: return "Model API key"
        }
    }

    var keySource: String {
        switch self {
        case .gemini: return "aistudio.google.com/apikey"
        case .museSpark: return "Meta Model API — MODEL_API_KEY"
        }
    }

    var modelHint: String {
        switch self {
        case .gemini:
            return "Any name from the /v1beta/models list, without the models/ prefix. "
                + "Aliases like gemini-flash-latest work but can't be priced."
        case .museSpark:
            return "Standard tier: muse-spark-1.3. Contributor tier: append -contributor."
        }
    }
}
