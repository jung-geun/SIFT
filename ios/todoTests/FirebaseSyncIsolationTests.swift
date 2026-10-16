import Foundation
import Testing
@testable import todo

private final class FirebaseSnapshotURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class SnapshotRequestProbe: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let host: String
        let path: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    func append(_ request: URLRequest) {
        lock.lock()
        recorded.append(Request(
            method: request.httpMethod ?? "",
            host: request.url?.host ?? "",
            path: request.url?.path ?? ""
        ))
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

@Suite("Firebase snapshot app isolation")
struct FirebaseSyncIsolationTests {
    @Test("upload and download target this app's snapshot, never the other app's document")
    func variantSpecificSnapshotPath() async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let service = "pieroot.todo.gmail"
            let previousToken = KeychainStore.get(service: service, account: "id_token")
            defer {
                FirebaseSnapshotURLProtocol.handler = nil
                if let previousToken {
                    KeychainStore.set(service: service, account: "id_token", value: previousToken)
                } else {
                    KeychainStore.deleteAny(service: service, account: "id_token")
                }
            }
            KeychainStore.set(service: service, account: "id_token", value: "test-google-id-token")

            let probe = SnapshotRequestProbe()
            FirebaseSnapshotURLProtocol.handler = { request in
                let url = try #require(request.url)
                let response: HTTPURLResponse
                let body: Data
                if url.host == "identitytoolkit.googleapis.com" {
                    response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                    body = Data(#"{"localId":"isolation-user","idToken":"firebase-token","email":"test@example.invalid"}"#.utf8)
                } else {
                    probe.append(request)
                    let status = request.httpMethod == "GET" ? 404 : 200
                    response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                    body = Data("{}".utf8)
                }
                return (response, body)
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FirebaseSnapshotURLProtocol.self]
            let snapshot = try await FirebaseSyncService(session: URLSession(configuration: configuration))
            _ = try await snapshot.uploadSnapshot("{}", passphrase: "local-test-passphrase")
            _ = try await snapshot.downloadSnapshot(passphrase: "local-test-passphrase")

            #if SIFT_QA
            let expectedDocument = "snapshot-qa"
            #else
            let expectedDocument = "snapshot"
            #endif
            let expectedPath = "/users/isolation-user/appData/\(expectedDocument)"
            let requests = probe.requests
            #expect(requests.map(\.method) == ["PATCH", "GET"])
            #expect(requests.allSatisfy {
                $0.host == "firestore.googleapis.com" && $0.path.hasSuffix(expectedPath)
            })
        }
    }
}

private final class SnapshotPayloadExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: Any] = [:]
    let alteration: String?

    init(alteration: String?) { self.alteration = alteration }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        if url.host == "identitytoolkit.googleapis.com" {
            return (response, Data(#"{"localId":"cipher-user","idToken":"firebase-token","email":"test@example.invalid"}"#.utf8))
        }
        if request.httpMethod == "PATCH" {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let uploaded = try #require(object["fields"] as? [String: Any])
            lock.withLock { fields = uploaded }
            return (response, Data("{}".utf8))
        }
        var downloaded = lock.withLock { fields }
        switch alteration {
        case "negativeIterations": downloaded["iterations"] = ["integerValue": "-1"]
        case "excessiveIterations": downloaded["iterations"] = ["integerValue": "\(Int.max)"]
        case "unsupportedVersion": downloaded["version"] = ["integerValue": "2"]
        case "unsupportedKDF": downloaded["kdf"] = ["stringValue": "UNKNOWN"]
        case "missingKDF": downloaded.removeValue(forKey: "kdf")
        case "shortSalt": downloaded["salt"] = ["stringValue": Data(repeating: 0, count: 8).base64EncodedString()]
        case "shortIV": downloaded["iv"] = ["stringValue": Data(repeating: 0, count: 8).base64EncodedString()]
        case "truncatedCiphertext": downloaded["ciphertext"] = ["stringValue": Data(repeating: 0, count: 15).base64EncodedString()]
        case "tamperedCiphertext":
            let raw = try #require((downloaded["ciphertext"] as? [String: Any])?["stringValue"] as? String)
            var data = try #require(Data(base64Encoded: raw))
            data[data.startIndex] ^= 1
            downloaded["ciphertext"] = ["stringValue": data.base64EncodedString()]
        default: break
        }
        return (response, try JSONSerialization.data(withJSONObject: ["fields": downloaded]))
    }
}

@Suite("Firebase encrypted snapshot boundaries", .serialized)
struct FirebaseEncryptedSnapshotTests {
    private func withExchange(
        alteration: String? = nil,
        operation: (FirebaseSyncService) async throws -> Void
    ) async throws {
        try await AIProviderTestIsolation.shared.withLock {
            let service = "pieroot.todo.gmail"
            let previous = KeychainStore.get(service: service, account: "id_token")
            defer {
                FirebaseSnapshotURLProtocol.handler = nil
                if let previous { KeychainStore.set(service: service, account: "id_token", value: previous) }
                else { KeychainStore.deleteAny(service: service, account: "id_token") }
            }
            KeychainStore.set(service: service, account: "id_token", value: "test-google-id-token")
            let exchange = SnapshotPayloadExchange(alteration: alteration)
            FirebaseSnapshotURLProtocol.handler = exchange.response(for:)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FirebaseSnapshotURLProtocol.self]
            let snapshot = try FirebaseSyncService(session: URLSession(configuration: configuration))
            _ = try await snapshot.uploadSnapshot(#"{"title":"로컬 할 일"}"#, passphrase: "local-passphrase")
            try await operation(snapshot)
        }
    }

    @Test("encrypted snapshot preserves UTF-8 and rejects a wrong passphrase")
    func encryptedRoundTrip() async throws {
        try await withExchange { snapshot in
            let json = try await snapshot.downloadSnapshot(passphrase: "local-passphrase")
            #expect(json == #"{"title":"로컬 할 일"}"#)
            await #expect(throws: (any Error).self) {
                _ = try await snapshot.downloadSnapshot(passphrase: "wrong-passphrase")
            }
        }
    }

    @Test("untrusted envelope parameters are rejected before key derivation", arguments: [
        "negativeIterations", "excessiveIterations", "unsupportedVersion", "unsupportedKDF",
        "missingKDF", "shortSalt", "shortIV", "truncatedCiphertext"
    ])
    func invalidEnvelope(alteration: String) async throws {
        try await withExchange(alteration: alteration) { snapshot in
            do {
                _ = try await snapshot.downloadSnapshot(passphrase: "local-passphrase")
                Issue.record("Expected invalid snapshot")
            } catch FirebaseSyncError.invalidSnapshot {
                // Expected before PBKDF2 and before any trapping UInt32 conversion.
            }
        }
    }

    @Test("modified ciphertext cannot be restored")
    func tamperedCiphertext() async throws {
        try await withExchange(alteration: "tamperedCiphertext") { snapshot in
            await #expect(throws: (any Error).self) {
                _ = try await snapshot.downloadSnapshot(passphrase: "local-passphrase")
            }
        }
    }
}
