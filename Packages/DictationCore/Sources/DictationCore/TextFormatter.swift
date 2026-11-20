import Foundation

/// Deterministic, instant clean-up applied to every transcript.
///
/// The LLM cleanup in Phase 2 runs on top of this; this layer keeps working
/// even when no LLM is available.
public struct TextFormatter: Sendable {
    public var removeFillers: Bool
    /// Say "comma", "question mark", "new line"… to insert punctuation yourself.
    /// The speech model's automatic punctuation stays on either way.
    public var spokenPunctuation: Bool
    /// Keep the speech model's own punctuation. Off (Casual / Messages): only what you say.
    public var automaticPunctuation: Bool
    /// "six" -> 6, "three a m" -> 3am, "five dollars" -> $5.
    public var numbersAsDigits: Bool
    public var isProperNoun: ProperNounCheck

    public init(
        removeFillers: Bool = true,
        spokenPunctuation: Bool = true,
        automaticPunctuation: Bool = true,
        numbersAsDigits: Bool = true,
        isProperNoun: @escaping ProperNounCheck = { _ in false }
    ) {
        self.removeFillers = removeFillers
        self.spokenPunctuation = spokenPunctuation
        self.automaticPunctuation = automaticPunctuation
        self.numbersAsDigits = numbersAsDigits
        self.isProperNoun = isProperNoun
    }

    /// Formatted text plus what later steps need to know about it.
    public struct FormattedText: Sendable, Equatable {
        public var text: String
        /// The text ends with punctuation you said out loud ("…period"), which
        /// styles must keep even if they normally drop the final period.
        public var endsWithSpokenPunctuation: Bool
    }

    /// Standalone filler words that never carry meaning in dictated text.
    static let fillers = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm"]

    public func format(_ raw: String) -> String {
        formatDetailed(raw).text
    }

    public func formatDetailed(_ raw: String) -> FormattedText {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return FormattedText(text: "", endsWithSpokenPunctuation: false) }

        if removeFillers {
            text = Self.stripFillers(text)
        }

        // Before spoken punctuation, so the marks you say are never removed.
        if !automaticPunctuation {
            text = AutomaticPunctuation.removing(from: text)
        }

        var endsWithSpoken = false
        if spokenPunctuation {
            (text, endsWithSpoken) = SpokenPunctuation(isProperNoun: isProperNoun).applyDetailed(text)
        }

        // After spoken punctuation: "six comma seven" -> "6, 7", and "one period of time" keeps its word.
        if numbersAsDigits {
            text = SpokenNumbers().apply(text)
        }

        text = Self.collapseWhitespace(text)
        text = Self.capitalizeFirstLetter(text)
        return FormattedText(text: text, endsWithSpokenPunctuation: endsWithSpoken)
    }

    static func stripFillers(_ text: String) -> String {
        let alternation = fillers.joined(separator: "|")
        // A filler plus any comma/ellipsis right after it, e.g. "Um, so" -> "so".
        let pattern = "(?i)\\b(?:\(alternation))\\b[,.…]*\\s*"
        var result = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        // Tidy punctuation left dangling by a removed filler: "word ," -> "word,".
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        // A sentence that now starts with a comma: "Hello. , then" -> "Hello. then".
        result = result.replacingOccurrences(of: "([.!?])\\s*,\\s*", with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        // Re-capitalize sentence starts that were behind a filler: "Hi. so" -> "Hi. So".
        result = capitalizeSentenceStarts(result)
        return result
    }

    /// Collapses runs of spaces. Line breaks (e.g. a spoken "new line" at the end) are kept.
    static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    static func capitalizeFirstLetter(_ text: String) -> String {
        CaseRules.capitalizingFirstLetter(text)
    }

    static func capitalizeSentenceStarts(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?]\\s+)([a-z])") else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letterRange = match.range(at: 2)
            let upper = ns.substring(with: letterRange).uppercased()
            result = (result as NSString).replacingCharacters(in: letterRange, with: upper)
        }
        return result
    }
}
