import Foundation

/// Saving "it wrote X, I meant Y" into the vocabulary file, as a `## Words` line.
extension Vocabulary {
    /// Why a correction can't be saved, or nil if it's fine.
    public static func correctionProblem(heard: String, meant: String) -> String? {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty || meant.isEmpty { return "Fill in both boxes." }
        if meant.count > 40 { return "\"You meant\" is too long (40 characters at most)." }
        if meant.contains(where: { ".:|,".contains($0) }) || meant.contains("->") {
            return "\"You meant\" can't contain . : | or ,"
        }
        if heard.contains(where: { "|,".contains($0) }) || heard.contains("->") {
            return "\"It wrote\" can't contain | , or ->"
        }
        return nil
    }

    /// Adds `heard` as a "sounds like" alias of `meant` under `## Words`.
    ///
    /// - Existing `meant` line: the alias is appended (no duplicates).
    /// - Otherwise a new `meant | heard` line goes at the end of the Words section.
    /// - No Words section: one is added after the title.
    /// - Same word in a different case ("shaarav" -> "Shaarav"): the name is added without an alias,
    ///   which is enough to keep its spelling and capital.
    /// Everything else in the file is left exactly as it was.
    public static func addingCorrection(heard rawHeard: String, meant rawMeant: String, to markdown: String) -> String {
        let heard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = rawMeant.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias: String? = heard.caseInsensitiveCompare(meant) == .orderedSame ? nil : heard
        var lines = markdown.components(separatedBy: "\n")

        // Locate the Words section: its heading and the next heading after it.
        var start: Int?
        var end = lines.count
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            if start == nil {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                if title.hasPrefix("word") || title.hasPrefix("name") { start = i }
            } else {
                end = i
                break
            }
        }

        let newEntry = alias.map { "\(meant) | \($0)" } ?? meant

        guard let start else {
            let at = lines.first?.hasPrefix("# ") == true ? 1 : 0
            let block = at == 0 ? ["## Words", "", newEntry, ""] : ["", "## Words", "", newEntry]
            lines.insert(contentsOf: block, at: at)
            return lines.joined(separator: "\n")
        }

        // An existing line for this word: add the alias to it.
        var lastContent = start
        for i in (start + 1)..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lastContent = i
            guard !trimmed.hasPrefix(">"), !trimmed.hasPrefix("<!--") else { continue }

            let prefixRange = lines[i].range(of: "^\\s*(?:[-*•]|\\d+\\.)\\s+", options: .regularExpression)
            let prefix = prefixRange.map { String(lines[i][$0]) } ?? ""
            let body = prefixRange.map { String(lines[i][$0.upperBound...]) } ?? trimmed
            let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts[0].caseInsensitiveCompare(meant) == .orderedSame else { continue }

            var aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            guard let alias, !aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) else {
                return markdown  // already there
            }
            aliases.append(alias)
            lines[i] = prefix + parts[0] + " | " + aliases.joined(separator: ", ")
            return lines.joined(separator: "\n")
        }

        // A new line at the end of the section, after any notes.
        let afterNote = lastContent == start || lines[lastContent].trimmingCharacters(in: .whitespaces).hasPrefix(">")
        var insertion = afterNote ? ["", newEntry] : [newEntry]
        let next = lastContent + 1
        if next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            insertion.append("")  // keep a blank line before the next heading
        }
        lines.insert(contentsOf: insertion, at: next)
        return lines.joined(separator: "\n")
    }
}
