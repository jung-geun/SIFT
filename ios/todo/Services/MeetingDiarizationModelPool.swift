import CoreML
@preconcurrency import FluidAudio
import Foundation

/// A loading task owns one store lease; borrowers reserve it before suspending.
/// Cancellation never cancels a sibling's load. The last borrower waits for the
/// load to settle before releasing the lease, including failed/cancelled prepares.
actor MeetingDiarizationModelPool<Key: Hashable & Sendable, Value: Sendable> {
    nonisolated struct Lease: Sendable {
        let key: Key
        let id: UUID
        let value: Value
    }

    nonisolated private struct Entry {
        let task: Task<Value, Error>
        let release: @Sendable () async -> Void
        var borrowers: Set<UUID>
    }

    private var entries: [Key: Entry] = [:]
    /// Ownership snapshot for deterministic lifecycle regressions (no model data).
    func borrowerCount(for key: Key) -> Int { entries[key]?.borrowers.count ?? 0 }


    func acquire(
        key: Key,
        load: @escaping @Sendable () async throws -> Value,
        release: @escaping @Sendable () async -> Void
    ) async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()
        if entries[key] == nil {
            entries[key] = Entry(task: Task.detached { try await load() }, release: release, borrowers: [])
        }
        entries[key]!.borrowers.insert(id)
        let task = entries[key]!.task
        do {
            let value = try await task.value
            try Task.checkCancellation()
            return Lease(key: key, id: id, value: value)
        } catch {
            await self.release(key: key, id: id)
            throw error
        }
    }

    func release(key: Key, id: UUID) async {
        guard var entry = entries[key], entry.borrowers.remove(id) != nil else { return }
        if !entry.borrowers.isEmpty {
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        // A failed loader is responsible for unwinding its own partial lease.
        if case .success = await entry.task.result { await entry.release() }
    }
}

/// Only weights and read-only Swift Array storage are shared. Nemotron3Models
/// itself is NOT immutable: it contains mutable MLMultiArray scratch/backings
/// and MLPredictionOptions (SDK v0.17.4). Construct a fresh wrapper per diarizer.
nonisolated final class MeetingDiarizationModelWeights: @unchecked Sendable {
    private let model: MLModel
    private let silenceEmbedding: [Float]
    private let projection: [Float]?
    private let predictionLock = NSLock()

    init(config: Nemotron3Config, directory: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: directory.appendingPathComponent(config.modelFileName), configuration: configuration)
        let silence = try Data(contentsOf: directory.appendingPathComponent("learnable_sil_emb.bin"))
        guard silence.count == config.preEncoderDims * MemoryLayout<Float>.size else {
            throw MeetingDiarizationFailure.modelUnavailable
        }
        silenceEmbedding = silence.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if config.splitGraph {
            let data = try Data(contentsOf: directory.appendingPathComponent("pre_encode_proj_t.bin"))
            guard data.count == 1024 * 512 * MemoryLayout<Float>.size else {
                throw MeetingDiarizationFailure.modelUnavailable
            }
            projection = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else {
            projection = nil
        }
    }

    func makeModels(config: Nemotron3Config) throws -> Nemotron3Models {
        try Nemotron3Models(config: config, model: model, silenceEmbedding: silenceEmbedding, preEncodeProjection: projection)
    }

    /// Core ML's shared MLModel is never predicted concurrently. Cover SDK input
    /// packing through output readback, not just prediction, so SDK changes cannot
    /// expose borrowed output backing storage to another worker's prediction.
    func withPredictionLock<T>(_ body: () throws -> T) rethrows -> T {
        try predictionLock.withLock(body)
    }
}

nonisolated struct MeetingDiarizationModelKey: Hashable, Sendable {
    let storeID: ObjectIdentifier
    let preset: MeetingDiarizationPreset
}
