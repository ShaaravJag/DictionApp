import Testing
@testable import DictationCore

@Suite struct SpokenPunctuationTests {
    let names: Set<String> = ["sam", "sarah"]
    var formatter: TextFormatter {
        let names = self.names
        return TextFormatter(isProperNoun: { names.contains($0.lowercased()) })
    }

    @Test func commaAndQuestionMarkReplaceModelPunctuation() {
        #expect(formatter.format("Hello, comma, how are you question mark.") == "Hello, how are you?")
    }

    @Test func exclamationPoint() {
        #expect(formatter.format("Wait exclamation point") == "Wait!")
        #expect(formatter.format("Wait exclamation mark.") == "Wait!")
    }

    @Test func colonAndNewParagraph() {
        #expect(formatter.format("Dear Sam colon new paragraph thanks") == "Dear Sam:\n\nThanks")
        #expect(formatter.format("Dear Sam, colon. New paragraph. Thanks.") == "Dear Sam:\n\nThanks.")
    }

    @Test func newLineKeepsSentenceEndingPunctuation() {
        #expect(formatter.format("First item. New line. Second item.") == "First item.\nSecond item.")
    }

    @Test func periodUsedAsAWordStaysAWord() {
        #expect(formatter.format("for a period of time") == "For a period of time")
        #expect(formatter.format("The trial period ends Friday.") == "The trial period ends Friday.")
    }

    @Test func spokenPeriodStartsNewSentence() {
        #expect(formatter.format("I'm done period see you later") == "I'm done. See you later")
    }

    @Test func quotes() {
        #expect(formatter.format("she said open quote hi close quote") == "She said \"hi\"")
    }

    @Test func parentheses() {
        #expect(formatter.format("Bring snacks open paren chips or fruit close paren please.")
            == "Bring snacks (chips or fruit) please.")
    }

    @Test func commaLowercasesWrongCapitalButKeepsNames() {
        #expect(formatter.format("Thanks. Comma. Sarah will call.") == "Thanks, Sarah will call.")
        #expect(formatter.format("Okay. Comma. The plan works.") == "Okay, the plan works.")
    }

    @Test func emDashAndEllipsis() {
        #expect(formatter.format("It was great em dash really great") == "It was great—really great")
        #expect(formatter.format("Well dot dot dot maybe") == "Well… maybe")
    }

    @Test func literalUseAfterArticle() {
        #expect(formatter.format("Add a comma here.") == "Add a comma here.")
    }

    @Test func automaticPunctuationPassesThroughUnchanged() {
        #expect(formatter.format("Sounds good. See you at 5.") == "Sounds good. See you at 5.")
        #expect(formatter.format("Can you send it today? Thanks!") == "Can you send it today? Thanks!")
    }

    @Test func canBeTurnedOff() {
        let off = TextFormatter(spokenPunctuation: false)
        #expect(off.format("Hello comma there") == "Hello comma there")
    }
}

@Suite struct SpokenPunctuationFixesTests {
    let formatter = TextFormatter()

    @Test func pluralParentheses() {
        #expect(formatter.format("Bring snacks. Open parentheses. Chips. Close parentheses.") == "Bring snacks (chips)")
    }

    @Test func colinHeardForColonBeforeLineBreak() {
        #expect(formatter.format("Dear Sam, Colin. New paragraph. Thanks for the update!") == "Dear Sam:\n\nThanks for the update!")
        #expect(formatter.format("Here's the list, Colin.") == "Here's the list:")
    }

    @Test func colinAsANameStaysAName() {
        #expect(formatter.format("Colin is coming over later.") == "Colin is coming over later.")
        #expect(formatter.format("Tell Colin I said hi.") == "Tell Colin I said hi.")
    }

    @Test func bareQuoteWithEndQuote() {
        #expect(formatter.format("He said quote I'm tired end quote and left.") == "He said \"I'm tired\" and left.")
    }

    @Test func quoteUnquoteIdiomStaysWords() {
        #expect(formatter.format("The so-called quote unquote experts.") == "The so-called quote unquote experts.")
    }

    @Test func noPeriodAfterSpokenExclamation() {
        #expect(formatter.format("I love music exclamation point exclamation point.") == "I love music!!")
    }
}
