import FluidAudio
import Foundation
import OSLog

let log = Logger(subsystem: "com.dictionapp.core", category: "core")

/// Speech-to-text engine. Implementations must be safe to call from any task.
public protocol Transcriber: Sendable {
    /// Downloads (first run only) and loads the model, then warms it up.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ audio: RecordedAudio) async throws -> String
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

    public func transcribe(_ audio: RecordedAudio) async throws -> String {
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
        return result.text
    }
}
