import Foundation

/// Writes spoken numbers as digits.
///
///     six seven eight          -> 6 7 8
///     twenty five / a hundred  -> 25 / 100
///     three a m / 3 p.m.       -> 3am / 3pm
///     three thirty p m         -> 3:30pm     (and "at three thirty" -> "at 3:30")
///     five dollars and fifty cents / five fifty dollars -> $5.50
///     ten percent              -> 10%
///     three point one four     -> 3.14
///     twenty twenty six        -> 2026
///     five million             -> 5 million
///
/// "one" stays a word unless it's clearly a number ("no one", "the one", "one more thing").
/// Ordinals ("first") are left alone.
public struct SpokenNumbers: Sendable {
    public init() {}

    public func apply(_ text: String) -> String {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        var parser = Parser(tokens: Token.tokenize(text))
        return parser.run()
    }
}

// MARK: - Tokens

private struct Token {
    enum Kind { case word, digits, space, other }
    let kind: Kind
    let text: String
    let lower: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
        self.lower = text.lowercased()
    }

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Words (with inner apostrophes: "o'clock", "it's"), digit groups ("3", "3:30", "25,000"),
    /// runs of spaces, and single other characters (punctuation, newlines).
    static func tokenize(_ text: String) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var j = i + 1
            if c.isLetter {
                while j < chars.count {
                    if chars[j].isLetter {
                        j += 1
                    } else if chars[j] == "'" || chars[j] == "’", j + 1 < chars.count, chars[j + 1].isLetter {
                        j += 2
                    } else {
                        break
                    }
                }
                tokens.append(Token(.word, String(chars[i..<j])))
            } else if isDigit(c) {
                while j < chars.count {
                    if isDigit(chars[j]) {
                        j += 1
                    } else if ".,:".contains(chars[j]), j + 1 < chars.count, isDigit(chars[j + 1]) {
                        j += 2
                    } else {
                        break
                    }
                }
                tokens.append(Token(.digits, String(chars[i..<j])))
            } else if c == " " || c == "\t" {
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                tokens.append(Token(.space, String(chars[i..<j])))
            } else {
                tokens.append(Token(.other, String(c)))
            }
            i = j
        }
        return tokens
    }
}

// MARK: - Parser

