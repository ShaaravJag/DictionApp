import Contacts
import DictationCore
import Foundation
import OSLog

/// Reads first, last and nicknames from Contacts so the speech model spells them right.
/// Everything stays on this Mac, in memory.
@MainActor
final class ContactsNameSource {
    /// Called with the new name list whenever it is (re)loaded.
    var onChange: (([Vocabulary.Term]) -> Void)?
    private(set) var names: [Vocabulary.Term] = []

    private let logger = Logger(subsystem: "com.dictionapp.mac", category: "contacts")
    private var observer: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?

    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Asks for Contacts access the first time, then loads names and keeps them current.
    /// Returns false if access was denied.
    func enable() async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        guard Self.isAuthorized else {
            logger.info("Contacts access not granted")
            return false
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        await refresh()
        return true
    }

    func disable() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pendingRefresh?.cancel()
        names = []
        onChange?([])
    }

    /// Contacts changes arrive in bursts (e.g. iCloud sync), so wait for them to settle.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.refresh() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func refresh() async {
        let start = Date()
        let terms = await Task.detached(priority: .utility) { Self.fetchUncommonNames() }.value
        guard observer != nil else { return }  // turned off meanwhile
        names = terms
        logger.info("Loaded \(terms.count) contact names in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        onChange?(terms)
    }

    /// Names the dictionary doesn't already know (e.g. "Anirudh", "Jaxon"). Common names like
    /// "John" are left to the speech model, which already gets them right.
    nonisolated static func fetchUncommonNames() -> [Vocabulary.Term] {
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let known = ProperNouns.dictionaryWords()
        var terms: [Vocabulary.Term] = []

        func add(_ field: String, phonetic: String) {
            let words = field.split(whereSeparator: { $0.isWhitespace }).compactMap(cleanName)
            // A phonetic spelling only lines up with a one-word name.
            let alias = words.count == 1
                ? phonetic.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
                : ""
            for word in words where !known.contains(word.lowercased()) {
                let aliases = alias.isEmpty || alias.caseInsensitiveCompare(word) == .orderedSame ? [] : [alias]
                terms.append(Vocabulary.Term(word, aliases: aliases))
            }
        }

        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                add(contact.givenName, phonetic: contact.phoneticGivenName)
                add(contact.familyName, phonetic: contact.phoneticFamilyName)
                add(contact.nickname, phonetic: "")
            }
        } catch {
            Logger(subsystem: "com.dictionapp.mac", category: "contacts")
                .error("Contacts fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        return Vocabulary.Term.merged(terms)
    }

    /// "Anirudh" → "Anirudh"; "(school)", "💕", "J.", "Dr" → nil.
    nonisolated private static func cleanName(_ raw: Substring) -> String? {
        let word = raw.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard word.count >= 3,
              word.first?.isLetter == true,
              word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" })
        else { return nil }
        return word
    }
}
