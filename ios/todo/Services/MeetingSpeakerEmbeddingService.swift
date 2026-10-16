import Accelerate
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Foundation

/// Voice evidence exists only for this pass over one recording. No network,
/// enrollment, persisted voiceprints, or inference alongside a Nemotron worker.
nonisolated enum MeetingSpeakerEmbeddingService {
    private struct Clip: Hashable {
        let start: Int64
        let end: Int64
    }

    private struct Sum {
        var values = [Double](repeating: 0, count: 256)

        mutating func add(_ vector: [Float]) {
            for index in values.indices { values[index] += Double(vector[index]) }
        }

        var normalized: [Float]? {
            let squared = values.reduce(0) { $0 + $1 * $1 }
            guard squared.isFinite, squared > 0 else { return nil }
            let scale = 1 / sqrt(squared)
            return values.map { Float($0 * scale) }
        }
    }

    static func run(
        manifest: MeetingAudioManifest,
        detected: [MeetingSpeakerInterval],
        reference: [MeetingSpeakerInterval],
        store: MeetingDiarizationModelStore = .shared,
        rootURL: URL = AppDataContainer.meetingDirectory(),
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingSpeakerVoiceEvidence {
        try Task.checkCancellation()
        let newWindows = MeetingSpeakerEmbeddingWindows.select(intervals: detected, totalSamples: manifest.totalSamples)
        let referenceWindows = MeetingSpeakerEmbeddingWindows.select(intervals: reference, totalSamples: manifest.totalSamples)
        guard !newWindows.isEmpty, !referenceWindows.isEmpty else {
            progress(1)
            return MeetingSpeakerVoiceEvidence(newEmbeddings: [:], referenceEmbeddings: [:])
        }
        guard manifest.sampleRate == 16_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw MeetingDiarizationFailure.timelineMismatch }

        let directory = try await store.acquire()
        do {
            try Task.checkCancellation()
            let extractor = try MeetingSpeakerEmbeddingExtractor(directory: directory)
            let cursor: MeetingLogicalAudioCursor
            do {
                cursor = try MeetingLogicalAudioCursor(manifest: manifest, rootURL: rootURL)
            } catch {
                throw MeetingDiarizationFailure.audioUnavailable
            }
            // Identical bounds across the two timelines need only one prediction.
            var uniqueClips: Set<Clip> = []
            for window in newWindows { uniqueClips.insert(Clip(start: window.startSample, end: window.endSample)) }
            for window in referenceWindows { uniqueClips.insert(Clip(start: window.startSample, end: window.endSample)) }
            let clips = uniqueClips.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            var vectors: [Clip: [Float]] = [:]
            vectors.reserveCapacity(clips.count)
            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                let vector = try autoreleasepool {
                    try extractor.embedding(startSample: clip.start, endSample: clip.end, cursor: cursor, format: format)
                }
                vectors[clip] = vector
                progress(Double(index + 1) / Double(clips.count))
            }
            try Task.checkCancellation()
            let evidence = MeetingSpeakerVoiceEvidence(
                newEmbeddings: centroids(windows: newWindows, vectors: vectors),
                referenceEmbeddings: centroids(windows: referenceWindows, vectors: vectors)
            )
            await store.release()
            return evidence
        } catch {
            await store.release()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error as? MeetingDiarizationFailure ?? .inferenceFailed
        }
    }

    private static func centroids(
        windows: [MeetingSpeakerEmbeddingWindows.Window], vectors: [Clip: [Float]]
    ) -> [String: [Float]] {
        var sums: [String: Sum] = [:]
        for window in windows {
            guard let vector = vectors[Clip(start: window.startSample, end: window.endSample)] else { continue }
            sums[window.speakerID, default: Sum()].add(vector)
        }
        return sums.compactMapValues(\.normalized)
    }
}

