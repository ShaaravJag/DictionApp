import Testing
@testable import DictationCore

@Suite struct WritingStyleTests {
    @Test func casualLowercasesEverythingButAcronyms() {
        #expect(WritingStyle.casual.apply("Hey Sarah, I think the NBA game is at 5.")
            == "hey sarah, i think the NBA game is at 5")
        #expect(WritingStyle.casual.apply("I'm on my way. ASAP.") == "i'm on my way. ASAP")
    }

    @Test func casualKeepsQuestionAndExclamation() {
        #expect(WritingStyle.casual.apply("Are you coming?") == "are you coming?")
        #expect(WritingStyle.casual.apply("Let's go!") == "let's go!")
        #expect(WritingStyle.casual.apply("Well...") == "well...")
    }

    @Test func standardIsUnchanged() {
        #expect(WritingStyle.standard.apply("Hey Sarah.") == "Hey Sarah.")
    }

    @Test func casualStillGetsSpacingButNoCapitalization() {
        let formatter = ContextualFormatter(adjustsCapitalization: false)
        let text = WritingStyle.casual.apply("See you there.")
        #expect(formatter.adapt(text, to: InsertionContext(textBefore: "sounds good")) == " see you there")
        #expect(formatter.adapt(text, to: InsertionContext(textBefore: "")) == "see you there")
    }
}

@Suite struct SpokenFinalPunctuationTests {
    let formatter = TextFormatter()

    func casual(_ raw: String) -> String {
        let formatted = formatter.formatDetailed(raw)
        return WritingStyle.casual.apply(formatted.text, keepFinalPunctuation: formatted.endsWithSpokenPunctuation)
    }

    @Test func spokenFinalPeriodIsKeptInCasual() {
        #expect(casual("see you then period") == "see you then.")
        #expect(casual("See you then. Period.") == "see you then.")
        #expect(casual("sounds good full stop") == "sounds good.")
    }

    @Test func modelFinalPeriodIsStillDroppedInCasual() {
        #expect(casual("See you then.") == "see you then")
    }

    @Test func spokenMidPeriodKeptButModelFinalPeriodDropped() {
        #expect(casual("ok period sounds good") == "ok. sounds good")
        #expect(casual("Ok. Period. Sounds good.") == "ok. sounds good")
    }

    @Test func detailedReportsSpokenEnding() {
        #expect(formatter.formatDetailed("on my way period").endsWithSpokenPunctuation)
        #expect(!formatter.formatDetailed("On my way.").endsWithSpokenPunctuation)
        #expect(!formatter.formatDetailed("ok period sounds good").endsWithSpokenPunctuation)
    }

    @Test func standardUnchanged() {
        let formatted = formatter.formatDetailed("see you then period")
        #expect(WritingStyle.standard.apply(formatted.text, keepFinalPunctuation: true) == "See you then.")
    }

    @Test func contextKeepsSpokenPeriodBeforeExistingText() {
        let f = ContextualFormatter()
        let ctx = InsertionContext(textBefore: "Meet me ", textAfter: "and then")
        #expect(f.adapt("There.", to: ctx, keepFinalPeriod: true) == "there. ")
        #expect(f.adapt("There.", to: ctx) == "there ")
    }
}
