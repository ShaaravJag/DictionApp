import AVFoundation
import Foundation
import FluidAudio
import Testing
@testable import DictationCore

/// End-to-end check of the real speech model. Downloads the model on first run,
/// so it only runs when DICTATION_E2E=1 is set:
///
///     DICTATION_E2E=1 swift test --filter TranscriberIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DICTATION_E2E"] == "1"))
struct TranscriberIntegrationTests {
    @Test func transcribesSynthesizedSpeech() async throws {
        let audio = try synthesize("Hey, can you send me the notes from yesterday's meeting before five o'clock?")

        let transcriber = ParakeetTranscriber(model: .ultra)
        let loadStart = Date()
        try await transcriber.prepare { _ in }
        let loadTime = Date().timeIntervalSince(loadStart)

        let start = Date()
        let raw = try await transcriber.transcribe(audio)
        let elapsed = Date().timeIntervalSince(start)
        let text = TextFormatter().format(raw)

        print("E2E model load: \(String(format: "%.2f", loadTime))s")
        print("E2E audio: \(String(format: "%.1f", audio.duration))s, transcribed in \(String(format: "%.3f", elapsed))s")
        print("E2E text: \(text)")

        let lower = text.lowercased()
        #expect(lower.contains("notes"))
        #expect(lower.contains("meeting"))
        #expect(elapsed < 2)
    }

