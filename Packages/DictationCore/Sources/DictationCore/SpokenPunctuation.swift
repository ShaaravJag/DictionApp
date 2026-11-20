import Foundation

/// Turns spoken punctuation ("comma", "question mark", "new line") into symbols.
///
/// This is an extra layer on top of the speech model's automatic punctuation:
/// where you say a command, the symbol you asked for replaces whatever the model
/// put there; everywhere else the model's punctuation is left alone.
public struct SpokenPunctuation: Sendable {
    public var isProperNoun: ProperNounCheck

    public init(isProperNoun: @escaping ProperNounCheck = { _ in false }) {
        self.isProperNoun = isProperNoun
    }

    enum Kind {
        case trailing   // , . ? ! : ; …  attach to the previous word, space after
        case opening    // " ( [          space before, attach to the next word
        case closing    // " ) ]          attach to the previous word, space after
        case joining    // —              attaches on both sides
        case lineBreak  // \n or \n\n
    }

    enum NextWord {
        case capitalize, lowercase, leave
    }

    struct Command {
        let phrases: [String]
        let symbol: String
        let kind: Kind
        let next: NextWord
        /// If one of these words comes right before the command, it's a normal word ("add a comma").
        var literalAfter: Set<String> = SpokenPunctuation.determiners
        /// If one of these words comes right after the command, it's a normal word ("period of time").
        var literalBefore: Set<String> = []
        /// Bare "quote" / "unquote": only a command when paired with the other half,
        /// so "so-called quote unquote experts" stays as words.
        var pairedOnly = false
        /// Only a command at the very end or right before a spoken line break.
        /// Used for "Colin", which is how the model often hears "colon".
        var onlyBeforeBreakOrEnd = false
    }

