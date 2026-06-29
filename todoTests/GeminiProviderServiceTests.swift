import Foundation
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
    }


    @Test("generateJSON sends POST with Gemini auth and JSON response mime type")
    func generateJSONRequestShape() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            GeminiProviderService.saveAPIKey("test-gemini-key")
            let service = GeminiProviderService(session: makeSession())

            GeminiMockURLProtocol.requestHandler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-gemini-key")
                let data = try requestBodyData(from: request)
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let generationConfig = try #require(body["generationConfig"] as? [String: Any])
                #expect(generationConfig["responseMimeType"] as? String == "application/json")

                let response = HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let payload = #"{"candidates":[{"content":{"parts":[{"text":"{\"scheduled_tasks\":[]}"}]}}]}"#.data(using: .utf8)
                return (response, payload)
            }

            let text = try await service.generateJSON(
                systemInstruction: "system",
                userPrompt: "user",
                modelID: GeminiProviderService.defaultModelID
            )

            #expect(text == #"{"scheduled_tasks":[]}"#)
        }
    }

    @Test("HTTP 403 maps to generationFailed HTTP 401/403")
    func maps403ToGenerationFailed() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            reset()
            defer { reset() }
            GeminiProviderService.saveAPIKey("test-gemini-key")
            let service = GeminiProviderService(session: makeSession())

            GeminiMockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("forbidden".utf8))
            }

            do {
                _ = try await service.generateJSON(
                    systemInstruction: "system",
                    userPrompt: "user",
                    modelID: GeminiProviderService.defaultModelID
                )
                Issue.record("Expected Gemini generation failure")
            } catch let error as IntelligenceRoutingError {
                switch error {
                case .generationFailed(let provider, let reason):
                    #expect(provider == .gemini)
                    #expect(reason == "HTTP 401/403")
                default:
                    Issue.record("Unexpected routing error: \(error.localizedDescription)")
                }
            } catch {
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }
}
