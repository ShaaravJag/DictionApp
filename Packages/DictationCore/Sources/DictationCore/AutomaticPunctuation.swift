import Foundation

/// Removes the punctuation the speech model adds on its own, for styles that only
/// want the punctuation you say out loud. Runs before spoken punctuation, so
/// "comma", "question mark"… still work.
public enum AutomaticPunctuation {
    /// Sentence punctuation, quotes, brackets and dashes.
    static let removable: Set<Character> = [
        ".", ",", "?", "!", ";", ":", "…", "\"", "“", "”", "‘", "’", "'", "(", ")", "[", "]", "{", "}",
        "—", "–", "-", "¿", "¡",
    ]

    /// "Hey, what's up? I'm at the U.S. office (3:30)." -> "Hey what's up I'm at the US office 3:30"
    ///
    /// Kept: apostrophes inside words (i'm, don't), hyphens inside words (well-known),
    /// punctuation inside numbers (3.5, 3:30, 25,000), and symbols like $ % & / @ # +.
    public static func removing(from text: String) -> String {
        let chars = Array(text.replacingOccurrences(of: "...", with: "…"))
        var result = ""
        result.reserveCapacity(chars.count)

        for (i, c) in chars.enumerated() {
            guard removable.contains(c) else {
                result.append(c)
                continue
            }
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let prevLetter = prev?.isLetter == true, nextLetter = next?.isLetter == true
            let prevDigit = prev?.isNumber == true, nextDigit = next?.isNumber == true

            if (c == "." || c == "," || c == ":") && prevDigit && nextDigit {
                result.append(c)  // 3.5, 25,000, 3:30
            } else if (c == "'" || c == "’") && prevLetter && nextLetter {
                result.append(c)  // i'm, don't
            } else if c == "-" && (prevLetter || prevDigit) && (nextLetter || nextDigit) {
                result.append(c)  // well-known, 24-7
            } else if c == "." && prevLetter && nextLetter {
                continue  // U.S., a.m., e.g. -> US, am, eg
            } else if (prevLetter || prevDigit) && (nextLetter || nextDigit) {
                result.append(" ")  // "word—word", "word...word": keep the words apart
            }
        }
        return result
    }
}
