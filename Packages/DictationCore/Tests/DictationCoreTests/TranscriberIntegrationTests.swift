import AVFoundation
import Foundation
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

    private func synthesize(_ sentence: String) throws -> RecordedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-e2e-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, sentence]
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
