import Foundation

struct OmniboxCandidate: Equatable {
    var id: String
    var kind: OmniboxSuggestionKind
    var title: String
    var subtitle: String
    var url: URL?
    var tabID: UUID?
    var visitedAt: Date?
}

enum OmniboxRanker {
    static func ranked(_ candidates: [OmniboxCandidate], query: String, limit: Int = 10) -> [OmniboxCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var bestByKey: [String: (candidate: OmniboxCandidate, score: Int)] = [:]

        for candidate in candidates {
            let score = self.score(query: needle, candidate: candidate)
            guard score > 0 else { continue }
            let key = dedupeKey(candidate)
            if let existing = bestByKey[key], existing.score >= score {
                continue
            }
            bestByKey[key] = (candidate, score)
        }

        return bestByKey.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return kindPriority($0.candidate.kind) < kindPriority($1.candidate.kind)
            }
            .prefix(limit)
            .map(\.candidate)
    }

    static func score(query: String, candidate: OmniboxCandidate) -> Int {
        switch candidate.kind {
        case .navigate:
            return looksLikeURL(query) ? 860 + matchScore(query: query, candidate: candidate) / 10 : 40
        case .search:
            guard !query.isEmpty else { return 0 }
            return looksLikeURL(query) ? 30 : 820
        default:
            let match = matchScore(query: query, candidate: candidate)
            guard match > 0 || query.isEmpty else { return 0 }
            return match + kindBonus(candidate.kind) + recencyBonus(candidate.visitedAt)
        }
    }

    static func matchScore(query: String, candidate: OmniboxCandidate) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 10 }

        let title = candidate.title.lowercased()
        let host = (candidate.url?.host ?? "").lowercased()
        let urlText = (candidate.url?.absoluteString ?? "").lowercased()
        let scores = [
            textScore(needle: needle, text: title),
            textScore(needle: needle, text: host) + (host == needle || host.hasPrefix("www.\(needle)") ? 80 : 0),
            textScore(needle: needle, text: urlText) / 2
        ]
        return scores.max() ?? 0
    }

    private static func textScore(needle: String, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if text == needle { return 1000 }
        if text.hasPrefix(needle) { return 820 }
        if text.hasPrefix("www.\(needle)") { return 800 }
        if wordBoundaryMatch(needle: needle, text: text) { return 620 }
        if text.contains(needle) { return 220 }
        return 0
    }

    private static func wordBoundaryMatch(needle: String, text: String) -> Bool {
        let separators: [Character] = [" ", ".", "-", "_", "/", ":", "?", "&"]
        guard let range = text.range(of: needle) else { return false }
        if range.lowerBound == text.startIndex { return true }
        let previous = text[text.index(before: range.lowerBound)]
        return separators.contains(previous)
    }

    private static func kindBonus(_ kind: OmniboxSuggestionKind) -> Int {
        switch kind {
        case .openTab: 140
        case .bookmark: 80
        case .history: 35
        case .navigate: 0
        case .search: 0
        }
    }

    private static func recencyBonus(_ date: Date?) -> Int {
        guard let date else { return 0 }
        let age = Date().timeIntervalSince(date)
        if age < 3600 { return 90 }
        if age < 86_400 { return 45 }
        if age < 604_800 { return 18 }
        return 0
    }

    private static func kindPriority(_ kind: OmniboxSuggestionKind) -> Int {
        switch kind {
        case .openTab: 0
        case .bookmark: 1
        case .history: 2
        case .navigate: 3
        case .search: 4
        }
    }

    private static func dedupeKey(_ candidate: OmniboxCandidate) -> String {
        switch candidate.kind {
        case .openTab:
            return "tab:\(candidate.tabID?.uuidString ?? candidate.id)"
        case .navigate:
            return "navigate"
        case .search:
            return "search"
        case .bookmark, .history:
            if let url = candidate.url {
                return "url:\(url.absoluteString)"
            }
            return candidate.id
        }
    }

    private static func looksLikeURL(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(" ") { return false }
        if trimmed.hasPrefix("localhost") || trimmed.contains("://") { return true }
        let hostPart = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return hostPart.contains(".") || (hostPart.contains(":") && !hostPart.contains(" "))
    }
}
