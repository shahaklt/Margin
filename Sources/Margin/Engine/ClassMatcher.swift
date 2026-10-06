import Foundation
import NaturalLanguage

/// Picks a class from transcript content without any language model:
/// explicit keyword hits plus semantic similarity from Apple's on-device word embeddings
/// (so "mitosis" and "chromosomes" pull toward "Biology" even with no keywords set).
enum ClassMatcher {
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    /// Common school abbreviations → a word the embedding knows.
    private static let expansions: [String: String] = [
        "apush": "history", "ush": "history", "euro": "history", "calc": "calculus", "chem": "chemistry",
        "bio": "biology", "lit": "literature", "lang": "language", "econ": "economics", "macro": "economics",
        "micro": "economics", "gov": "government", "psych": "psychology", "stats": "statistics", "stat": "statistics",
        "cs": "programming", "csa": "programming", "csp": "programming", "comp": "computer", "sci": "science",
        "phys": "physics", "geo": "geography", "trig": "trigonometry", "precalc": "algebra", "apes": "environmental",
        "env": "environmental", "anat": "anatomy", "phil": "philosophy", "soc": "sociology", "hum": "humanities",
    ]
    private static let generic: Set<String> = ["ap", "ib", "honors", "hon", "class", "intro", "introduction", "the", "of", "and", "to", "for", "in", "a", "an", "i", "ii", "iii", "iv", "us", "ab", "bc", "advanced", "placement", "course", "period", "block", "college", "dual", "enrollment"]
    /// Reference subjects used as a baseline so generic words ("homework", "today") cancel out.
    private static let baseline = ["history", "mathematics", "literature", "chemistry", "physics", "biology", "art", "music", "economics", "computer", "language", "psychology", "government", "philosophy"]
    private static let stop: Set<String> = ["that", "this", "with", "have", "what", "when", "they", "there", "their", "about", "would", "could", "should", "which", "where", "because", "going", "really", "right", "think", "know", "like", "just", "okay", "yeah", "then", "than", "them", "were", "been", "being", "also", "into", "your", "from", "will", "some", "more", "very", "here", "does", "make", "said", "these", "those", "other", "after", "before", "today", "everyone", "question", "great", "sorry", "please", "next", "last", "time", "thing", "things", "kind", "want", "need", "look", "good"]

    static func best(transcript: String, classes: [ClassFolder]) -> ClassFolder? {
        guard !classes.isEmpty else { return nil }
        let text = " " + transcript.lowercased() + " "
        let words = text.split { !$0.isLetter }.map(String.init).filter { $0.count > 3 && !stop.contains($0) }
        var freq: [String: Int] = [:]
        words.forEach { freq[$0, default: 0] += 1 }
        let top = freq.sorted { $0.value > $1.value }.prefix(60)

        let scored: [(ClassFolder, Double)] = classes.map { c in
            let keywords = c.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let nameTerms = c.name.lowercased().split { !$0.isLetter }.map(String.init)
                .filter { !generic.contains($0) && $0.count > 1 }
                .map { expansions[$0] ?? $0 }
            let terms = Array(Set(nameTerms + keywords.flatMap { $0.split(separator: " ").map(String.init) }))

            // 1) Literal hits of keywords / name words.
            let hits = (keywords + nameTerms.filter { $0.count > 3 }).reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }

            // 2) Semantic pull relative to the baseline subjects.
            var semantic = 0.0
            if let embedding {
                let known = terms.filter { embedding.contains($0) }
                for (word, count) in top where embedding.contains(word) && !known.isEmpty {
                    let sim = known.map { 1 - embedding.distance(between: word, and: $0) }.max() ?? 0
                    let base = baseline.map { 1 - embedding.distance(between: word, and: $0) }.reduce(0, +) / Double(baseline.count)
                    semantic += max(-0.2, sim - base) * Double(count)
                }
            }
            return (c, Double(hits) * 0.6 + semantic)
        }.sorted { $0.1 > $1.1 }

        guard let first = scored.first, first.1 > 0.6 else { return nil }
        // Require a clear winner when several classes compete.
        if scored.count > 1, first.1 - scored[1].1 < 0.35 { return nil }
        return first.0
    }
}
