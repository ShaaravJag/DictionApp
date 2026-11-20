import Foundation

/// Your personal vocabulary: words and names to recognize, Casual-only slang,
/// and fixed spelling replacements. Parsed from a simple Markdown file.
public struct Vocabulary: Sendable, Equatable {
    public struct Term: Sendable, Equatable, Hashable {
        /// How it should be written.
        public var text: String
        /// Spellings the speech model tends to produce instead ("sounds like").
        public var aliases: [String]

        public init(_ text: String, aliases: [String] = []) {
            self.text = text
            self.aliases = aliases
        }
    }

    public struct Replacement: Sendable, Equatable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Used in every app.
    public var words: [Term] = []
    /// Used only in Casual apps.
    public var slang: [Term] = []
    /// Always applied: heard -> written.
    public var replacements: [Replacement] = []

    public init(words: [Term] = [], slang: [Term] = [], replacements: [Replacement] = []) {
        self.words = words
        self.slang = slang
        self.replacements = replacements
    }

    public var isEmpty: Bool { words.isEmpty && slang.isEmpty && replacements.isEmpty }

    private enum Section { case none, words, slang, replacements }

    /// Parses the vocabulary file.
    ///
    /// - `## Words` / `## Slang`: one term per line, optionally `Term | alias, alias`.
    /// - `## Replacements`: `heard -> written`.
    /// - `#` headings, `>` notes, `<!-- -->` comments and blank lines are ignored.
    ///   Lines before the first section, and plain prose lines that contain a
    ///   period or colon (explanations), are ignored too.
    public static func parse(markdown: String) -> Vocabulary {
        var vocabulary = Vocabulary()
        var section = Section.none
        var inComment = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)

            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                if !line.contains("-->") { inComment = true }
                continue
            }

            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                if title.hasPrefix("word") || title.hasPrefix("name") {
                    section = .words
                } else if title.hasPrefix("slang") {
                    section = .slang
                } else if title.hasPrefix("replacement") {
                    section = .replacements
                } else {
                    section = .none
                }
                continue
            }

            // Allow Markdown list syntax: "- word", "* word", "1. word".
            if let range = line.range(of: "^([-*•]|\\d+\\.)\\s+", options: .regularExpression) {
                line.removeSubrange(range)
            }
            if line.isEmpty || line.hasPrefix(">") { continue }

            switch section {
            case .none:
                continue
            case .words, .slang:
                guard let term = parseTerm(line) else { continue }
                if section == .words { vocabulary.words.append(term) } else { vocabulary.slang.append(term) }
            case .replacements:
                let parts = line.components(separatedBy: "->")
                guard parts.count == 2 else { continue }
                let from = parts[0].trimmingCharacters(in: .whitespaces)
                let to = parts[1].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty { vocabulary.replacements.append(Replacement(from: from, to: to)) }
            }
        }
        return vocabulary
    }

    private static func parseTerm(_ line: String) -> Term? {
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let text = parts[0]
        // Skip explanation sentences in the template ("Names, places, brands. Used in every app.")
        guard !text.isEmpty, text.count <= 40, !text.contains("."), !text.contains(":") else { return nil }
        let aliases = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return Term(text, aliases: aliases)
    }

    /// The starter file written on first launch.
    public static let template = """
    # DictionApp Vocabulary

    > Edit this file any time. DictionApp reloads it as soon as you save.
    > One entry per line. Lines starting with > are notes, # are headings.

    ## Words

    > Names, places, brands and terms, spelled exactly how you want them. Used in every app.
    > If one still comes out wrong, add what it comes out as after a | and it's always swapped back:
    > Anirudh | Anirud, Annie rude

    ## Slang

    > Words you actually say. Only used in Casual apps (Messages).
    > Short slang that sounds like a common word needs a swap to work, e.g.  fuh | for
    > (that turns every "for" into "fuh" in Casual apps).

    fuh

    ## Replacements

    > Always swap one spelling for another, in every app. Write: heard -> written
    > e.g.  gonna -> going to

    """
}

/// Applies `Vocabulary.replacements` as whole-word, case-insensitive swaps.
public struct VocabularyReplacer: Sendable {
    private let rules: [(regex: NSRegularExpression, template: String)]

    public init(_ replacements: [Vocabulary.Replacement]) {
        rules = replacements
            .sorted { $0.from.count > $1.from.count }  // longest phrase first
            .compactMap { replacement in
                let words = replacement.from.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                let pattern = "(?<![\\p{L}\\p{N}'])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}'])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
                return (regex, NSRegularExpression.escapedTemplate(for: replacement.to))
            }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func apply(_ text: String) -> String {
        rules.reduce(text) { result, rule in
            rule.regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: rule.template
            )
        }
    }
}

extension Vocabulary.Term {
    /// Removes duplicates (case-insensitive), merging their aliases. Keeps the first spelling.
    public static func merged(_ terms: [Vocabulary.Term]) -> [Vocabulary.Term] {
        var order: [String] = []
        var byKey: [String: Vocabulary.Term] = [:]
        for term in terms {
            let text = term.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            if var existing = byKey[key] {
                for alias in term.aliases where !existing.aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                    existing.aliases.append(alias)
                }
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = Vocabulary.Term(text, aliases: term.aliases)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

extension Vocabulary {
    /// Text swaps to run on the raw transcript: your Replacements, plus every
    /// "sounds like" alias swapped to its term. Slang aliases only count in Casual apps.
    public func textReplacements(casual: Bool) -> [Replacement] {
        var result = replacements
        for term in words + (casual ? slang : []) {
            for alias in term.aliases where alias.caseInsensitiveCompare(term.text) != .orderedSame {
                result.append(Replacement(from: alias, to: term.text))
            }
        }
        return result
    }
}
