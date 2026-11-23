import AppKit
import ApplicationServices
import DictationCore

/// Reads the text just before and after the cursor in the focused app, using
/// the Accessibility API (the same permission the hotkey already needs).
@MainActor
enum FocusedTextReader {
    struct Snapshot {
        var context: InsertionContext
        var pid: pid_t?
        var element: AXUIElement?
    }

    private static let charactersBefore = 200
    private static let charactersAfter = 20
    private static let timeout: Float = 0.15
    private static var accessibilityEnabledPIDs = Set<pid_t>()

    /// Electron (Slack, VS Code, the Claude app, Discord) and Chromium only build their
    /// accessibility tree when asked. Call this early (on key press) so it's ready
    /// by the time we read the text.
    static func prepareFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard !accessibilityEnabledPIDs.contains(pid) else { return }
        accessibilityEnabledPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func read() -> Snapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Snapshot(context: .unknown)
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)

        guard let element: AXUIElement = copyAttribute(appElement, kAXFocusedUIElementAttribute) else {
            return Snapshot(context: .unknown, pid: pid)
        }
        AXUIElementSetMessagingTimeout(element, timeout)

        let role: String? = copyAttribute(element, kAXRoleAttribute)
        let subrole: String? = copyAttribute(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return Snapshot(context: .unknown, pid: pid, element: element)
        }

        guard let rangeValue: AXValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else {
            return Snapshot(context: .unknown, pid: pid, element: element)
        }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selection), selection.location >= 0 else {
            return Snapshot(context: .unknown, pid: pid, element: element)
        }

        let totalLength: Int? = copyAttribute(element, kAXNumberOfCharactersAttribute)
        let beforeStart = max(0, selection.location - charactersBefore)
        let afterStart = selection.location + selection.length
        let afterLength = totalLength.map { max(0, min(charactersAfter, $0 - afterStart)) } ?? charactersAfter

        var before = string(in: element, range: CFRange(location: beforeStart, length: selection.location - beforeStart))
        var after = afterLength > 0 ? string(in: element, range: CFRange(location: afterStart, length: afterLength)) : ""

        // Some apps don't support ranged reads: fall back to slicing the full value.
        if before == nil || after == nil, let value: String = copyAttribute(element, kAXValueAttribute) {
            let ns = value as NSString
            if before == nil, selection.location <= ns.length {
                before = ns.substring(with: NSRange(location: beforeStart, length: selection.location - beforeStart))
            }
            if after == nil, afterStart <= ns.length {
                after = ns.substring(with: NSRange(location: afterStart, length: min(charactersAfter, ns.length - afterStart)))
            }
        }

        // Some apps report a cursor but no text at all; treat that as unknown.
        if before == nil && after == nil {
            return Snapshot(context: .unknown, pid: pid, element: element)
        }
        return Snapshot(context: InsertionContext(textBefore: before, textAfter: after), pid: pid, element: element)
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        if range.length == 0 { return "" }
        var cfRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        )
        guard error == .success else { return nil }
        return result as? String
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
            return nil
        }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}

/// Decides which capitalized words are names (and so keep their capital mid-sentence).
///
/// The spell checker alone accepts "john" and "chicago", so we also use the system
/// word list, where names appear only capitalized ("John") and common words only
/// lowercase ("station").
enum ProperNouns {
    nonisolated(unsafe) private static var namesOnly: Set<String> = []
    nonisolated(unsafe) private static var allWords: Set<String>?
    nonisolated(unsafe) private static var custom: Set<String> = []
    private static let lock = NSLock()      // guards the sets
    private static let loadLock = NSLock()  // makes sure the word lists load once

    /// Loads the word lists in the background at launch (~0.2 s, a few MB).
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = dictionaryWords() }
    }

    /// Every word in the system word lists, lowercased. Loads them on first use; safe off the main thread.
    static func dictionaryWords() -> Set<String> {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let words = lock.withLock({ allWords }) { return words }

        var lowercase = Set<String>()
        var capitalized = Set<String>()
        for path in ["/usr/share/dict/web2", "/usr/share/dict/propernames"] {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let first = line.first else { continue }
                if first.isUppercase { capitalized.insert(line.lowercased()) } else { lowercase.insert(String(line)) }
            }
        }
        let names = capitalized.subtracting(lowercase)
        let all = lowercase.union(capitalized)
        lock.withLock {
            namesOnly = names
            allWords = all
        }
        return all
    }

    /// Your vocabulary words and contact names, so they keep their capital mid-sentence.
    static func setCustomNames<S: Sequence>(_ names: S) where S.Element == String {
        let lowered = Set(names.filter { $0.first?.isUppercase == true }.map { $0.lowercased() })
        lock.withLock { custom = lowered }
    }

    /// A real everyday word ("coding", "for"), which the name matcher must never replace.
    /// Checks the system word list, then the spell checker (which knows forms like "coding").
    static func isCommonWord(_ word: String) async -> Bool {
        let lower = word.lowercased()
        guard lower.count > 1, lower.contains(where: \.isLetter) else { return false }
        if dictionaryWords().contains(lower) { return true }
        return await MainActor.run {
            NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0).location == NSNotFound
        }
    }

    /// `word` is the word as dictated (e.g. "Sarah"). Main thread only (spell checker).
    static func isProperNoun(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lock.withLock({ namesOnly.contains(lower) || custom.contains(lower) }) { return true }
        // Not a known word at all in lowercase ("sarah", "alex"): probably a name.
        let misspelled = NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0)
        return misspelled.location != NSNotFound
    }
}
