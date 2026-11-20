import Foundation

/// The text immediately around the cursor where dictation will be inserted.
/// `nil` means the app didn't tell us.
public struct InsertionContext: Sendable, Equatable {
    public var textBefore: String?
    public var textAfter: String?

    public init(textBefore: String? = nil, textAfter: String? = nil) {
        self.textBefore = textBefore
        self.textAfter = textAfter
    }

    public static let unknown = InsertionContext()
    public var isUnknown: Bool { textBefore == nil && textAfter == nil }
}

/// Adapts a formatted transcript to where it's being inserted: adds the space
/// after the previous sentence, and only capitalizes when starting a sentence.
public struct ContextualFormatter: Sendable {
    public var isProperNoun: ProperNounCheck
    /// Off for styles that set their own case (e.g. casual lowercase); spacing still applies.
    public var adjustsCapitalization: Bool

    public init(adjustsCapitalization: Bool = true, isProperNoun: @escaping ProperNounCheck = { _ in false }) {
        self.adjustsCapitalization = adjustsCapitalization
        self.isProperNoun = isProperNoun
    }

    enum Position: Equatable {
        case sentenceStart, midSentence, keepAsIs
    }

    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
    static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    static let bullets: Set<Character> = ["-", "•", "*", "–"]
    /// Punctuation that attaches to the previous word, so no space before it.
    static let attachingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "\"", "”", "’"]

    /// - Parameter keepFinalPeriod: true when you said the final period out loud,
    ///   so it's kept even when inserting before existing text.
    public func adapt(_ text: String, to context: InsertionContext, keepFinalPeriod: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        if let before = context.textBefore {
            // Text that starts with a spoken "new line" keeps its own capitalization.
            let startsWithBreak = result.first?.isNewline == true
            switch startsWithBreak || !adjustsCapitalization ? .keepAsIs : Self.position(after: before) {
            case .sentenceStart:
                result = CaseRules.capitalizingFirstLetter(result)
            case .midSentence:
                result = CaseRules.lowercasingFirstWord(result, isProperNoun: isProperNoun)
            case .keepAsIs:
                break  // after a colon or an opening quote/bracket either case is fine
            }

            if Self.needsLeadingSpace(before: before, inserting: result) {
                result = " " + result
            }
        }

        if let after = context.textAfter, let next = after.first {
            if next.isLetter && next.isLowercase || next.isNumber {
                // Inserting into the middle of a sentence: drop the model's closing period.
                if !keepFinalPeriod && result.hasSuffix(".") && !result.hasSuffix("..") {
                    result.removeLast()
                }
            }
            if (next.isLetter || next.isNumber || Self.openers.contains(next)),
               let last = result.last, !last.isWhitespace {
                result += " "
            }
        }

        return result
    }

    static func position(after before: String) -> Position {
        var index = before.endIndex
        var sawNewline = false

        while index > before.startIndex {
            let previous = before.index(before: index)
            let c = before[previous]
            if c.isNewline {
                sawNewline = true
            } else if !c.isWhitespace {
                if sawNewline { return .sentenceStart }
                if sentenceEnders.contains(c) { return .sentenceStart }
                if c == ":" { return .keepAsIs }
                if isOpening(c, in: String(before[before.startIndex...previous])) { return .keepAsIs }
                if closers.contains(c) {
                    // Look through closing quotes/brackets: `He said "Hi."` -> sentence start.
                    index = previous
                    continue
                }
                if bullets.contains(c) && isAtLineStart(before, upTo: previous) { return .sentenceStart }
                return .midSentence
            }
            index = previous
        }
        // Empty field or only whitespace before the cursor.
        return .sentenceStart
    }

    /// Whether the last character of `text` opens a quote/bracket. Straight quotes
    /// are ambiguous: `say "` opens, `"Hi."` closes.
    private static func isOpening(_ last: Character, in text: String) -> Bool {
        if last == "\"" || last == "'" {
            let head = text.dropLast()
            guard let previous = head.last else { return true }
            return previous.isWhitespace || openers.contains(previous)
        }
        return ["(", "[", "{", "“", "‘"].contains(last)
    }

    private static func isAtLineStart(_ text: String, upTo index: String.Index) -> Bool {
        let head = text[text.startIndex..<index]
        guard let lastNonSpace = head.last(where: { !($0 == " " || $0 == "\t") }) else { return true }
        return lastNonSpace.isNewline
    }

    static func needsLeadingSpace(before: String, inserting text: String) -> Bool {
        guard let last = before.last, !last.isWhitespace else { return false }
        if isOpening(last, in: before) { return false }
        guard let first = text.first else { return false }
        if first.isWhitespace { return false }
        // A quote that opens the new text (`"hello"`) needs the space; a closing one doesn't.
        if first == "\"" || first == "“" {
            let second = text.dropFirst().first
            return second.map { !$0.isWhitespace && !attachingPunctuation.contains($0) } ?? false
        }
        if attachingPunctuation.contains(first) { return false }
        return true
    }
}
