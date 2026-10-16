import CoreML
import Foundation

/// One static typed forward pass per question. Holds the compiled graph in memory
/// while selected, never transmits user text or model input tensors.
actor LayaCoreMLRunner {
    static let shared = LayaCoreMLRunner()

    enum Failure: Error {
        case invalidOutput
    }

    private var loadedURL: URL?
    private var loadedModel: MLModel?

    func predict(_ input: LayaPriorityEncoding.Input, modelDirectory: URL) async throws -> LayaAnswer {
        try Task.checkCancellation()
        try input.question.validate()
        guard (2...4).contains(input.activeOptions),
              input.markerPositions.count == input.activeOptions,
              input.activeOptions == input.question.labels.count,
              input.tokenIDs.count == LayaPriorityEncoding.sequenceLength,
              input.attentionMask.count == LayaPriorityEncoding.sequenceLength,
              input.markerPositions.allSatisfy({ (0..<LayaPriorityEncoding.sequenceLength).contains($0) }) else {
            throw Failure.invalidOutput
        }
        let model = try await loadModel(from: modelDirectory)
        let ids = try Self.array(input.tokenIDs, shape: [1, LayaPriorityEncoding.sequenceLength])
        let attention = try Self.array(input.attentionMask, shape: [1, LayaPriorityEncoding.sequenceLength])

        let markerMap = try MLMultiArray(shape: [1, 32, 256], dataType: .float32)
        let markerPointer = markerMap.dataPointer.assumingMemoryBound(to: Float32.self)
        markerPointer.initialize(repeating: 0, count: 32 * 256)
        for (optionIndex, position) in input.markerPositions.enumerated() {
            markerPointer[optionIndex * 256 + position] = 1.0
        }

        let questionType = try MLMultiArray(shape: [1, 3], dataType: .float32)
        let qPointer = questionType.dataPointer.assumingMemoryBound(to: Float32.self)
        qPointer.initialize(repeating: 0, count: 3)
        qPointer[input.question.type.index] = 1

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: attention),
            "marker_map": MLFeatureValue(multiArray: markerMap),
            "question_type": MLFeatureValue(multiArray: questionType)
        ])
        let output = try await model.prediction(from: provider)
        try Task.checkCancellation()
        func values(_ name: String, count: Int) throws -> [Double] {
            guard let array = output.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float32, array.count == count else { throw Failure.invalidOutput }
            return (0..<count).map { array[$0].doubleValue }
        }
        let logits = try values("logits", count: LayaPriorityEncoding.maxOptions)
        let raw = try values("probabilities", count: LayaPriorityEncoding.maxOptions)
        let action = try values("action_probabilities", count: 2)
        guard action.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(action.reduce(0, +) - 1) <= 0.01 else { throw Failure.invalidOutput }
        return try LayaAnswer(
            question: input.question,
            logits: Array(logits.prefix(input.activeOptions)),
            rawProbabilities: Array(raw.prefix(input.activeOptions)),
            actionProbability: action[0],
            stateWasTruncated: input.stateWasTruncated,
            tokenCount: input.tokenCount,
            modelRevision: LayaDecisionService.modelRevision
        )
    }

    private func loadModel(from directory: URL) async throws -> MLModel {
        if loadedURL == directory, let loadedModel { return loadedModel }
        let modelURL = directory.appendingPathComponent("laya_multilingual_e8_L256_options32.mlmodelc")
        // The artifact is distributed pre-compiled as .mlmodelc; do not compile compiled model at runtime.
        // Configured with .cpuAndNeuralEngine for on-device inference; host execution dynamically places graph layers.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        loadedURL = directory
        loadedModel = model
        return model
    }

    func unload() {
        loadedURL = nil
        loadedModel = nil
    }

    private static func array(_ values: [Int], shape: [Int]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        guard result.count == values.count else { throw Failure.invalidOutput }
        let pointer = result.dataPointer.assumingMemoryBound(to: Int32.self)
        for (index, value) in values.enumerated() {
            guard let exact = Int32(exactly: value) else { throw Failure.invalidOutput }
            pointer[index] = exact
        }
        return result
    }
}