    /// Names the model has never seen get the user's spelling once they're in the vocabulary.
    @Test func vocabularyBoostingFixesNames() async throws {
        let sentences = [
            "Tell Shaarav I'm running late.",
            "I'm grabbing lunch with Anirudh and Tejas.",
            "Can you ask Vihaan to call me back?",
            "Ishaan and Priyanka are coming tonight.",
            "Text Rishabh the address.",
            "I'm good, thanks for asking.",
        ]
        let names = ["Shaarav", "Anirudh", "Tejas", "Vihaan", "Ishaan", "Priyanka", "Rishabh"]
        let transcriber = ParakeetTranscriber(model: .ultra)
        try await transcriber.prepare { _ in }

        var plain: [String] = []
        for sentence in sentences {
            plain.append(try await transcriber.transcribe(try synthesize(sentence)))
        }

        let start = Date()
        await transcriber.setVocabulary(
            standard: names.map { Vocabulary.Term($0) },
            casual: names.map { Vocabulary.Term($0) } + [Vocabulary.Term("fuh")]
        )
        print("E2E vocabulary load: \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

        var fixed = 0, missedBefore = 0
        for (sentence, before) in zip(sentences, plain) {
            let audio = try synthesize(sentence)
            let t0 = Date()
            let after = try await transcriber.transcribe(audio, boost: .standard)
            let ms = Date().timeIntervalSince(t0) * 1000
            print("E2E said:    \(sentence)\nE2E plain:   \(before)\nE2E boosted: \(after)  (\(Int(ms)) ms)")
            for name in names where sentence.contains(name) {
                let had = before.contains(name), has = after.contains(name)
                if !had { missedBefore += 1 }
                if !had && has { fixed += 1 }
                #expect(!(had && !has), "boosting broke \(name)")
            }
            if !names.contains(where: sentence.contains) {
                #expect(after == before, "sentence without names changed")
            }
        }
        print("E2E names fixed: \(fixed) of \(missedBefore) the plain model missed")
        #expect(fixed > 0 || missedBefore == 0)
    }

    /// A "sounds like" alias rescues a name the model mangles beyond recognition,
    /// and slang is only used for Casual apps.
    @Test func aliasesAndCasualSlang() async throws {
        let transcriber = ParakeetTranscriber(model: .ultra)
        try await transcriber.prepare { _ in }
        await transcriber.setVocabulary(
            standard: [Vocabulary.Term("Vihaan", aliases: ["Viven"])],
            casual: [Vocabulary.Term("Vihaan", aliases: ["Viven"]), Vocabulary.Term("fuh")]
        )

        let vihaan = try await transcriber.transcribe(try synthesize("Can you ask Vihaan to call me back?"), boost: .standard)
        print("E2E alias: \(vihaan)")
        #expect(vihaan.contains("Vihaan"))

        for sentence in ["That's fuh real.", "Thanks for coming.", "Fuh sure, see you there."] {
            let audio = try synthesize(sentence)
            let standard = try await transcriber.transcribe(audio, boost: .standard)
            let casual = try await transcriber.transcribe(audio, boost: .casual)
            print("E2E slang said: \(sentence) | standard: \(standard) | casual: \(casual)")
            #expect(!standard.lowercased().contains("fuh"))
        }
    }

    /// Numbers come out as digits everywhere; Messages (Casual) keeps only spoken punctuation.
    @Test func numbersAndCasualPunctuation() async throws {
        let transcriber = ParakeetTranscriber(model: .ultra)
        try await transcriber.prepare { _ in }
        let standard = TextFormatter()
        let casual = TextFormatter(automaticPunctuation: false)

        let cases: [(said: String, digits: [String])] = [
            ("It's currently three a m.", ["3am"]),
            ("I need six, seven, eight.", ["6", "7", "8"]),
            ("Count six. Seven. Eight.", ["6", "7", "8"]),
            ("Meet me at three thirty p m.", ["3:30pm"]),
            ("It costs five dollars and fifty cents.", ["$5.50"]),
            ("Hey, what's up? Are you coming tonight?", []),
        ]
        for (said, digits) in cases {
            let raw = try await transcriber.transcribe(try synthesize(said))
            let std = standard.format(raw)
            let c = casual.formatDetailed(raw)
            let msg = WritingStyle.casual.apply(c.text, keepFinalPunctuation: c.endsWithSpokenPunctuation)
            print("E2E said: \(said)\nE2E raw:      \(raw)\nE2E standard: \(std)\nE2E messages: \(msg)")
            for d in digits {
                #expect(std.contains(d), "standard missing \(d)")
                #expect(msg.contains(d), "messages missing \(d)")
            }
            #expect(!msg.contains(where: { ",?!;".contains($0) }), "messages kept automatic punctuation")
            #expect(!msg.hasSuffix("."), "messages kept a final period")
        }
    }

    /// With hundreds of contact names, ordinary words must not turn into names
    /// ("coding" -> "Romal"), while names still get fixed.
    @Test func manyNamesDontReplaceCommonWords() async throws {
        let firsts = ["Aarav", "Vivaan", "Aditya", "Vihaan", "Arjun", "Sai", "Reyansh", "Ayaan", "Krishna", "Ishaan",
                      "Shaurya", "Atharv", "Advik", "Pranav", "Advaith", "Aaryan", "Dhruv", "Kabir", "Ritvik", "Aarush",
                      "Kian", "Darsh", "Veer", "Rudra", "Yuvan", "Anirudh", "Tejas", "Rishabh", "Shaarav", "Romal",
                      "Bhavin", "Eshaan", "Monish", "Pratham", "Keerat", "Mohit", "Adil", "Saanvi", "Aanya", "Aadhya",
                      "Aaradhya", "Ananya", "Pari", "Anika", "Navya", "Angel", "Diya", "Myra", "Sara", "Ira",
                      "Ahana", "Anvi", "Prisha", "Riya", "Aarohi", "Anaya", "Akshara", "Eva", "Shanaya", "Kyra",
                      "Siya", "Priyanka", "Nikhil", "Rohan", "Karthik", "Varun", "Siddharth", "Harsha", "Kavya", "Meera",
                      "Tanvi", "Ishita", "Neha", "Pooja", "Sneha", "Deepak", "Suresh", "Ramesh", "Lakshmi", "Gowri",
                      "Hemant", "Jatin", "Kunal", "Lalit", "Manav", "Naveen", "Omkar", "Parth", "Raghav", "Sahil",
                      "Tarun", "Uday", "Vikram", "Yash", "Zubin", "Bhuvan", "Chetan", "Dev", "Gaurav", "Hrithik"]
        let lasts = ["Sharma", "Patel", "Reddy", "Iyer", "Nair", "Menon", "Rao", "Gupta", "Joshi", "Kulkarni",
                     "Desai", "Mehta", "Shah", "Pillai", "Chopra", "Kapoor", "Malhotra", "Bhat", "Hegde", "Jagadeesh",
                     "Srinivasan", "Venkatesh", "Subramanian", "Krishnan", "Raman", "Natarajan", "Chandran", "Gopal",
                     "Mukherjee", "Banerjee", "Chatterjee", "Das", "Bose", "Sen", "Ghosh", "Dutta", "Agarwal", "Bansal",
                     "Goyal", "Mittal", "Saxena", "Tiwari", "Pandey", "Mishra", "Dubey", "Yadav", "Chauhan", "Rathore",
                     "Thakur", "Sodhi", "Gill", "Sandhu", "Dhillon", "Grewal", "Bajwa", "Ahluwalia", "Bedi", "Kohli",
                     "Arora", "Khanna", "Sethi", "Tandon", "Bhatia", "Anand", "Wadhwa", "Puri", "Talwar", "Vohra",
                     "Ranganathan", "Balakrishnan", "Ramaswamy", "Sundaram", "Shetty", "Kamath", "Pai", "Prabhu",
                     "Naik", "Gowda", "Hiremath", "Patil", "Pawar", "Jadhav", "Shinde", "Bhosale", "Deshmukh",
                     "Kale", "Gokhale", "Apte", "Ranade", "Phadke", "Karve", "Tilak", "Godbole", "Bapat", "Lele",
                     "Oak", "Paranjpe", "Sathe", "Vaidya", "Dixit"]
        let known = Set(((try? String(contentsOfFile: "/usr/share/dict/web2", encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.lowercased() })
        let names = (firsts + lasts).filter { !known.contains($0.lowercased()) }.map { Vocabulary.Term($0) }
        print("E2E vocabulary size: \(names.count)")

        let everyday = [
            "I've been coding all day and I'm tired.",
            "Are you coming to the movie tonight?",
            "I'm going for a run, then grabbing food.",
            "That was honestly the best thing ever.",
            "Can you send me the notes from the meeting?",
            "My brother is driving us to the game later.",
            "We should order pizza for the party.",
            "I'm running late, start without me.",
            "I'm just coding right now, call you later.",
            "Still coding, almost done with the project.",
            "Honestly I don't know, let me check.",
            "Bro that's crazy, what happened?",
            "Did you finish the homework for tomorrow?",
            "Yeah I'm down, what time are we meeting?",
            "Nothing much, just chilling at home.",
            "Can you pick me up from practice?",
            "I'll be there in like ten minutes.",
            "Who's coming to dinner on Friday?",
        ]
        let withNames = [
            "Tell Shaarav I'm running late.",
            "I'm grabbing lunch with Anirudh and Tejas.",
            "Can you ask Vihaan to call me back?",
            "Text Rishabh the address.",
        ]
        let inflected: Set<String> = ["coding", "grabbing", "honestly", "chilling", "meeting", "driving", "running", "i've", "i'm", "don't", "that's", "who's", "i'll"]
        let isCommonWord: ParakeetTranscriber.CommonWordCheck = { known.contains($0.lowercased()) || inflected.contains($0.lowercased()) }
        let voices: [(String?, Int?)] = [(nil, nil), ("Aman", nil), ("Aman", 240), ("Daniel (English (UK))", 230), ("Flo (English (US))", nil)]

        var audio: [String: RecordedAudio] = [:]
        var plain: [String: String] = [:]
        let base = ParakeetTranscriber(model: .ultra)
        try await base.prepare { _ in }
        for (voice, rate) in voices {
            for sentence in everyday + withNames {
                let key = "\(voice ?? "default")/\(rate ?? 0): \(sentence)"
                audio[key] = try synthesize(sentence, voice: voice, rate: rate)
                plain[key] = try await base.transcribe(audio[key]!)
            }
        }
        let everydayKeys = audio.keys.filter { key in everyday.contains { key.hasSuffix(": " + $0) } }.sorted()
        let nameKeys = audio.keys.filter { key in withNames.contains { key.hasSuffix(": " + $0) } }.sorted()

        for (label, thresholds, guarded) in [("recall", VocabularyBoostingSession.Thresholds.recall, false),
                                              ("recall+guard", .recall, true)] {
            let transcriber = ParakeetTranscriber(model: .ultra, boostThresholds: thresholds)
            try await transcriber.prepare { _ in }
            await transcriber.setCommonWordCheck(guarded ? isCommonWord : nil)
            await transcriber.setVocabulary(standard: names, casual: names)
            var broken = 0, fixed = 0, missed = 0
            for key in everydayKeys {
                let after = try await transcriber.transcribe(audio[key]!, boost: .casual)
                guard after != plain[key] else { continue }
                print("E2E [\(label)] CHANGED: \(plain[key]!) -> \(after)")
                // Count it as broken only if a real word was lost (a misheard non-word may still change).
                var remaining = ParakeetTranscriber.words(after).map { $0.lowercased() }
                for word in ParakeetTranscriber.words(plain[key]!).map({ $0.lowercased() }) {
                    if let i = remaining.firstIndex(of: word) { remaining.remove(at: i) } else if await isCommonWord(word) { broken += 1; break }
                }
            }
            for key in nameKeys {
                let after = try await transcriber.transcribe(audio[key]!, boost: .casual)
                for name in names.map(\.text) where key.contains(name) {
                    if !plain[key]!.contains(name) { missed += 1; if after.contains(name) { fixed += 1 } }
                }
                if after != plain[key] { print("E2E [\(label)] names: \(plain[key]!) -> \(after)") }
            }
            print("E2E [\(label)] everyday sentences with a real word replaced: \(broken) of \(everydayKeys.count); names fixed: \(fixed) of \(missed)")
            if guarded { #expect(broken == 0) }
        }
    }

    private func synthesize(_ sentence: String, voice: String? = nil, rate: Int? = nil) throws -> RecordedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-e2e-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path] + (voice.map { ["-v", $0] } ?? []) + (rate.map { ["-r", "\($0)"] } ?? []) + [sentence]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return RecordedAudio(samples: samples, sampleRate: format.sampleRate)
    }
}