private struct Parser {
    let tokens: [Token]

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    /// Kept as words: "5 million" reads better than "5,000,000".
    static let bigScales: Set<String> = ["million", "billion", "trillion"]
    /// "at three thirty" is a time even without a.m./p.m.
    static let timePrepositions: Set<String> = [
        "at", "by", "until", "till", "til", "around", "before", "after", "from", "since",
    ]
    /// "one or two", "one to three": "one" is a number when another number follows these.
    static let rangeWords: Set<String> = ["or", "to", "and", "through"]

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil
    }

    // MARK: Token helpers

    func word(at k: Int) -> String? {
        k >= 0 && k < tokens.count && tokens[k].kind == .word ? tokens[k].lower : nil
    }

    /// The index after a space at `k`, if there is one.
    func afterSpace(_ k: Int) -> Int? {
        k < tokens.count && tokens[k].kind == .space ? k + 1 : nil
    }

    /// The next word joined to the word at `k` by a space or hyphen ("twenty-five").
    func joinedWord(after k: Int) -> Int? {
        let j = k + 1
        guard j + 1 < tokens.count, tokens[j + 1].kind == .word else { return nil }
        if tokens[j].kind == .space || tokens[j].text == "-" { return j + 1 }
        return nil
    }

    /// Whether a number (word or digits) starts at `k`.
    func isNumber(at k: Int) -> Bool {
        guard k < tokens.count else { return false }
        if tokens[k].kind == .digits { return true }
        if let w = word(at: k) { return Self.isNumberWord(w) }
        return false
    }

    // MARK: Cardinals

    struct Cardinal {
        var value: Int
        var end: Int          // token index after the last word used
        var words: Int
        var single: String?   // the word, when the number is a single word
    }

    /// "two hundred and five", "twenty-five", "a thousand". Stops where the words stop forming one
    /// number, so "six seven eight" is three numbers.
    func cardinal(at start: Int) -> Cardinal? {
        enum Last { case none, unit, teen, tens, tensUnit, hundred, thousand, and }
        var k = start
        var total = 0, current = 0
        var last = Last.none
        var end = start
        var words = 0
        var firstWord: String?

        // "a hundred", "a thousand"
        if word(at: k) == "a" {
            guard let next = afterSpace(k + 1), let w = word(at: next), w == "hundred" || w == "thousand" else { return nil }
            current = 1
            last = .unit
            words = 1
            firstWord = "a"
            k = next
        }

        while let w = word(at: k) {
            var accepted = true
            var stopAfter = false
            if let u = Self.units[w] {
                if w == "zero" {
                    accepted = last == .none
                    stopAfter = true
                } else {
                    switch last {
                    case .none, .hundred, .thousand, .and: current += u; last = .unit
                    case .tens: current += u; last = .tensUnit
                    default: accepted = false
                    }
                }
            } else if let t = Self.teens[w] ?? Self.tens[w] {
                switch last {
                case .none, .hundred, .thousand, .and:
                    current += t
                    last = Self.teens[w] != nil ? .teen : .tens
                default:
                    accepted = false
                }
            } else if w == "hundred" {
                if [.unit, .teen, .tens, .tensUnit].contains(last), current > 0, current < 100 {
                    current *= 100
                    last = .hundred
                } else {
                    accepted = false
                }
            } else if w == "thousand" {
                if [.unit, .teen, .tens, .tensUnit, .hundred].contains(last), total == 0, current > 0 {
                    total = current * 1000
                    current = 0
                    last = .thousand
                } else {
                    accepted = false
                }
            } else if w == "and" {
                // Only inside a number: "a hundred and five", "two thousand and six".
                if last == .hundred || last == .thousand, let next = afterSpace(k + 1), let nw = word(at: next),
                   Self.isNumberWord(nw), nw != "zero" {
                    last = .and
                } else {
                    accepted = false
                }
            } else {
                accepted = false
            }

            guard accepted else { break }
            if w != "and" {
                words += 1
                if firstWord == nil { firstWord = w }
                end = k + 1
            }
            if stopAfter { break }
            guard let next = joinedWord(after: k) else { break }
            k = next
        }

        guard words > 0 else { return nil }
        return Cardinal(value: total + current, end: end, words: words, single: words == 1 ? firstWord : nil)
    }

    /// Minutes after an hour: "thirty" (10–59) or "oh five" (01–09).
    func minutes(after k: Int) -> (text: String, end: Int)? {
        guard let start = afterSpace(k), let w = word(at: start) else { return nil }
        if w == "oh", let n = afterSpace(start + 1), let u = word(at: n).flatMap({ Self.units[$0] }), u > 0 {
            return ("0\(u)", n + 1)
        }
        if let c = cardinal(at: start), (10...59).contains(c.value), c.words <= 2 {
            return (String(c.value), c.end)
        }
        return nil
    }

    /// "am", "AM", "a m", "a.m.", "a. m." after a number. `dotted` means the abbreviation's final
    /// period was consumed (it may also have been the end of the sentence).
    func meridiem(after k: Int) -> (text: String, end: Int, dotted: Bool)? {
        var j = k
        if j < tokens.count, tokens[j].kind == .space { j += 1 }
        guard let w = word(at: j) else { return nil }
        if w == "am" || w == "pm" { return (w, j + 1, false) }
        guard w == "a" || w == "p" else { return nil }
        var m = j + 1
        if m < tokens.count, tokens[m].text == "." { m += 1 }
        if m < tokens.count, tokens[m].kind == .space { m += 1 }
        guard word(at: m) == "m" else { return nil }
        m += 1
        var dotted = false
        if m < tokens.count, tokens[m].text == "." {
            m += 1
            dotted = true
        }
        return (w == "a" ? "am" : "pm", m, dotted)
    }

    /// A dropped "a.m." period that also ended the sentence comes back after "3am".
    func sentencePeriod(dotted: Bool, end: Int) -> String {
        guard dotted else { return "" }
        guard end < tokens.count else { return "." }
        let next = tokens[end]
        if next.text == "\n" { return "." }
        if next.kind == .space, end + 1 < tokens.count, tokens[end + 1].kind == .word,
           tokens[end + 1].text.first?.isUppercase == true {
            return "."
        }
        return ""
    }

    // MARK: Phrases

    /// The digits for the number phrase starting at `i`, or nil to leave it as written.
    func phrase(at i: Int, previousIsNumber: Bool) -> (text: String, end: Int)? {
        if tokens[i].kind == .digits { return digitPhrase(at: i) }
        guard let c = cardinal(at: i) else { return nil }

        // Times: "three a m", "three thirty p m", "at three thirty".
        if (1...12).contains(c.value), c.single != nil || c.words <= 2 {
            let mins = minutes(after: c.end)
            if let mer = meridiem(after: mins?.end ?? c.end) {
                let time = mins.map { "\(c.value):\($0.text)" } ?? "\(c.value)"
                return (time + mer.text + sentencePeriod(dotted: mer.dotted, end: mer.end), mer.end)
            }
            if let mins, let before = word(at: i - 2), tokens[i - 1].kind == .space,
               Self.timePrepositions.contains(before) {
                return ("\(c.value):\(mins.text)", mins.end)
            }
        }

        // "five fifty dollars" -> $5.50 (not "three fifty dollar bills")
        if (1...99).contains(c.value), let s = afterSpace(c.end), let cents = cardinal(at: s),
           (10...99).contains(cents.value), let d = afterSpace(cents.end), word(at: d) == "dollars" {
            return ("$\(c.value).\(cents.value)", d + 1)
        }

        // Years: "twenty twenty six" -> 2026, "nineteen ninety nine" -> 1999, "twenty oh five" -> 2005.
        if let first = c.single, ["eighteen", "nineteen", "twenty"].contains(first), let s = afterSpace(c.end) {
            if word(at: s) == "oh", let n = afterSpace(s + 1), let u = word(at: n).flatMap({ Self.units[$0] }), u > 0 {
                return (String(c.value * 100 + u), n + 1)
            }
            if let second = cardinal(at: s), (10...99).contains(second.value) {
                return (String(c.value * 100 + second.value), second.end)
            }
        }

        var text = Self.format(c.value)
        var end = c.end
        var extended = false

        // "three point one four" -> 3.14
        if let p = afterSpace(end), word(at: p) == "point", let decimals = decimalDigits(after: p) {
            text += "." + decimals.text
            end = decimals.end
            extended = true
        }

        // "five million" -> 5 million
        if let s = afterSpace(end), let w = word(at: s), Self.bigScales.contains(w) {
            text += " " + tokens[s].text
            end = s + 1
            extended = true
        }

        if let suffix = moneyOrPercent(number: text, after: end, allowCents: !extended) {
            return suffix
        }

        // "one" is only a digit when it's clearly a number.
        if c.single == "one", !extended, !previousIsNumber, !numberFollows(c.end) {
            return nil
        }
        return (text, end)
    }

    /// Digits the model already wrote: only the time, money and percent rules apply.
    func digitPhrase(at i: Int) -> (text: String, end: Int)? {
        let digits = tokens[i].text
        if let mer = meridiem(after: i + 1), let time = Self.clockTime(digits) {
            return (time + mer.text + sentencePeriod(dotted: mer.dotted, end: mer.end), mer.end)
        }
        return moneyOrPercent(number: digits, after: i + 1, allowCents: !digits.contains("."))
    }

    /// "5 dollars" -> $5, "5 dollars and 50 cents" -> $5.50, "10 percent" -> 10%.
    func moneyOrPercent(number: String, after end: Int, allowCents: Bool) -> (text: String, end: Int)? {
        guard let s = afterSpace(end), let w = word(at: s) else { return nil }
        if w == "dollars" || w == "dollar" {
            if allowCents, let a = afterSpace(s + 1), word(at: a) == "and", let n = afterSpace(a + 1) {
                var cents: (value: Int, end: Int)?
                if let c = cardinal(at: n) { cents = (c.value, c.end) }
                else if tokens[n].kind == .digits, let v = Int(tokens[n].text) { cents = (v, n + 1) }
                if let cents, (1...99).contains(cents.value), let cw = afterSpace(cents.end),
                   let unit = word(at: cw), unit == "cents" || unit == "cent" {
                    return ("$\(number).\(String(format: "%02d", cents.value))", cw + 1)
                }
            }
            return ("$" + number, s + 1)
        }
        if w == "percent" { return (number + "%", s + 1) }
        if w == "per", let c = afterSpace(s + 1), word(at: c) == "cent" { return (number + "%", c + 1) }
        return nil
    }

    /// Digits after "point": "one four" -> "14", "five" -> "5", "fifteen" -> "15".
    func decimalDigits(after p: Int) -> (text: String, end: Int)? {
        var digits = ""
        var end = p + 1
        var k = afterSpace(p + 1)
        while let current = k, let w = word(at: current) {
            if let u = Self.units[w] {
                digits += String(u)
            } else if w == "oh" {
                digits += "0"
            } else if digits.isEmpty, let c = cardinal(at: current), c.value >= 10, c.value < 100 {
                return (String(c.value), c.end)
            } else {
                break
            }
            end = current + 1
            k = afterSpace(current + 1)
        }
        return digits.isEmpty ? nil : (digits, end)
    }

    /// Another number right after (directly or via "or", "to", "and"), or "o'clock".
    func numberFollows(_ end: Int) -> Bool {
        guard let s = afterSpace(end) else { return false }
        if isNumber(at: s) { return true }
        guard let w = word(at: s) else { return false }
        if w == "o'clock" || w == "o’clock" { return true }
        if Self.rangeWords.contains(w), let n = afterSpace(s + 1) { return isNumber(at: n) }
        return false
    }

    /// "3", "3:30", or "3.30" (how the model sometimes writes it) as a 12-hour clock time.
    /// Only called when am/pm follows.
    static func clockTime(_ digits: String) -> String? {
        let parts = digits.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard let hour = Int(parts[0]), (1...12).contains(hour) else { return nil }
        if parts.count == 1 { return String(hour) }
        guard parts.count == 2, parts[1].count == 2, let m = Int(parts[1]), m < 60 else { return nil }
        return "\(hour):\(parts[1])"
    }

    /// 2500 stays 2500; 25000 becomes 25,000.
    static func format(_ value: Int) -> String {
        let digits = String(value)
        guard value >= 10_000 else { return digits }
        var result = ""
        for (index, c) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.append(",") }
            result.append(c)
        }
        return String(result.reversed())
    }

    // MARK: Run

    mutating func run() -> String {
        var out = ""
        var i = 0
        var lastNumberEnd = -1
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .word || token.kind == .digits {
                // "six one" -> the "one" follows another number.
                let previousIsNumber = i >= 2 && tokens[i - 1].kind == .space
                    && (lastNumberEnd == i - 1 || tokens[i - 2].kind == .digits)
                if let (text, end) = phrase(at: i, previousIsNumber: previousIsNumber) {
                    out += text
                    i = end
                    lastNumberEnd = end
                    continue
                }
            }
            out += token.text
            i += 1
        }
        return out
    }
}
