import Foundation

struct Usage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    /// True when the provider didn't report usage and this is a chars/4 guess.
    var estimated: Bool

    var total: Int { inputTokens + outputTokens }

    static func estimate(inputChars: Int, outputChars: Int) -> Usage {
        Usage(inputTokens: max(1, inputChars / 4),
              outputTokens: max(1, outputChars / 4),
              estimated: true)
    }
}

/// Dollars per million tokens.
struct Rate: Equatable {
    var input: Double
    var output: Double

    var isSet: Bool { input > 0 || output > 0 }

    func cost(_ usage: Usage) -> Double {
        Double(usage.inputTokens) / 1_000_000 * input
            + Double(usage.outputTokens) / 1_000_000 * output
    }

    var summary: String {
        String(format: "$%g in / $%g out per 1M", input, output)
    }
}

enum Prices {
    /// When the bundled rate card below was last checked against the vendors'
    /// own pricing pages. Shown in the settings sheet so a stale table is
    /// visible rather than silently wrong.
    static let cardDate = "9 Sep 2026"

    enum Source {
        case custom          // you overrode it
        case card            // bundled rate card
        case unknown         // model isn't in the card and has no override
    }

    // MARK: - Bundled rate cards

    /// Longest-prefix match, so `gemini-3.5-flash-lite` beats `gemini-3.5-flash`.
    /// Standard pay-as-you-go tier, text pricing. Pro entries are the
    /// under-200k-context rate; long prompts bill higher than shown.
    private static let geminiCard: [(String, Rate)] = [
        ("gemini-3.8-flash",      Rate(input: 0.75, output: 3.75)),
        ("gemini-3.7-flash",      Rate(input: 0.75, output: 3.75)),
        ("gemini-3.6-flash",      Rate(input: 0.75, output: 3.75)),
        ("gemini-3.5-flash-lite", Rate(input: 0.30, output: 2.50)),
        ("gemini-3.5-flash",      Rate(input: 1.50, output: 9.00)),
        ("gemini-3.1-flash-lite", Rate(input: 0.25, output: 1.50)),
        ("gemini-3.1-pro",        Rate(input: 2.00, output: 12.00)),
        ("gemini-3-flash",        Rate(input: 0.50, output: 3.00)),
        ("gemini-2.5-flash-lite", Rate(input: 0.10, output: 0.40)),
        ("gemini-2.5-flash",      Rate(input: 0.30, output: 2.50)),
        ("gemini-2.5-pro",        Rate(input: 1.25, output: 10.00))
    ]

    static func card(provider: Provider, model: String) -> Rate? {
        let name = model.lowercased()

        switch provider {
        case .gemini:
            return geminiCard
                .filter { name.hasPrefix($0.0) }
                .max { $0.0.count < $1.0.count }?
                .1

        case .museSpark:
            guard name.hasPrefix("muse-spark") else { return nil }
            // Contributor tier trades training rights for ~a tenth the price.
            return name.contains("contributor")
                ? Rate(input: 0.10, output: 0.20)
                : Rate(input: 1.25, output: 4.25)
        }
    }

    // MARK: - Resolution

    static func rate(provider: Provider, model: String) -> Rate {
        if let custom = override(provider: provider, model: model) { return custom }
        return card(provider: provider, model: model) ?? Rate(input: 0, output: 0)
    }

    static func source(provider: Provider, model: String) -> Source {
        if override(provider: provider, model: model) != nil { return .custom }
        return card(provider: provider, model: model) != nil ? .card : .unknown
    }

    /// nil means "no override stored" — distinct from an override of zero.
    static func override(provider: Provider, model: String) -> Rate? {
        let defaults = UserDefaults.standard
        let inKey = key("in", provider, model)
        let outKey = key("out", provider, model)
        guard defaults.object(forKey: inKey) != nil || defaults.object(forKey: outKey) != nil else {
            return nil
        }
        return Rate(input: defaults.double(forKey: inKey),
                    output: defaults.double(forKey: outKey))
    }

    static func setOverride(_ rate: Rate?, provider: Provider, model: String) {
        let defaults = UserDefaults.standard
        guard let rate else {
            defaults.removeObject(forKey: key("in", provider, model))
            defaults.removeObject(forKey: key("out", provider, model))
            return
        }
        defaults.set(rate.input, forKey: key("in", provider, model))
        defaults.set(rate.output, forKey: key("out", provider, model))
    }

    private static func key(_ side: String, _ provider: Provider, _ model: String) -> String {
        "rate.\(side).\(provider.rawValue).\(model)"
    }

    // MARK: - Formatting

    static func money(_ amount: Double) -> String {
        if amount <= 0 { return "$0.00" }
        if amount < 0.0001 { return "<$0.0001" }
        if amount < 1 { return String(format: "$%.4f", amount) }
        return String(format: "$%.2f", amount)
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
