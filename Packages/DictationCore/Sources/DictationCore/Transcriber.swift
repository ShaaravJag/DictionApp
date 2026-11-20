import FluidAudio
import Foundation
import OSLog

let log = Logger(subsystem: "com.dictionapp.core", category: "core")

/// Speech-to-text engine. Implementations must be safe to call from any task.
public protocol Transcriber: Sendable {
    /// Downloads (first run only) and loads the model, then warms it up.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ audio: RecordedAudio, boost: VocabularyBoost) async throws -> String
}

public extension Transcriber {
    func transcribe(_ audio: RecordedAudio) async throws -> String {
        try await transcribe(audio, boost: .standard)
    }
}

/// Which personal vocabulary to listen for.
public enum VocabularyBoost: Sendable {
    /// Words + contact names (every app).
    case standard
    /// Words + contact names + slang (Casual apps).
    case casual
}

/// Which Parakeet checkpoint to run. All run on the Apple Neural Engine.
public enum ParakeetModel: String, CaseIterable, Sendable, Identifiable {
    case ultra       // multilingual, most accurate (default)
    case v3          // multilingual, original
    case v2          // English-only, high recall
    case bark3Clean  // English-only, drops fillers / false starts itself

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ultra: return "Parakeet Ultra (recommended)"
        case .v3: return "Parakeet v3"
        case .v2: return "Parakeet v2 (English)"
        case .bark3Clean: return "Bark 3.0 Clean (English, removes fillers)"
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .ultra: return .ultra
        case .v3: return .v3
        case .v2: return .v2
        case .bark3Clean: return .bark3Clean
        }
    }
}

public enum TranscriberError: LocalizedError {
    case notReady

    public var errorDescription: String? {
        switch self {
        case .notReady: return "The speech model is still loading."
        }
    }
}

/// Parakeet TDT via FluidAudio (CoreML on the Neural Engine).
public actor ParakeetTranscriber: Transcriber {
    private let model: ParakeetModel
    private var manager: AsrManager?
    private let converter = AudioConverter()

    // Personal vocabulary boosting (loaded only when there is a vocabulary).
    private var ctcLoad: Task<CtcModels, Error>?
    private var standardBoost: VocabularyBoostingSession?
    private var casualBoost: VocabularyBoostingSession?
    private var vocabularyGeneration = 0

    public init(model: ParakeetModel = .ultra) {
        self.model = model
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if manager != nil { return }
        let start = Date()
        let models = try await AsrModels.downloadAndLoad(
            version: model.asrVersion,
            progressHandler: { progress($0.fractionCompleted) }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager

        // Warm-up so the first real dictation doesn't pay CoreML's compile cost.
        let silence = RecordedAudio(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        _ = try? await transcribe(silence)
        log.info("Parakeet \(self.model.rawValue, privacy: .public) ready in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
    }

    /// Sets the terms to listen for. Downloads the small CTC model (~100 MB)
    /// the first time a non-empty vocabulary is set. Safe to call repeatedly.
    public func setVocabulary(standard: [Vocabulary.Term], casual: [Vocabulary.Term]) async {
        vocabularyGeneration += 1
        let generation = vocabularyGeneration
        let standardTerms = Vocabulary.Term.merged(standard)
        let casualTerms = Vocabulary.Term.merged(casual)

        guard !standardTerms.isEmpty || !casualTerms.isEmpty else {
            standardBoost = nil
            casualBoost = nil
            return
        }

        do {
            let start = Date()
            // One shared load, even if the vocabulary changes while it downloads.
            let load = ctcLoad ?? Task { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
            ctcLoad = load
            let ctc: CtcModels
            do {
                ctc = try await load.value
            } catch {
                ctcLoad = nil  // retry next time
                throw error
            }
            let standardSession = try await Self.makeSession(standardTerms, ctc: ctc)
            let casualSession = try await Self.makeSession(casualTerms, ctc: ctc)
            // A newer call may have started while we were loading.
            guard generation == vocabularyGeneration else { return }
            standardBoost = standardSession
            casualBoost = casualSession
            log.info("Vocabulary ready: \(standardTerms.count) terms (+\(casualTerms.count - standardTerms.count) casual) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        } catch {
            log.error("Vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeSession(_ terms: [Vocabulary.Term], ctc: CtcModels) async throws -> VocabularyBoostingSession? {
        guard !terms.isEmpty else { return nil }
        let context = CustomVocabularyContext(
            terms: terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) }
        )
        return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc, thresholds: boostThresholds)
    }

    /// Rescoring thresholds. FluidAudio's defaults (recall-oriented).
    static let boostThresholds = VocabularyBoostingSession.Thresholds()

    public func transcribe(_ audio: RecordedAudio, boost: VocabularyBoost) async throws -> String {
        guard let manager else { throw TranscriberError.notReady }

        var samples = audio.sampleRate == 16_000
            ? audio.samples
            : try converter.resample(audio.samples, from: audio.sampleRate)

        // Pad with a little silence so the final word isn't clipped by the decoder.
        samples.append(contentsOf: [Float](repeating: 0, count: 16_000 / 4))
        // Parakeet needs at least ~1 s of input.
        if samples.count < 16_000 {
            samples.append(contentsOf: [Float](repeating: 0, count: 16_000 - samples.count))
        }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)

        let session = boost == .casual ? casualBoost : standardBoost
        guard let session, let timings = result.tokenTimings, !timings.isEmpty,
              session.hasCTCRescoringCandidates(text: result.text, tokenTimings: timings)
        else { return result.text }

        let start = Date()
        guard let rescored = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
              rescored.wasModified
        else { return result.text }

        let swaps = rescored.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
        log.info("Vocabulary: \(swaps.count) swap(s) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
        return rescored.text
    }
}
