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

    @Test("MiniCPM5 1B MLX 모델은 낮은 메모리 티어에서 선택 가능하다")
    func testMiniCPM5ModelCatalogEntry() {
        let model = OnDeviceLLMService.modelCatalog.first {
            $0.id == OnDeviceLLMService.miniCPMModelID
        }

        #expect(model?.sizeMB == 620)
        #expect(model?.minMemoryGiB == 5.0)
        #expect(model?.promptPrefix == "<s>")
        #expect(model?.assistantPrimer == "<think>\n\n</think>\n\n")
        #expect(
            !OnDeviceLLMService.modelCatalog.contains {
                $0.id == "mlx-community/LFM2.5-1.2B-Instruct-4bit"
            }
        )
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
}
