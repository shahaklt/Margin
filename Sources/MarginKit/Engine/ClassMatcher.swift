import Foundation
import NaturalLanguage

/// Picks a class from transcript content without any language model.
/// Class names are mapped to a built-in subject (e.g. "AP Physics 1" → physics, "APUSH" → US history),
/// and each subject has a vocabulary of characteristic word stems. The class whose vocabulary
/// (plus the user's own topic keywords) appears most often wins — only if it clearly beats the rest.
/// Classes with unrecognized names fall back to Apple's on-device word embeddings.
enum ClassMatcher {
    // MARK: Subjects

    /// Words in a class name → subject key.
    private static let nameToSubject: [(String, String)] = [
        ("apush", "ushistory"), ("ush", "ushistory"), ("american history", "ushistory"), ("us history", "ushistory"), ("u.s. history", "ushistory"),
        ("euro", "worldhistory"), ("world history", "worldhistory"), ("whap", "worldhistory"), ("history", "worldhistory"), ("hist", "worldhistory"),
        ("gov", "government"), ("civics", "government"), ("politic", "government"),
        ("physics", "physics"), ("phys", "physics"),
        ("stat", "statistics"), ("probability", "statistics"),
        ("calc", "calculus"), ("precalc", "precalculus"), ("pre-calc", "precalculus"), ("trig", "precalculus"),
        ("algebra", "algebra"), ("geometry", "geometry"), ("math", "algebra"),
        ("bio", "biology"), ("anatomy", "anatomy"), ("physiology", "anatomy"),
        ("chem", "chemistry"),
        ("apes", "environmental"), ("environmental", "environmental"), ("enviro", "environmental"), ("earth", "environmental"),
        ("econ", "economics"), ("macro", "economics"), ("micro", "economics"),
        ("psych", "psychology"), ("socio", "sociology"),
        ("lit", "literature"), ("english", "literature"), ("lang", "literature"), ("writing", "literature"), ("rhetoric", "literature"),
        ("spanish", "spanish"), ("french", "french"), ("german", "german"), ("latin", "latin"), ("chinese", "chinese"), ("mandarin", "chinese"),
        ("csa", "cs"), ("csp", "cs"), ("computer", "cs"), ("programming", "cs"), ("coding", "cs"), ("cs ", "cs"),
        ("geography", "geography"), ("hug", "geography"), ("art history", "arthistory"), ("music", "music"), ("theory", "music"),
        ("philosophy", "philosophy"), ("health", "anatomy"),
    ]

