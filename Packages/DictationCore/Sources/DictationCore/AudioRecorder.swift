import AVFoundation
import Foundation

/// Captured microphone audio: mono float samples at the device's native rate.
public struct RecordedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

public enum RecorderError: LocalizedError {
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        }
    }
}

/// Records the default microphone into memory while dictation is active.
///
/// A fresh `AVAudioEngine` is created for every recording so that switching
/// microphones (e.g. AirPods connecting) between dictations just works.
public final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    /// Called on the audio thread with a 0...1 loudness value for the UI meter.
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public var isRecording: Bool { engine != nil }

    public func start() throws {
        guard engine == nil else { return }
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        sampleRate = format.sampleRate
        lock.withLock { samples.reserveCapacity(Int(format.sampleRate) * 30) }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops recording and returns everything captured since `start()`.
    @discardableResult
    public func stop() -> RecordedAudio {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        let captured = lock.withLock { samples }
        return RecordedAudio(samples: captured, sampleRate: sampleRate)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return }

        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let ptr = channelData[c]
            for i in 0..<frames { mono[i] += ptr[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<frames { mono[i] *= scale }
        }

        var sumSquares: Float = 0
        for v in mono { sumSquares += v * v }
        let rms = (sumSquares / Float(frames)).squareRoot()

        lock.withLock { samples.append(contentsOf: mono) }
        // Map RMS (speech is roughly 0.01...0.3) onto a 0...1 meter.
        onLevel?(min(1, rms * 6))
    }
}
