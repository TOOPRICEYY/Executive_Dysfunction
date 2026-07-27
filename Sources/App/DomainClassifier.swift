import Foundation
import FoundationModels

struct DomainClassifier {
    static func normalizedDomains(from text: String) -> [String] {
        let candidates = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",;")))
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let input = candidate.contains("://") ? candidate : "https://\(candidate)"
            guard let host = URL(string: input)?.host?.lowercased() else { return nil }
            let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard normalized.contains("."), seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    static func classify(_ domains: [String]) async -> [ClassifiedDomain] {
        guard !domains.isEmpty else { return [] }
        if #available(iOS 26.0, *), let aiResults = await classifyWithAppleIntelligence(domains) {
            return aiResults
        }
        return domains.map {
            ClassifiedDomain(domain: $0, category: heuristicCategory(for: $0), source: .heuristic)
        }
    }

    @available(iOS 26.0, *)
    private static func classifyWithAppleIntelligence(_ domains: [String]) async -> [ClassifiedDomain]? {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard model.isAvailable else { return nil }

        let session = LanguageModelSession(
            model: model,
            instructions: "Classify website domains by their likely primary purpose. Never browse or invent extra domains."
        )
        let prompt = """
        Classify each domain into exactly one category from this list:
        \(WebsiteCategory.promptValues)

        Return exactly one line per input in the form domain|category, with no prose.
        Domains:
        \(domains.joined(separator: "\n"))
        """

        do {
            let response = try await session.respond(to: prompt)
            let parsed = parse(response.content, expectedDomains: domains)
            return parsed.count == domains.count ? parsed : nil
        } catch {
            return nil
        }
    }

    private static func parse(_ output: String, expectedDomains: [String]) -> [ClassifiedDomain] {
        var categories: [String: WebsiteCategory] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*`"))
            let pieces = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let domain = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let category = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = WebsiteCategory(rawValue: category) {
                categories[domain] = value
            }
        }

        return expectedDomains.compactMap { domain in
            guard let category = categories[domain] else { return nil }
            return ClassifiedDomain(domain: domain, category: category, source: .appleIntelligence)
        }
    }

    private static func heuristicCategory(for domain: String) -> WebsiteCategory {
        let rules: [(WebsiteCategory, [String])] = [
            (.social, ["facebook", "instagram", "tiktok", "twitter", "x.com", "reddit", "threads", "snapchat", "mastodon"]),
            (.video, ["youtube", "netflix", "hulu", "twitch", "vimeo", "disneyplus", "max.com"]),
            (.news, ["news", "cnn", "bbc", "reuters", "nytimes", "washingtonpost"]),
            (.shopping, ["amazon", "ebay", "etsy", "walmart", "target", "shop"]),
            (.gaming, ["game", "steam", "ign", "roblox", "twitch"]),
            (.adult, ["porn", "xxx", "adult"]),
            (.aiTools, ["openai", "chatgpt", "claude", "gemini", "perplexity", "copilot"]),
            (.productivity, ["notion", "slack", "asana", "trello", "office", "docs.google.com"]),
            (.education, [".edu", "coursera", "udemy", "khanacademy", "wikipedia"]),
            (.finance, ["bank", "finance", "invest", "coinbase", "paypal"]),
            (.health, ["health", "medical", "fitness", "wellness"])
        ]
        return rules.first { _, needles in
            needles.contains { matches(domain, needle: $0) }
        }?.0 ?? .other
    }

    /// Dotted needles match whole domains or subdomains; bare needles match anywhere in the name.
    private static func matches(_ domain: String, needle: String) -> Bool {
        if needle.hasPrefix(".") { return domain.hasSuffix(needle) }
        if needle.contains(".") { return domain == needle || domain.hasSuffix(".\(needle)") }
        return domain.contains(needle)
    }
}