    /// Characteristic stems per subject (matched as word prefixes, so "chromosom" matches "chromosomes").
    private static let vocab: [String: [String]] = [
        "physics": ["force", "newton", "accelerat", "velocit", "momentum", "kinetic", "potential energy", "friction", "torque", "gravit", "mass", "joule", "watt", "displacement", "projectile", "kinematic", "inertia", "circuit", "voltage", "current", "resist", "ohm", "wave", "frequenc", "amplitude", "oscillat", "pendulum", "spring", "free body", "normal force", "tension", "incline", "collision", "impulse", "rotation", "angular", "meters per second", "vector", "work-energy", "power"],
        "statistics": ["sample", "sampling", "population", "mean", "median", "standard deviation", "variance", "confidence interval", "margin of error", "hypothesis", "null", "p-value", "p value", "significan", "distribution", "normal model", "z-score", "z score", "t-test", "chi-square", "chi square", "regression", "correlation", "residual", "outlier", "probabilit", "random", "binomial", "geometric", "survey", "bias", "experiment", "control group", "placebo", "stratified", "quartile", "boxplot", "histogram", "scatterplot", "inference", "parameter", "statistic"],
        "government": ["constitution", "congress", "senate", "house of representatives", "president", "supreme court", "federalis", "amendment", "bill of rights", "checks and balances", "separation of powers", "judicial", "legislat", "executive", "veto", "filibuster", "election", "electoral", "vote", "voting", "campaign", "party", "parties", "democrat", "republican", "lobby", "interest group", "civil liberties", "civil rights", "due process", "precedent", "marbury", "bureaucra", "policy", "public opinion", "media", "political", "government", "states' rights", "commerce clause", "free response"],
        "ushistory": ["colon", "revolution", "independence", "civil war", "reconstruction", "slavery", "abolition", "jefferson", "lincoln", "washington", "roosevelt", "new deal", "depression", "progressive", "industrial", "immigra", "manifest destiny", "westward", "parliament", "tea party", "stamp act", "continental", "union", "confedera", "segregation", "civil rights movement", "cold war", "vietnam", "world war", "treaty", "president", "frontier", "gilded age"],
        "worldhistory": ["empire", "dynasty", "revolution", "feudal", "renaissance", "reformation", "enlightenment", "imperialism", "colonial", "monarch", "napoleon", "world war", "treaty", "industrial", "ottoman", "roman", "greek", "mongol", "silk road", "trade", "civilization", "nationalism", "communis", "fascis", "cold war", "decoloniz", "crusade", "medieval", "absolutism"],
        "biology": ["cell", "mitos", "meios", "chromosom", "dna", "rna", "gene", "genetic", "protein", "enzyme", "membrane", "organelle", "mitochondri", "nucleus", "ribosom", "photosynthe", "respiration", "atp", "evolution", "natural selection", "species", "allele", "dominant", "recessive", "mutation", "ecosystem", "organism", "cytoplasm", "cytokines", "prophase", "metaphase", "anaphase", "telophase", "gamete", "replicat", "transcription", "translation", "homeostasis"],
        "anatomy": ["muscle", "bone", "skelet", "nerve", "neuron", "brain", "heart", "blood", "artery", "vein", "organ", "tissue", "hormone", "digest", "respirat", "immune", "kidney", "lung", "joint", "spinal"],
        "chemistry": ["atom", "electron", "proton", "neutron", "molecule", "bond", "covalent", "ionic", "mole", "molar", "stoichiometr", "reaction", "reactant", "product", "equilibrium", "acid", "base", "ph", "titration", "oxidation", "reduction", "periodic table", "element", "compound", "enthalpy", "entropy", "gibbs", "catalyst", "gas law", "orbital", "valence", "solution", "concentration", "isotope"],
        "calculus": ["derivative", "integral", "limit", "differentiat", "antiderivative", "chain rule", "product rule", "quotient rule", "tangent", "slope", "rate of change", "continuity", "continuous", "series", "converge", "diverge", "taylor", "riemann", "area under", "related rates", "optimization", "fundamental theorem", "l'hopital", "polar", "parametric", "differential equation"],
        "precalculus": ["function", "trig", "sine", "cosine", "tangent", "radian", "unit circle", "logarithm", "exponential", "polynomial", "asymptote", "inverse", "domain", "range", "vector", "matrix", "conic", "sequence"],
        "algebra": ["equation", "variable", "solve for", "slope", "intercept", "linear", "quadratic", "factor", "polynomial", "exponent", "inequalit", "function", "graph", "coefficient", "parabola", "system of equations"],
        "geometry": ["angle", "triangle", "congruent", "similar", "proof", "theorem", "parallel", "perpendicular", "circle", "radius", "diameter", "area", "volume", "polygon", "pythagore", "hypotenuse", "postulate"],
        "environmental": ["ecosystem", "biome", "biodiversity", "pollution", "climate", "carbon", "greenhouse", "renewable", "fossil fuel", "sustainab", "watershed", "soil", "deforestation", "population growth", "carrying capacity", "food web", "trophic", "conservation", "emission"],
        "economics": ["supply", "demand", "market", "price", "elastic", "equilibrium", "gdp", "inflation", "unemployment", "fiscal", "monetary", "federal reserve", "interest rate", "marginal", "cost", "revenue", "profit", "monopoly", "competition", "tax", "tariff", "trade", "opportunity cost", "aggregate"],
        "psychology": ["behavior", "cognitive", "memory", "conditioning", "pavlov", "skinner", "freud", "neuron", "brain", "personality", "disorder", "therapy", "perception", "sensation", "development", "piaget", "motivation", "emotion", "research method", "nature versus nurture"],
        "sociology": ["society", "social", "culture", "norm", "deviance", "institution", "inequality", "stratification", "race", "gender", "class"],
        "literature": ["novel", "poem", "poetry", "author", "character", "theme", "symbol", "metaphor", "imagery", "narrator", "protagonist", "plot", "essay", "thesis", "rhetoric", "argument", "tone", "diction", "syntax", "paragraph", "chapter", "shakespeare", "stanza", "irony", "claim", "evidence", "analysis"],
        "cs": ["code", "program", "algorithm", "variable", "loop", "array", "function", "method", "class", "object", "java", "python", "recursion", "boolean", "string", "integer", "compile", "debug", "data structure", "inheritance", "binary"],
        "spanish": ["spanish", "español", "verb", "conjugat", "preterite", "subjunctive", "vocabulario", "gramática", "hola"],
        "french": ["french", "français", "verb", "conjugat", "passé composé", "subjonctif", "bonjour"],
        "german": ["german", "deutsch", "verb", "conjugat", "akkusativ", "dativ"],
        "latin": ["latin", "declension", "conjugat", "nominative", "accusative", "ablative", "caesar", "virgil"],
        "chinese": ["chinese", "mandarin", "character", "pinyin", "tone"],
        "geography": ["population", "migration", "urban", "rural", "culture", "diffusion", "region", "map", "scale", "agriculture", "development", "density", "settlement"],
        "arthistory": ["painting", "sculpture", "artist", "baroque", "renaissance", "gothic", "composition", "fresco", "architecture", "patron"],
        "music": ["chord", "scale", "key", "interval", "melody", "harmony", "rhythm", "tempo", "cadence", "major", "minor", "triad", "measure"],
        "philosophy": ["ethics", "moral", "plato", "aristotle", "kant", "argument", "premise", "logic", "metaphysic", "epistemolog", "virtue", "utilitarian"],
    ]