    static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "any", "no",
        "one", "another", "my", "your", "his", "her", "our", "their", "its",
    ]

    /// Extra words that make "period"/"colon" literal: "the trial period", "a short period".
    static let periodModifiers: Set<String> = determiners.union([
        "some", "same", "whole", "entire", "first", "last", "next", "short", "long", "brief",
        "given", "trial", "grace", "waiting", "time", "probation", "probationary", "cooling",
        "rest", "transition", "reporting", "billing", "free", "class", "study", "lunch",
        "sigmoid", "historical", "certain",
    ])

    static let commands: [Command] = [
        Command(phrases: ["new paragraph"], symbol: "\n\n", kind: .lineBreak, next: .capitalize),
        Command(phrases: ["new line", "newline", "next line"], symbol: "\n", kind: .lineBreak, next: .capitalize),
        Command(phrases: ["question mark"], symbol: "?", kind: .trailing, next: .capitalize),
        Command(phrases: ["exclamation point", "exclamation mark"], symbol: "!", kind: .trailing, next: .capitalize),
        Command(phrases: ["full stop"], symbol: ".", kind: .trailing, next: .capitalize),
        Command(phrases: ["period"], symbol: ".", kind: .trailing, next: .capitalize,
                literalAfter: periodModifiers, literalBefore: ["of", "in", "when", "where", "during", "is", "was"]),
        Command(phrases: ["semicolon", "semi colon"], symbol: ";", kind: .trailing, next: .lowercase),
        Command(phrases: ["colon"], symbol: ":", kind: .trailing, next: .leave,
                literalAfter: periodModifiers, literalBefore: ["cancer", "health"]),
        Command(phrases: ["colin"], symbol: ":", kind: .trailing, next: .leave, onlyBeforeBreakOrEnd: true),
        Command(phrases: ["comma"], symbol: ",", kind: .trailing, next: .lowercase),
        Command(phrases: ["dot dot dot", "ellipsis"], symbol: "…", kind: .trailing, next: .leave),
        Command(phrases: ["em dash"], symbol: "—", kind: .joining, next: .leave),
        Command(phrases: ["open quote", "open quotes", "begin quote", "start quote"], symbol: "\"", kind: .opening, next: .leave),
        Command(phrases: ["close quote", "close quotes", "end quote", "end quotes"], symbol: "\"", kind: .closing, next: .leave),
        Command(phrases: ["quote"], symbol: "\"", kind: .opening, next: .leave, pairedOnly: true),
        Command(phrases: ["unquote"], symbol: "\"", kind: .closing, next: .leave, pairedOnly: true),
        Command(phrases: ["open paren", "open parenthesis", "open parentheses", "open parens"], symbol: "(", kind: .opening, next: .lowercase),
        Command(phrases: ["close paren", "close parenthesis", "close parentheses", "close parens"], symbol: ")", kind: .closing, next: .leave),
        Command(phrases: ["open bracket"], symbol: "[", kind: .opening, next: .leave),
        Command(phrases: ["close bracket"], symbol: "]", kind: .closing, next: .leave),
    ]

    /// Punctuation the speech model may have put around a spoken command.
    private static let modelPunctuation = ",.;:!?…"

    private static let regex: NSRegularExpression = {
        let alternatives = commands.flatMap(\.phrases)
            .sorted { $0.count > $1.count }
            .map { phrase in
                phrase.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[\\s,.-]+")  // "em-dash", "new, line"
            }
            .joined(separator: "|")
        let p = NSRegularExpression.escapedPattern(for: modelPunctuation)
        // group 1: model punctuation/space before, group 2: the command, group 3: model punctuation after
        return try! NSRegularExpression(
            pattern: "([\\s\(p)]*)\\b(\(alternatives))\\b([\(p)]*)",
            options: [.caseInsensitive]
        )
    }()

    private static let capitalizeMarker: Character = "\u{E000}"
    private static let lowercaseMarker: Character = "\u{E001}"

    public func apply(_ text: String) -> String {
        applyDetailed(text).text
    }

    /// Also reports whether the text ends with a mark you spoke (e.g. "period" at the end),
    /// so styles that drop the model's final period can keep yours.
    func applyDetailed(_ text: String) -> (text: String, endsWithSpokenMark: Bool) {
        let ns = text as NSString
        let matches = Self.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, false) }

        // 1. Decide which matches are real commands.
        var accepted: [(match: NSTextCheckingResult, command: Command)] = []
        for match in matches {
            guard let command = Self.command(for: ns.substring(with: match.range(at: 2))) else { continue }
            let before = ns.substring(to: match.range(at: 2).location)
            let after = ns.substring(from: match.range.location + match.range.length)
            if Self.isLiteral(command, before: before, after: after) { continue }
            if command.onlyBeforeBreakOrEnd && !Self.isAtBreakOrEnd(after) { continue }
            accepted.append((match, command))
        }
        accepted = Self.resolvePairedQuotes(accepted, in: ns)

        // 2. Replace them.
        var output = ""
        var cursor = 0
        for (match, command) in accepted {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += Self.replacement(for: command, leading: ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        let remainder = ns.substring(from: cursor)
        output += remainder

        var endsWithSpokenMark = false
        if let last = accepted.last, last.command.kind == .trailing || last.command.kind == .closing {
            let lastEnd = last.match.range.location + last.match.range.length
            endsWithSpokenMark = lastEnd == cursor
                && remainder.allSatisfy { $0.isWhitespace || Self.modelPunctuation.contains($0) }
        }

        return (Self.tidy(applyMarkers(output)), endsWithSpokenMark)
    }

    /// True if nothing but punctuation follows, or a spoken line break comes next.
    private static func isAtBreakOrEnd(_ after: String) -> Bool {
        let rest = after.drop(while: { $0.isWhitespace || modelPunctuation.contains($0) }).lowercased()
        if rest.isEmpty { return true }
        let words = rest.split(whereSeparator: { !$0.isLetter }).prefix(2).joined(separator: " ")
        return ["new line", "new paragraph", "next line"].contains(words) || words.hasPrefix("newline")
    }

    /// Keeps a bare "quote"/"unquote" only when it pairs with a quote on the other side
    /// with at least one word in between.
    private static func resolvePairedQuotes(
        _ items: [(match: NSTextCheckingResult, command: Command)], in ns: NSString
    ) -> [(match: NSTextCheckingResult, command: Command)] {
        func isQuote(_ c: Command) -> Bool { c.symbol == "\"" }
        func wordsBetween(_ a: NSTextCheckingResult, _ b: NSTextCheckingResult) -> Bool {
            let start = a.range.location + a.range.length
            let length = b.range.location - start
            guard length > 0 else { return false }
            return ns.substring(with: NSRange(location: start, length: length)).contains(where: \.isLetter)
        }

        return items.enumerated().filter { index, item in
            guard item.command.pairedOnly else { return true }
            if item.command.kind == .opening {
                return items[(index + 1)...].contains { isQuote($0.command) && $0.command.kind == .closing && wordsBetween(item.match, $0.match) }
            } else {
                return items[..<index].contains { isQuote($0.command) && $0.command.kind == .opening && wordsBetween($0.match, item.match) }
            }
        }.map(\.element)
    }

    private static func command(for spoken: String) -> Command? {
        let normalized = spoken.lowercased()
            .replacingOccurrences(of: "[\\s,.-]+", with: " ", options: .regularExpression)
        return commands.first { $0.phrases.contains(normalized) }
    }

    private static func isLiteral(_ command: Command, before: String, after: String) -> Bool {
        if let previous = before.split(whereSeparator: { !$0.isLetter }).last,
           command.literalAfter.contains(previous.lowercased()) {
            // Literal only if the model didn't put punctuation between the two words.
            let gap = before.reversed().prefix { !$0.isLetter }
            if !gap.contains(where: { modelPunctuation.contains($0) }) { return true }
        }
        if let nextWord = after.split(whereSeparator: { !$0.isLetter }).first,
           command.literalBefore.contains(nextWord.lowercased()) {
            let gap = after.prefix { !$0.isLetter }
            if !gap.contains(where: { modelPunctuation.contains($0) }) { return true }
        }
        return false
    }

    private static func replacement(for command: Command, leading: String) -> String {
        let marker: String
        switch command.next {
        case .capitalize: marker = String(capitalizeMarker)
        case .lowercase: marker = String(lowercaseMarker)
        case .leave: marker = ""
        }

        switch command.kind {
        case .trailing, .closing:
            return command.symbol + marker + " "
        case .opening:
            return " " + command.symbol + marker
        case .joining:
            return command.symbol + marker
        case .lineBreak:
            // Keep a sentence-ending mark the model put before the break; drop a comma.
            let keep = leading.filter { ".!?".contains($0) }.suffix(1)
            return String(keep) + marker + command.symbol
        }
    }

    /// Fixes spacing left over from the replacements.
    static func tidy(_ text: String) -> String {
        var t = text
        // Opening symbols attach to the next word: `( hello` -> `(hello`, ` " hi` -> ` "hi`
        t = t.replacingOccurrences(of: "([(\\[]|(?:^|\\s)\")[ \\t]+", with: "$1", options: .regularExpression)
        // Em dash and line breaks absorb surrounding spaces.
        t = t.replacingOccurrences(of: "[ \\t]*—[ \\t]*", with: "—", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        // No space before closing punctuation: `hi .` -> `hi.`
        t = t.replacingOccurrences(of: "[ \\t]+([,.;:!?…)\\]])", with: "$1", options: .regularExpression)
        // A model period right after a spoken "!" or "?": `great!.` -> `great!`
        t = t.replacingOccurrences(of: "([!?])\\.(?!\\.)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Applies capitalize/lowercase markers to the following word, then removes them.
    private func applyMarkers(_ text: String) -> String {
        var result = ""
        var pending: Character?
        var rest = Substring(text)

        while let c = rest.first {
            rest = rest.dropFirst()
            if c == Self.capitalizeMarker || c == Self.lowercaseMarker {
                pending = c
                continue
            }
            if let marker = pending, c.isLetter {
                let wordEnd = rest.firstIndex(where: { !($0.isLetter || $0 == "'" || $0 == "’") }) ?? rest.endIndex
                let word = String(c) + rest[rest.startIndex..<wordEnd]
                result += marker == Self.capitalizeMarker
                    ? CaseRules.capitalizingFirstLetter(word)
                    : CaseRules.lowercasingFirstWord(word, isProperNoun: isProperNoun)
                rest = rest[wordEnd...]
                pending = nil
                continue
            }
            if pending != nil && !(c.isWhitespace || "\"'“‘([".contains(c)) {
                pending = nil
            }
            result.append(c)
        }
        return result
    }
}
