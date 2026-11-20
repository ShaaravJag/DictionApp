import Testing
@testable import DictationCore

@Suite struct SpokenNumbersTests {
    let numbers = SpokenNumbers()

    @Test(arguments: [
        ("I need six seven eight", "I need 6 7 8"),
        ("Six people came.", "6 people came."),
        ("about twenty five of them", "about 25 of them"),
        ("twenty-five", "25"),
        ("two hundred and five", "205"),
        ("a hundred bucks", "100 bucks"),
        ("five bucks", "5 bucks"),
        ("three hundred thousand", "300,000"),
        ("two thousand five hundred", "2500"),
        ("two thousand and six", "2006"),
        ("twelve hundred", "1200"),
        ("zero", "0"),
        ("a five-year-old", "a 5-year-old"),
    ])
    func cardinals(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("five million", "5 million"),
        ("two point five billion", "2.5 billion"),
        ("a million", "a million"),
        ("three point five", "3.5"),
        ("three point one four", "3.14"),
        ("the point is", "the point is"),
    ])
    func scalesAndDecimals(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("no one knows", "no one knows"),
        ("the one I want", "the one I want"),
        ("one of them", "one of them"),
        ("One more thing.", "One more thing."),
        ("one two three", "1 2 3"),
        ("one or two", "1 or 2"),
        ("twenty one", "21"),
        ("one hundred", "100"),
        ("one dollar", "$1"),
        ("one o'clock", "1 o'clock"),
        ("one a m", "1am"),
        ("someone once said", "someone once said"),
    ])
    func smartOne(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("It's currently three a m", "It's currently 3am"),
        ("It's currently 3 a.m.", "It's currently 3am."),
        ("It's 3 a.m. Go to sleep.", "It's 3am. Go to sleep."),
        ("3 a.m. and I'm up", "3am and I'm up"),
        ("at 3 AM", "at 3am"),
        ("at 3 a. m.", "at 3am."),
        ("3 am", "3am"),
        ("three thirty p m", "3:30pm"),
        ("3:30 p.m.", "3:30pm."),
        ("Meet me at 3.30 p.m. tomorrow", "Meet me at 3:30pm tomorrow"),
        ("the rate is 3.30 now", "the rate is 3.30 now"),
        ("three oh five pm", "3:05pm"),
        ("twelve fifteen a.m.", "12:15am."),
        ("meet at three thirty", "meet at 3:30"),
        ("seven o'clock", "7 o'clock"),
        ("I am here", "I am here"),
        ("thirteen a m", "13 a m"),
    ])
    func times(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("five dollars", "$5"),
        ("two hundred dollars", "$200"),
        ("five dollars and fifty cents", "$5.50"),
        ("five dollars and five cents", "$5.05"),
        ("five fifty dollars", "$5.50"),
        ("three fifty dollar bills", "3 $50 bills"),
        ("5 dollars", "$5"),
        ("five million dollars", "$5 million"),
        ("ten percent", "10%"),
        ("a hundred percent", "100%"),
        ("10 percent", "10%"),
        ("fifty cents", "50 cents"),
    ])
    func moneyAndPercent(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("twenty twenty six", "2026"),
        ("nineteen ninety nine", "1999"),
        ("twenty oh five", "2005"),
        ("nineteen hundred", "1900"),
        ("back in twenty twenty", "back in 2020"),
    ])
    func years(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }

    @Test(arguments: [
        ("like 6 or 7", "like 6 or 7"),
        ("the first time", "the first time"),
        ("six, seven, eight.", "6, 7, 8."),
        ("Seks seven eight", "Seks 7 8"),
        ("well-known", "well-known"),
        ("", ""),
    ])
    func leftAlone(input: String, expected: String) {
        #expect(numbers.apply(input) == expected)
    }
}

@Suite struct AutomaticPunctuationTests {
    @Test(arguments: [
        ("Hey, what's up? Are you coming tonight.", "Hey what's up Are you coming tonight"),
        ("I'm at the U.S. office (3:30).", "I'm at the US office 3:30"),
        ("It costs $3.50, or 25,000 total!", "It costs $3.50 or 25,000 total"),
        ("Wait—what?", "Wait what"),
        ("Hmm... okay", "Hmm okay"),
        ("A well-known, \"quoted\" word.", "A well-known quoted word"),
        ("It's 3 a.m.", "It's 3 am"),
    ])
    func removesModelPunctuation(input: String, expected: String) {
        let collapsed = AutomaticPunctuation.removing(from: input)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        #expect(collapsed == expected)
    }
}

/// The full Messages pipeline: no automatic punctuation, spoken marks kept, numbers as digits.
@Suite struct CasualPipelineTests {
    let formatter = TextFormatter(automaticPunctuation: false)

    func messages(_ raw: String) -> String {
        let formatted = formatter.formatDetailed(raw)
        return WritingStyle.casual.apply(formatted.text, keepFinalPunctuation: formatted.endsWithSpokenPunctuation)
    }

    @Test func noAutomaticPunctuation() {
        #expect(messages("Hey, what's up? Are you coming tonight.") == "hey what's up are you coming tonight")
    }

    @Test func spokenPunctuationStillWorks() {
        #expect(messages("Are you coming? Question mark.") == "are you coming?")
        #expect(messages("Okay, period.") == "okay.")
        #expect(messages("Wait comma what") == "wait, what")
    }

    @Test func numbersAndTimes() {
        #expect(messages("It's 3 a.m., go to sleep.") == "it's 3am go to sleep")
        #expect(messages("It's currently three a m.") == "it's currently 3am")
        #expect(messages("I need six, seven, eight.") == "i need 6 7 8")
    }

    @Test func standardKeepsPunctuationAndConvertsNumbers() {
        let standard = TextFormatter()
        #expect(standard.format("It's currently 3 a.m.") == "It's currently 3am.")
        #expect(standard.format("Can you send six, seven, eight?") == "Can you send 6, 7, 8?")
        #expect(standard.format("Six comma seven") == "6, 7")
    }
}
