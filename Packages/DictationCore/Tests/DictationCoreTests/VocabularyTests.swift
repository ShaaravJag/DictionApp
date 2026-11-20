import Testing
@testable import DictationCore

@Suite struct VocabularyTests {
    @Test func parsesSectionsAliasesAndReplacements() {
        let file = """
        # My Vocabulary
        stray line before any section

        ## Words
        > a note
        Shaarav | Sharav, Shah rav
        - Anirudh
        Names, places and brands. Used everywhere.

        <!-- Priya
        hidden -->
        ## Slang
        fuh
        * bruh

        ## Replacements
        gonna -> going to
        not a replacement line
        """
        let v = Vocabulary.parse(markdown: file)
        #expect(v.words == [
            Vocabulary.Term("Shaarav", aliases: ["Sharav", "Shah rav"]),
            Vocabulary.Term("Anirudh"),
        ])
        #expect(v.slang == [Vocabulary.Term("fuh"), Vocabulary.Term("bruh")])
        #expect(v.replacements == [Vocabulary.Replacement(from: "gonna", to: "going to")])
    }

    @Test func templateParsesToJustTheExampleSlang() {
        let v = Vocabulary.parse(markdown: Vocabulary.template)
        #expect(v.words.isEmpty)
        #expect(v.slang == [Vocabulary.Term("fuh")])
        #expect(v.replacements.isEmpty)
    }

    @Test func replacerSwapsWholeWordsCaseInsensitively() {
        let r = VocabularyReplacer([
            .init(from: "gonna", to: "going to"),
            .init(from: "chat gpt", to: "ChatGPT"),
        ])
        #expect(r.apply("I'm Gonna ask chat  GPT.") == "I'm going to ask ChatGPT.")
        #expect(r.apply("gonnabe stays") == "gonnabe stays")
    }

    @Test func replacerHandlesSpecialCharacters() {
        let r = VocabularyReplacer([.init(from: "c sharp", to: "C# ($)")])
        #expect(r.apply("I code in c sharp") == "I code in C# ($)")
    }

    @Test func aliasesBecomeSwapsAndSlangOnlyInCasual() {
        let v = Vocabulary.parse(markdown: """
        ## Words
        Vihaan | Viven
        ## Slang
        fuh | for
        ## Replacements
        gonna -> going to
        """)
        let standard = VocabularyReplacer(v.textReplacements(casual: false))
        let casual = VocabularyReplacer(v.textReplacements(casual: true))
        #expect(standard.apply("Ask Viven for it, gonna be fine.") == "Ask Vihaan for it, going to be fine.")
        #expect(casual.apply("Ask Viven for it, gonna be fine.") == "Ask Vihaan fuh it, going to be fine.")
        #expect(casual.apply("Forget it") == "Forget it")
    }

    @Test func mergedDedupesAndCombinesAliases() {
        let merged = Vocabulary.Term.merged([
            .init("Tejas", aliases: ["Tehas"]),
            .init("tejas", aliases: ["Texas guy"]),
            .init("Anirudh"),
        ])
        #expect(merged == [.init("Tejas", aliases: ["Tehas", "Texas guy"]), .init("Anirudh")])
    }
}
