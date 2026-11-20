import Testing
@testable import DictationCore

@Suite struct TextFormatterTests {
    let formatter = TextFormatter()

    @Test func trimsAndCapitalizes() {
        #expect(formatter.format("  hello there.  ") == "Hello there.")
    }

    @Test func emptyStaysEmpty() {
        #expect(formatter.format("   ") == "")
    }

    @Test func removesLeadingFiller() {
        #expect(formatter.format("Um, so I was thinking.") == "So I was thinking.")
    }

    @Test func removesMidSentenceFillers() {
        #expect(formatter.format("I think, uh, we should go.") == "I think, we should go.")
    }

    @Test func recapitalizesAfterFillerAtSentenceStart() {
        #expect(formatter.format("That's fine. Uh, let's meet at five.") == "That's fine. Let's meet at 5.")
    }

    @Test func keepsWordsThatContainFillers() {
        // "um" inside "umbrella" and "er" inside "never" must survive.
        #expect(formatter.format("Bring an umbrella, never forget.") == "Bring an umbrella, never forget.")
    }

    @Test func fillerRemovalCanBeDisabled() {
        let keep = TextFormatter(removeFillers: false)
        #expect(keep.format("um, okay") == "Um, okay")
    }
}
