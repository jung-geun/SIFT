import Foundation
import Testing
@testable import todo

@Suite("On-device model support state")
@MainActor
struct OnDeviceModelSupportStateTests {
    @Test("지원 가능하고 모델이 있으면 선택지를 표시한다")
    func testAvailableModelChoices() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: true,
                availableModelCount: 1
            ) == .available
        )
    }

    @Test("Retired local model selections migrate to a supported model")
    func testRetiredModelSelectionMigration() {
        #expect(
            OnDeviceLLMService.normalizedModelID(
                OnDeviceLLMService.retiredLFMModelID
            ) == OnDeviceLLMService.miniCPMModelID
        )
    }

    @Test("ChatML 종료 토큰을 순서대로 보존한다")
    func testTokenizerPreservesInterleavedChatMLTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tokenizerJSON = """
        {
          "added_tokens": [
            { "id": 130072, "content": "<|im_start|>" },
            { "id": 130073, "content": "<|im_end|>" }
          ],
          "model": { "vocab": {}, "merges": [] }
        }
        """
        try Data(tokenizerJSON.utf8).write(
            to: directory.appendingPathComponent("tokenizer.json")
        )

        let tokenizer = try BPETokenizer(directory: directory)
        let ids = tokenizer.encode(
            text: "<|im_start|>system<|im_end|><|im_start|>user<|im_end|>",
            addSpecialTokens: false
        )

        #expect(ids == [130072, 130073, 130072, 130073])
    }

    @Test("메모리 기준을 충족하지 못하면 미지원 상태다")
    func testInsufficientMemoryIsUnsupported() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: false,
                availableModelCount: 0
            ) == .unsupported
        )
    }

    @Test("표시 가능한 모델이 없으면 미지원 상태다")
    func testEmptyModelCatalogIsUnsupported() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: true,
                availableModelCount: 0
            ) == .unsupported
        )
    }

    @Test("Partial downloaded caches stay out of provider selection and deleted files invalidate readiness")
    func partialCacheIsNotSelectable() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = BetaProviderAccess(
            foundationModelsEnabled: false, onDeviceEnabled: true, openAIEnabled: false,
            layaEnabled: false, meetingVoiceProcessingEnabled: false
        )
        func selectableProviders() -> [PersonaAIProvider] {
            BetaProviderReadiness(
                foundationModelsAvailable: false,
                onDeviceModelUsable: OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false) != nil,
                openAIAccountConnected: false, openAIPlanPermitted: false, layaModelUsable: false
            ).selectableProviders(access: access)
        }

        #expect(selectableProviders().isEmpty)
        try writeCacheFile("config.json", contents: "{}", in: directory)
        try writeCacheFile("tokenizer.json", contents: "{}", in: directory)
        #expect(selectableProviders().isEmpty)
        try writeCacheFile("weights.safetensors", contents: "", in: directory)
        #expect(selectableProviders().isEmpty)
        try writeCacheFile("weights.safetensors", contents: "weight fixture", in: directory)
        #expect(selectableProviders() == [.onDevice])
        let snapshot = try #require(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tokenizer.json"))
        #expect(!snapshot.isUsable)
        #expect(selectableProviders().isEmpty)
    }

    @Test("Every indexed weight shard is required and a changed index invalidates the cached manifest")
    func indexedCacheRequiresEveryShard() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCacheFile("config.json", contents: "{}", in: directory)
        try writeCacheFile("tokenizer.json", contents: "{}", in: directory)
        try writeCacheFile("model.safetensors.index.json", contents: """
        {"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}
        """, in: directory)
        try writeCacheFile("model-00001-of-00002.safetensors", contents: "first shard", in: directory)
        #expect(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false) == nil)
        try writeCacheFile("model-00002-of-00002.safetensors", contents: "second shard", in: directory)
        let snapshot = try #require(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false))
        #expect(snapshot.isUsable)

        try writeCacheFile("model.safetensors.index.json", contents: """
        {"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors","c":"extra.safetensors"}}
        """, in: directory)
        #expect(!snapshot.isUsable)
        #expect(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false) == nil)
        try writeCacheFile("extra.safetensors", contents: "extra shard", in: directory)
        let updated = try #require(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: false))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(!updated.isUsable)
    }

    @Test("Native chat-template loading requires tokenizer configuration; a lone unindexed shard is not ready")
    func tokenizerAndUnindexedShardRequirements() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCacheFile("config.json", contents: "{}", in: directory)
        try writeCacheFile("tokenizer.json", contents: "{}", in: directory)
        try writeCacheFile("model.safetensors", contents: "weight fixture", in: directory)
        #expect(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: true) == nil)
        try writeCacheFile("tokenizer_config.json", contents: "{}", in: directory)
        #expect(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: true) != nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("model.safetensors"))
        try writeCacheFile("model-00001-of-00002.safetensors", contents: "first shard", in: directory)
        #expect(OnDeviceModelCacheSnapshot(directory: directory, requiresTokenizerConfiguration: true) == nil)
    }

    private func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeCacheFile(_ name: String, contents: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }
}
