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
    private let boostThresholds: VocabularyBoostingSession.Thresholds
    private var isCommonWord: CommonWordCheck?

    /// - Parameter boostThresholds: how sure the name matcher must be before swapping a word.
    public init(model: ParakeetModel = .ultra, boostThresholds: VocabularyBoostingSession.Thresholds = .recall) {
        self.model = model
        self.boostThresholds = boostThresholds
    }

    /// Words the name matcher may never replace (real dictionary words like "coding").
    /// Your vocabulary terms are names and slang the dictionary doesn't know, so a swap
    /// away from a real word is almost always wrong.
    public typealias CommonWordCheck = @Sendable (String) async -> Bool

    public func setCommonWordCheck(_ check: CommonWordCheck?) {
        isCommonWord = check
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
            let standardSession = try await makeSession(standardTerms, ctc: ctc)
            let casualSession = try await makeSession(casualTerms, ctc: ctc)
            // A newer call may have started while we were loading.
            guard generation == vocabularyGeneration else { return }
            standardBoost = standardSession
            casualBoost = casualSession
            log.info("Vocabulary ready: \(standardTerms.count) terms (+\(casualTerms.count - standardTerms.count) casual) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        } catch {
            log.error("Vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeSession(_ terms: [Vocabulary.Term], ctc: CtcModels) async throws -> VocabularyBoostingSession? {
        guard !terms.isEmpty else { return nil }
        let context = CustomVocabularyContext(
            terms: terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) }
        )
        return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc, thresholds: boostThresholds)
    }


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

        // Keep only swaps away from words the dictionary doesn't know.
        var accepted: [(from: String, to: String)] = []
        var blocked = 0
        for swap in rescored.replacements where swap.shouldReplace {
            guard let to = swap.replacementWord else { continue }
            if let isCommonWord, await Self.isAllCommon(swap.originalWord, isCommonWord) {
                blocked += 1
            } else {
                accepted.append((swap.originalWord, to))
            }
        }
        log.info("Vocabulary: \(accepted.count) swap(s), \(blocked) blocked, in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
        if blocked == 0 { return rescored.text }
        return accepted.reduce(result.text) { Self.replacingFirst($1.from, with: $1.to, in: $0) }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }).map(String.init)
    }

    static func isAllCommon(_ phrase: String, _ check: CommonWordCheck) async -> Bool {
        let parts = words(phrase)
        guard !parts.isEmpty else { return false }
        for part in parts where !(await check(part)) { return false }
        return true
    }

    /// Replaces the first whole-word occurrence of `from` (ignoring its punctuation), keeping
    /// the punctuation around it.
    static func replacingFirst(_ from: String, with to: String, in text: String) -> String {
        let fromWords = words(from), toWords = words(to)
        guard !fromWords.isEmpty, !toWords.isEmpty else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + fromWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s,.-]+")
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return text }
        return (text as NSString).replacingCharacters(in: match.range, with: toWords.joined(separator: " "))
    }
}

extension VocabularyBoostingSession.Thresholds {
    /// FluidAudio's recall-oriented defaults. Used with the common-word check, which blocks
    /// the wrong swaps these make with hundreds of contact names ("party" -> "Parth").
    public static let recall = VocabularyBoostingSession.Thresholds()
    /// FluidAudio's strict dictation setting. Measured with 162 names: no wrong swaps, but it
    /// fixed only 3 of 22 misheard names (recall + common-word check: 9 of 22).
    public static let dictation = VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7)
}
