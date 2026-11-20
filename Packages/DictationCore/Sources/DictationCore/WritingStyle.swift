import Foundation

/// How dictated text should read in a particular app.
///
/// These are deterministic rules applied after transcription. The Phase 2 LLM
/// cleanup can add richer, tone-based styles on top of the same per-app setting.
public enum WritingStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Normal sentence case and punctuation.
    case standard
    /// Texting style: all lowercase (names and "i" too, acronyms stay caps),
    /// no period at the end.
    case casual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .casual: return "Casual (lowercase, no final period)"
        }
    }

    /// Whether context-aware capitalization should run for this style.
    public var adjustsCapitalization: Bool { self == .standard }

    /// - Parameter keepFinalPunctuation: true when you said the final mark out loud
    ///   ("…period"); Casual then keeps it instead of dropping the model's period.
    public func apply(_ text: String, keepFinalPunctuation: Bool = false) -> String {
        switch self {
        case .standard:
            return text
        case .casual:
            let lowered = Self.lowercasingKeepingAcronyms(text)
            return keepFinalPunctuation ? lowered : Self.droppingFinalPeriod(lowered)
        }
    }

    /// "Hey Sarah, I think the NBA game is at 5." -> "hey sarah, i think the NBA game is at 5."
    static func lowercasingKeepingAcronyms(_ text: String) -> String {
        var result = ""
        var word = ""

        func flush() {
            let letters = word.filter(\.isLetter)
            let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            result += isAcronym ? word : word.lowercased()
            word = ""
        }

        for c in text {
            if c.isLetter || c.isNumber || c == "'" || c == "’" {
                word.append(c)
            } else {
                flush()
                result.append(c)
            }
        }
        flush()
        return result
    }

    /// Drops a single period at the very end ("see you at 5." -> "see you at 5").
    /// Keeps "?", "!", and ellipses.
    static func droppingFinalPeriod(_ text: String) -> String {
        var trimmed = text
        var trailing = ""
        while let last = trimmed.last, last.isWhitespace {
            trailing = String(last) + trailing
            trimmed.removeLast()
        }
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }
        trimmed.removeLast()
        return trimmed + trailing
    }
}
