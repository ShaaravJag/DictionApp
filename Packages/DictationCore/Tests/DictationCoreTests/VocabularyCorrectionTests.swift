import Testing
@testable import DictationCore

@Suite struct VocabularyCorrectionTests {
    @Test func addsNewNameToTemplateWordsSection() {
        let updated = Vocabulary.addingCorrection(heard: "Sharav", meant: "Shaarav", to: Vocabulary.template)
        let v = Vocabulary.parse(markdown: updated)
        #expect(v.words == [Vocabulary.Term("Shaarav", aliases: ["Sharav"])])
        #expect(v.slang == [Vocabulary.Term("fuh")])
        #expect(updated.contains("\n\nShaarav | Sharav\n\n## Slang"))
        // Everything else is untouched.
        #expect(updated.replacingOccurrences(of: "\nShaarav | Sharav\n", with: "") == Vocabulary.template)
    }

    @Test func secondNameGoesRightAfterTheFirst() {
        var file = Vocabulary.addingCorrection(heard: "Sharav", meant: "Shaarav", to: Vocabulary.template)
        file = Vocabulary.addingCorrection(heard: "Annie rude", meant: "Anirudh", to: file)
        #expect(file.contains("Shaarav | Sharav\nAnirudh | Annie rude\n\n## Slang"))
    }

    @Test func mergesAliasIntoExistingLineWithoutDuplicates() {
        let file = "## Words\n- Anirudh | Anirud\n\n## Slang\nfuh\n"
        let once = Vocabulary.addingCorrection(heard: "annie rude", meant: "anirudh", to: file)
        #expect(once == "## Words\n- Anirudh | Anirud, annie rude\n\n## Slang\nfuh\n")
        #expect(Vocabulary.addingCorrection(heard: "Anirud", meant: "Anirudh", to: once) == once)
    }

    @Test func caseOnlyFixAddsTheNameWithoutAlias() {
        let file = Vocabulary.addingCorrection(heard: "shaarav", meant: "Shaarav", to: "## Words\n")
        #expect(Vocabulary.parse(markdown: file).words == [Vocabulary.Term("Shaarav")])
    }

    @Test func createsWordsSectionWhenMissing() {
        let file = "# My Vocabulary\n\n## Slang\nfuh\n"
        let updated = Vocabulary.addingCorrection(heard: "Tehas", meant: "Tejas", to: file)
        let v = Vocabulary.parse(markdown: updated)
        #expect(v.words == [Vocabulary.Term("Tejas", aliases: ["Tehas"])])
        #expect(v.slang == [Vocabulary.Term("fuh")])
    }

    @Test func rejectsBadInput() {
        #expect(Vocabulary.correctionProblem(heard: "", meant: "Tejas") != nil)
        #expect(Vocabulary.correctionProblem(heard: "Tehas", meant: "Tejas.") != nil)
        #expect(Vocabulary.correctionProblem(heard: "a, b", meant: "Tejas") != nil)
        #expect(Vocabulary.correctionProblem(heard: "Tehas", meant: "Tejas | x") != nil)
        #expect(Vocabulary.correctionProblem(heard: "Annie rude", meant: "Anirudh") == nil)
    }
}
