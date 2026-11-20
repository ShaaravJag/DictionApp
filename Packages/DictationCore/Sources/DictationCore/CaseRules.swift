import Foundation

/// Decides whether a word may be lowercased when it appears mid-sentence.
public typealias ProperNounCheck = @Sendable (String) -> Bool

enum CaseRules {
    /// Lowercases the first word of `text` (after any leading whitespace or
    /// opening quotes/brackets) unless it should keep its capital:
    /// "I" and its contractions, acronyms, mixed-case words, and proper nouns.
    static func lowercasingFirstWord(_ text: String, isProperNoun: ProperNounCheck) -> String {
        guard let start = text.firstIndex(where: { $0.isLetter }) else { return text }
        // Only touch the word if nothing but whitespace/opening punctuation precedes it.
        let prefix = text[text.startIndex..<start]
        guard prefix.allSatisfy({ $0.isWhitespace || "\"'“‘([{".contains($0) }) else { return text }

        let end = text[start...].firstIndex(where: { !($0.isLetter || $0 == "'" || $0 == "’") }) ?? text.endIndex
        let word = String(text[start..<end])
        guard shouldLowercase(word, isProperNoun: isProperNoun) else { return text }

        var result = text
        result.replaceSubrange(start...start, with: String(text[start]).lowercased())
        return result
    }

    static func shouldLowercase(_ word: String, isProperNoun: ProperNounCheck) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        // "I", "I'm", "I'll", "I've", "I'd"
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        let letters = word.filter(\.isLetter)
        // Acronyms (API, NASA) and mixed case (iPhone, McDonald, YouTube)
        if letters.count >= 2 && letters.allSatisfy(\.isUppercase) { return false }
        if letters.dropFirst().contains(where: \.isUppercase) { return false }
        let base = word.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? word
        if isProperNoun(base) { return false }
        return true
    }

    /// Uppercases the first letter of `text` after any leading whitespace or opening punctuation.
    static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        let prefix = text[text.startIndex..<index]
        guard prefix.allSatisfy({ $0.isWhitespace || "\"'“‘([{-•*".contains($0) }) else { return text }
        guard text[index].isLowercase else { return text }
        var result = text
        result.replaceSubrange(index...index, with: String(text[index]).uppercased())
        return result
    }
}