    private static let embedding = NLEmbedding.wordEmbedding(for: .english)
    private static let generic: Set<String> = ["ap", "ib", "honors", "hon", "class", "intro", "introduction", "the", "of", "and", "to", "for", "in", "a", "an", "i", "ii", "iii", "iv", "us", "ab", "bc", "advanced", "placement", "course", "period", "block", "college", "dual", "enrollment"]

    static func subject(forClassName name: String) -> String? {
        let n = " " + name.lowercased() + " "
        // Prefer the longest (most specific) matching phrase, e.g. "us history" over "history".
        return nameToSubject.filter { n.contains($0.0) }.max { $0.0.count < $1.0.count }?.1
    }

    // MARK: Scoring

    static func scores(transcript: String, classes: [ClassFolder]) -> [(ClassFolder, Double)] {
        let text = " " + transcript.lowercased().replacingOccurrences(of: #"[^a-z0-9'\- ]+"#, with: " ", options: .regularExpression) + " "
        let tokens = text.split(separator: " ").map(String.init)
        let wordCount = max(1, tokens.count)

        func occurrences(_ stem: String) -> Int {
            if stem.contains(" ") || stem.count <= 3 {
                // Phrases and very short stems ("dna", "ph") must match whole words.
                return text.components(separatedBy: " \(stem) ").count - 1
            }
            return tokens.reduce(0) { $0 + ($1.hasPrefix(stem) ? 1 : 0) }
        }

        return classes.map { c in
            var stems = c.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var score = Double(stems.reduce(0) { $0 + occurrences($1) }) * 1.5 // the user's own topics count extra
            if let s = subject(forClassName: c.name), let words = vocab[s] {
                stems += words
                // Count each distinct stem at most 4 times so one repeated word can't dominate.
                score += Double(words.reduce(0) { $0 + min(4, occurrences($1)) })
            } else if let embedding {
                score += semanticScore(tokens: tokens, className: c.name, embedding: embedding)
            }
            // Per-1000-words density keeps long and short recordings comparable.
            return (c, score * 1000 / Double(wordCount))
        }.sorted { $0.1 > $1.1 }
    }

    static func best(transcript: String, classes: [ClassFolder]) -> ClassFolder? {
        let ranked = scores(transcript: transcript, classes: classes)
        guard let first = ranked.first, first.1 >= 12 else { return nil }
        if ranked.count > 1, first.1 < ranked[1].1 * 1.6 { return nil }
        return first.0
    }

    /// For class names we don't recognize: similarity of frequent words to the name's words.
    private static func semanticScore(tokens: [String], className: String, embedding: NLEmbedding) -> Double {
        let terms = className.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { !generic.contains($0) && $0.count > 2 && embedding.contains($0) }
        guard !terms.isEmpty else { return 0 }
        var freq: [String: Int] = [:]
        for t in tokens where t.count > 4 && embedding.contains(t) { freq[t, default: 0] += 1 }
        var score = 0.0
        for (word, count) in freq.sorted(by: { $0.value > $1.value }).prefix(50) {
            let d = terms.map { embedding.distance(between: word, and: $0) }.min() ?? 2
            if d < 0.95 { score += Double(min(count, 4)) * (0.95 - d) * 4 }
        }
        return score
    }
}
