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
        let sentence = "Hey, can you send me the notes from yesterday's meeting before five o'clock?"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-e2e.aiff")
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
        let audio = RecordedAudio(samples: samples, sampleRate: format.sampleRate)

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
}
