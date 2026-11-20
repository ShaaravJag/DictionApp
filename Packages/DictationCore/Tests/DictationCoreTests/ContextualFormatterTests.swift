import Testing
@testable import DictationCore

@Suite struct ContextualFormatterTests {
    let formatter = ContextualFormatter(isProperNoun: { ["sarah", "john"].contains($0.lowercased()) })

    func adapt(_ text: String, before: String? = nil, after: String? = nil) -> String {
        formatter.adapt(text, to: InsertionContext(textBefore: before, textAfter: after))
    }

    @Test func addsSpaceAfterPreviousSentence() {
        #expect(adapt("How are you?", before: "Hello.") == " How are you?")
    }

    @Test func noExtraSpaceWhenAlreadySpaced() {
        #expect(adapt("How are you?", before: "Hello. ") == "How are you?")
    }

    @Test func lowercasesMidSentence() {
        #expect(adapt("The station.", before: "I'll meet you at") == " the station.")
        #expect(adapt("Then we leave.", before: "We eat, ") == "then we leave.")
    }

    @Test func keepsNamesAcronymsAndI() {
        #expect(adapt("Sarah tomorrow.", before: "call") == " Sarah tomorrow.")
        #expect(adapt("API keys.", before: "we use") == " API keys.")
        #expect(adapt("I think so.", before: "so") == " I think so.")
        #expect(adapt("I'm sure.", before: "and") == " I'm sure.")
        #expect(adapt("iPhone apps.", before: "build") == " iPhone apps.")
    }

    @Test func emptyFieldIsSentenceStart() {
        #expect(adapt("hello there.", before: "") == "Hello there.")
        #expect(adapt("Hello there.", before: "   ") == "Hello there.")
    }

    @Test func newLineIsSentenceStart() {
        #expect(adapt("next point.", before: "First point.\n") == "Next point.")
        #expect(adapt("next point.", before: "Some header\n") == "Next point.")
    }

    @Test func noSpaceAfterOpeningBracketOrQuote() {
        #expect(adapt("Maybe.", before: "(") == "Maybe.")
        #expect(adapt("Hi.", before: "She said \"") == "Hi.")
    }

    @Test func spaceAfterClosingQuote() {
        #expect(adapt("Then she left.", before: "She said \"Hi.\"") == " Then she left.")
    }

    @Test func bulletLineIsSentenceStart() {
        #expect(adapt("buy milk", before: "Todo:\n- ") == "Buy milk")
    }

    @Test func insertingBeforeExistingTextDropsPeriodAndAddsSpace() {
        #expect(adapt("The station.", before: "Meet me at ", after: "and then we go") == "the station ")
    }

    @Test func insertingBeforePunctuationAddsNoSpace() {
        #expect(adapt("Tomorrow.", before: "See you ", after: ".") == "tomorrow.")
    }

    @Test func unknownContextIsUnchanged() {
        #expect(adapt("Hello there.") == "Hello there.")
    }

    @Test func spokenLeadingNewLineKeepsItsCase() {
        #expect(adapt("\nThanks", before: "Best regards") == "\nThanks")
    }
}

@Suite struct OpeningQuoteSpacingTests {
    @Test func openingQuoteAfterSentenceGetsSpace() {
        let f = ContextualFormatter()
        #expect(f.adapt("\"This is a quote.\"", to: InsertionContext(textBefore: "Very good.")) == " \"This is a quote.\"")
    }
}
