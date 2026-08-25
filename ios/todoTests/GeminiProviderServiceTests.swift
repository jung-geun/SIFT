import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Testing
@testable import todo

private final class GeminiMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("GeminiMockURLProtocol handler missing")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CountingGeminiTransport: @unchecked Sendable, GeminiHTTPTransport {
    private let lock = NSLock()
    private var requests = 0
    private let cancels: Bool

    init(cancels: Bool = false) {
        self.cancels = cancels
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requests += 1
        }
        if cancels { throw CancellationError() }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }

    func requestCount() -> Int {
        lock.withLock { requests }
    }
}

private final class CountingOnDeviceRuntime: OnDeviceModelRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var generations = 0

    func load() async throws {
        lock.withLock {
            loads += 1
        }
    }

    func unload() {}

    func generate(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        contextLength: Int
    ) async throws -> String {
        lock.withLock {
            generations += 1
        }
        throw CancellationError()
    }

    func counts() -> (loads: Int, generations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loads, generations)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private struct UncalledFoundationRuntime: FoundationModelsRuntime {
    func rankTodos(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMPriorityRankingList { fatalError("runtime must not be called") }
    func analyzeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailOutput { fatalError("runtime must not be called") }
    func summarizeEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailSummaryOutput { fatalError("runtime must not be called") }
    func generatePersonaNarrative(
        instructions: String,
        userPrompt: String
    ) async throws -> FMPersonaNarrativeOutput { fatalError("runtime must not be called") }
    func narrateBehavior(
        instructions: String,
        userPrompt: String
    ) async throws -> FMBehaviorNarrativeOutput { fatalError("runtime must not be called") }
    func analyzeMeeting(
        instructions: String,
        userPrompt: String
    ) async throws -> FMMeetingExtractionOutput { fatalError("runtime must not be called") }
    func correctTranscript(
        instructions: String,
        userPrompt: String,
        options: GenerationOptions
    ) async throws -> FMTranscriptCorrectionOutput { fatalError("runtime must not be called") }
    func draftTodoFromEmail(
        instructions: String,
        userPrompt: String
    ) async throws -> FMEmailTodoDraftOutput { fatalError("runtime must not be called") }
}
#endif

@Suite("GeminiProviderService", .serialized)
@MainActor
struct GeminiProviderServiceTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw NSError(domain: "GeminiProviderServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing request body"])
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? NSError(domain: "GeminiProviderServiceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed reading request body stream"])
            }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func reset() {
        GeminiMockURLProtocol.requestHandler = nil
        GeminiProviderService.deleteAPIKey()
        UserDefaults.standard.set(false, forKey: "pieroot.todo.iCloudSyncEnabled")
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaGeminiEnabledKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaSelectedProviderKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaFoundationModelsEnabledKey)
        UserDefaults.standard.removeObject(forKey: SettingsStore.betaOnDeviceModelEnabledKey)
        UserDefaults.standard.removeObject(forKey: "pieroot.todo.providerEmailAnalysisEnabled")
    }

    private func enableGeminiBeta() {
        UserDefaults.standard.set(true, forKey: SettingsStore.betaGeminiEnabledKey)
        UserDefaults.standard.set(
            PersonaAIProvider.gemini.rawValue,
            forKey: SettingsStore.betaSelectedProviderKey
        )
    }


    @Test("Disabled on-device provider performs zero load/generate calls")
    func disabledOnDeviceMakesNoCalls() async throws {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            let runtime = CountingOnDeviceRuntime()
            let service = OnDeviceLLMService(runtime: runtime)
            await service.loadModelIfNeeded(use: .standardAnalysis)
            do {
                _ = try await service.generate(
                    systemPrompt: "system",
                    userPrompt: "user",
                    use: .standardAnalysis
                )
                Issue.record("Expected disabled provider error")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerDisabled)
            }
            let counts = runtime.counts()
            #expect(counts.loads == 0)
            #expect(counts.generations == 0)
        }
    }
    @Test("Disabled Foundation Models performs zero runtime calls")
    @available(iOS 26.0, *)
    func disabledFoundationModelsMakesNoCalls() async throws {
        await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            UserDefaults.standard.set(false, forKey: SettingsStore.betaFoundationModelsEnabledKey)
            let service = FoundationModelsService(runtime: UncalledFoundationRuntime())
            do {
                _ = try await service.rankTodos(
                    todos: [],
                    events: [],
                    persona: .empty,
                    language: .english
                )
                Issue.record("Expected disabled provider error")
            } catch {
                #expect(ProviderErrorMapper.fallbackReason(for: error) == .providerDisabled)
            }
        }
    }
}