/// Pinned Community-1 FBANK -> WeSpeaker graphs. Reuses batch-one input storage;
/// only each selected two-to-three-second clip is decoded, never a whole meeting.
nonisolated final class MeetingSpeakerEmbeddingExtractor {
    private static let audioSamples = 160_000
    private static let maskFrames = 589
    private let fbank: MLModel
    private let model: MLModel
    private let audio: MLMultiArray
    private let weights: MLMultiArray
    private let fbankInput: MLDictionaryFeatureProvider
    private let embeddingInput: EmbeddingInput

    init(directory: URL) throws {
        try Task.checkCancellation()
        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly
        fbank = try MLModel(contentsOf: directory.appendingPathComponent("FBank.mlmodelc"), configuration: fbankConfiguration)
        try Task.checkCancellation()
        let embeddingConfiguration = MLModelConfiguration()
        embeddingConfiguration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: directory.appendingPathComponent("Embedding.mlmodelc"), configuration: embeddingConfiguration)
        try Task.checkCancellation()
        guard fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape == [1, 1, 160_000],
              fbank.modelDescription.outputDescriptionsByName["fbank_features"]?.type == .multiArray,
              model.modelDescription.inputDescriptionsByName["fbank_features"]?.multiArrayConstraint?.shape == [1, 1, 80, 998],
              model.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint?.shape == [1, 589],
              model.modelDescription.outputDescriptionsByName["embedding"]?.type == .multiArray
        else { throw MeetingDiarizationFailure.artifactCorrupt }
        audio = try MLMultiArray(shape: [1, 1, 160_000], dataType: .float32)
        weights = try MLMultiArray(shape: [1, 589], dataType: .float32)
        fbankInput = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)])
        embeddingInput = EmbeddingInput(weights: MLFeatureValue(multiArray: weights))
    }

    func embedding(
        startSample: Int64, endSample: Int64,
        cursor: MeetingLogicalAudioCursor, format: AVAudioFormat
    ) throws -> [Float] {
        let length = endSample - startSample
        guard startSample >= 0, endSample <= cursor.manifest.totalSamples,
              length >= Int64(MeetingSpeakerEmbeddingWindows.minimumSamples),
              length <= Int64(MeetingSpeakerEmbeddingWindows.targetSamples)
        else { throw MeetingDiarizationFailure.timelineMismatch }
        try Task.checkCancellation()
        let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        // The clean clip is copied to the prefix and then tiled to fill the full
        // 10-second buffer, preventing zero-padded silence from distorting FBank's CMVN.
        do {
            try cursor.seek(toLogicalSample: startSample)
            var copied = 0
            while copied < Int(length) {
                try Task.checkCancellation()
                guard let buffer = try cursor.nextPCMBuffer(maxFrames: length - Int64(copied), outputFormat: format),
                      buffer.frameLength > 0, let channel = buffer.floatChannelData?[0]
                else { throw MeetingDiarizationFailure.audioUnavailable }
                let count = Int(buffer.frameLength)
                guard count <= Int(length) - copied else { throw MeetingDiarizationFailure.timelineMismatch }
                audioPointer.advanced(by: copied).update(from: channel, count: count)
                copied += count
            }
        } catch {
            if error is CancellationError { throw error }
            throw error as? MeetingDiarizationFailure ?? .audioUnavailable
        }

        // Tile the clean speech window across the full 10-second buffer so that
        // FBank's cepstral mean normalization operates on speech alone.
        var filled = Int(length)
        while filled < Self.audioSamples {
            let chunk = min(filled, Self.audioSamples - filled)
            audioPointer.advanced(by: filled).update(from: audioPointer, count: chunk)
            filled += chunk
        }

        // The entire 10-second window is filled with valid speech from this solo speaker.
        let weightPointer = weights.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<Self.maskFrames {
            weightPointer[index] = 1.0
        }
        try Task.checkCancellation()
        let features = try fbank.prediction(from: fbankInput)
        guard let feature = features.featureValue(for: "fbank_features"), feature.multiArrayValue != nil else {
            throw MeetingDiarizationFailure.inferenceFailed
        }
        embeddingInput.fbank = feature
        defer { embeddingInput.fbank = nil }
        try Task.checkCancellation()
        let result = try model.prediction(from: embeddingInput)
        try Task.checkCancellation()
        guard let array = result.featureValue(for: "embedding")?.multiArrayValue,
              array.dataType == .float32, array.count == 256,
              let axis = array.shape.firstIndex(where: { $0.intValue == 256 }),
              array.shape.enumerated().allSatisfy({ $0.offset == axis || $0.element.intValue == 1 })
        else { throw MeetingDiarizationFailure.inferenceFailed }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let stride = array.strides[axis].intValue
        var vector = [Float](repeating: 0, count: 256)
        var squared = 0.0
        for index in vector.indices {
            let value = pointer[index * stride]
            guard value.isFinite else { throw MeetingDiarizationFailure.inferenceFailed }
            vector[index] = value
            squared += Double(value) * Double(value)
        }
        guard squared > 0, squared.isFinite else { throw MeetingDiarizationFailure.inferenceFailed }
        let scale = 1 / sqrt(squared)
        for index in vector.indices { vector[index] = Float(Double(vector[index]) * scale) }
        return vector
    }

    nonisolated private final class EmbeddingInput: MLFeatureProvider {
        let featureNames: Set<String> = ["fbank_features", "weights"]
        private let weights: MLFeatureValue
        var fbank: MLFeatureValue?

        init(weights: MLFeatureValue) { self.weights = weights }

        func featureValue(for featureName: String) -> MLFeatureValue? {
            switch featureName {
            case "fbank_features": return fbank
            case "weights": return weights
            default: return nil
            }
        }
    }
}
