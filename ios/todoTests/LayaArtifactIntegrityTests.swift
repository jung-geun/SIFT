import Foundation
import CryptoKit
import Testing
@testable import todo

@Suite("Laya artifact integrity")
@MainActor
struct LayaArtifactIntegrityTests {
    private static func makeValidConfig(
        repo: String = "convaiinnovations/laya",
        revision: String = "1c5edc17a7acd8701df6fc341c0d179f1c62c982",
        subfolder: String? = "multilingual",
        logitsOutput: String = "float32 [1, 32]"
    ) -> [String: Any] {
        var source: [String: Any] = [
            "repo": repo,
            "revision": revision
        ]
        if let subfolder {
            source["subfolder"] = subfolder
        }
        return [
            "format": "coreml",
            "source": source,
            "inputs": [
                "input_ids": "int32 [1, L]",
                "attention_mask": "int32 [1, L]",
                "marker_map": "float32 [1, 32, L]",
                "question_type": "float32 [1, 3]"
            ],
            "outputs": [
                "logits": logitsOutput,
                "probabilities": "float32 [1, 32]",
                "action_probabilities": "float32 [1, 2]"
            ],
            "max_options": 32,
            "head_max_len": 256
        ]
    }

    private static func createMockPayload(
        in directory: URL,
        configOverride: [String: Any]? = nil,
        tamperFile: String? = nil,
        omitFile: String? = nil,
        symlinkFile: String? = nil
    ) throws -> [String: LayaDecisionService.PinnedFile] {
        var pinned = [String: LayaDecisionService.PinnedFile]()
        let paths = LayaDecisionService.requiredFiles

        for path in paths {
            let dest = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            if path == symlinkFile {
                let target = directory.appendingPathComponent("symlink-target.txt")
                try Data("dummy".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: target)
                pinned[path] = LayaDecisionService.PinnedFile(size: 5, sha256: "dummy")
                continue
            }

            let bytes: Data
            if path == "config.json" {
                let json = configOverride ?? makeValidConfig()
                bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            } else {
                bytes = Data("laya-test-content-for-\(path)".utf8)
            }

            if path != omitFile {
                if path == tamperFile {
                    try Data("corrupted-bytes".utf8).write(to: dest)
                } else {
                    try bytes.write(to: dest)
                }
            }

            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            pinned[path] = LayaDecisionService.PinnedFile(size: Int64(bytes.count), sha256: digest)
        }
        return pinned
    }

    @Test("a complete-looking payload with a bad digest is never accepted for inference")
    func tamperedPayloadFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        let pinned = try Self.createMockPayload(
            in: directory,
            tamperFile: "laya_multilingual_e8_L256_options32.mlmodelc/model.mil"
        )

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
        #expect(!service.isModelInstalled)
    }

    @Test("an authentic config matching upstream identity and correct digests is accepted")
    func authenticConfigIdentityVerifies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        // Avoid mirroring code constants: authentic upstream contract literals are used directly
        let authenticConfig = Self.makeValidConfig(
            repo: "convaiinnovations/laya",
            revision: "1c5edc17a7acd8701df6fc341c0d179f1c62c982",
            subfolder: "multilingual"
        )
        let pinned = try Self.createMockPayload(in: directory, configOverride: authenticConfig)

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        #expect(service.isModelInstalled)
        let verifiedDirectory = try await service.verifiedModelDirectory()
        #expect(verifiedDirectory.path == directory.path)
        #expect(service.isModelInstalled)
    }

    @Test("config confusing download repo with source checkpoint repo fails closed")
    func confusedRepoConfigFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        // Download repo is FluidInference/laya-coreml, but config source repo must be convaiinnovations/laya
        let invalidConfig = Self.makeValidConfig(
            repo: "FluidInference/laya-coreml",
            revision: "1c5edc17a7acd8701df6fc341c0d179f1c62c982"
        )
        let pinned = try Self.createMockPayload(in: directory, configOverride: invalidConfig)

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
        #expect(!service.isModelInstalled)
    }

    @Test("config with wrong output contract fails closed")
    func wrongOutputContractFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        let invalidConfig = Self.makeValidConfig(logitsOutput: "float32 [1, 4]")
        let pinned = try Self.createMockPayload(in: directory, configOverride: invalidConfig)

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
        #expect(!service.isModelInstalled)
    }

    @Test("partial install missing files is never accepted as installed and fails verification")
    func partialInstallFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        let pinned = try Self.createMockPayload(
            in: directory,
            omitFile: "laya_multilingual_e8_L256_options32.mlmodelc/weights/weight.bin"
        )

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        #expect(!service.isModelInstalled)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
        #expect(!service.isModelInstalled)
    }

    @Test("symbolic link inside artifact is rejected")
    func symlinkFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)

        let pinned = try Self.createMockPayload(
            in: directory,
            symlinkFile: "laya_multilingual_e8_L256_options32.mlmodelc/coremldata.bin"
        )

        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        #expect(!service.isModelInstalled)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
    }

    @Test("an unpinned compiled-model member cannot redirect model loading")
    func unpinnedCompiledMemberFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LayaDecisionService.modelRevision)
        let pinned = try Self.createMockPayload(in: directory)
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("laya_multilingual_e8_L256_options32.mlmodelc/Manifest.json")
        )
        let service = LayaDecisionService(installRoot: root, expectedFiles: pinned)
        await #expect(throws: (any Error).self) {
            _ = try await service.verifiedModelDirectory()
        }
        #expect(!service.isModelInstalled)
    }

}
