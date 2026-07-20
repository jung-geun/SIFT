import Foundation
import CryptoKit
import CommonCrypto

struct FirebaseSyncResult: Sendable {
    let email: String
    let syncedAt: Date
}

enum FirebaseSyncError: LocalizedError {
    case missingConfig
    case missingGoogleIDToken
    case invalidResponse
    case invalidSnapshot
    case invalidPassphrase

    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .missingConfig:
            return AppLanguage.localized(
                "error.firebase.missingConfig",
                defaultValue: language == .english ? "Firebase configuration is missing." : "Firebase 설정 파일이 없습니다.",
                language: language,
                comment: "Firebase sync error shown when app configuration is unavailable."
            )
        case .missingGoogleIDToken:
            return AppLanguage.localized(
                "error.firebase.missingGoogleIDToken",
                defaultValue: language == .english
                    ? "Firebase sync cannot start because the Google ID token is missing. Please reconnect your Gmail account."
                    : "Google ID 토큰이 없어 Firebase 동기화를 시작할 수 없습니다. Gmail 계정을 다시 연결해 주세요.",
                language: language,
                comment: "Firebase sync error shown when Gmail authentication is unavailable."
            )
        case .invalidResponse:
            return AppLanguage.localized(
                "error.firebase.invalidResponse",
                defaultValue: language == .english ? "Could not read the Firebase response." : "Firebase 응답을 해석하지 못했습니다.",
                language: language,
                comment: "Firebase sync error shown when a server response cannot be decoded."
            )
        case .invalidSnapshot:
            return AppLanguage.localized(
                "error.firebase.invalidSnapshot",
                defaultValue: language == .english ? "The snapshot saved in Firebase is invalid." : "Firebase에 저장된 스냅샷이 올바르지 않습니다.",
                language: language,
                comment: "Firebase sync error shown when a stored snapshot is invalid."
            )
        case .invalidPassphrase:
            return AppLanguage.localized(
                "error.firebase.invalidPassphrase",
                defaultValue: language == .english ? "The encryption passphrase must be at least 8 characters." : "암호화 비밀번호는 8자 이상이어야 합니다.",
                language: language,
                comment: "Firebase sync error shown when the encryption passphrase is too short."
            )
        }
    }
}

private struct FirebaseGoogleSession: Sendable {
    let uid: String
    let idToken: String
    let email: String
}

private struct FirebaseEncryptedEnvelope: Codable, Sendable {
    let version: Int
    let kdf: String
    let salt: String
    let iterations: Int
    let iv: String
    let ciphertext: String
}

struct FirebaseSyncService {
    private let apiKey: String
    private let projectID: String
    private let session: URLSession

    init(session: URLSession = .shared) throws {
        guard
            let url = Bundle.main.url(forResource: "FirebaseConfig", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
            let apiKey = plist["APIKey"],
            let projectID = plist["ProjectID"],
            !apiKey.isEmpty,
            !projectID.isEmpty
        else {
            throw FirebaseSyncError.missingConfig
        }
        self.apiKey = apiKey
        self.projectID = projectID
        self.session = session
    }

    func uploadSnapshot(_ snapshotJSON: String, passphrase: String) async throws -> FirebaseSyncResult {
        let googleIDToken = try googleIDToken()
        let firebaseSession = try await signInToFirebase(googleIDToken: googleIDToken)
        let envelope = try encrypt(snapshotJSON: snapshotJSON, passphrase: passphrase)
        let payload = firestorePayload(email: firebaseSession.email, envelope: envelope)
        let url = firestoreDocumentURL(uid: firebaseSession.uid)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(firebaseSession.idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FirebaseSyncError.invalidResponse
        }
        return FirebaseSyncResult(email: firebaseSession.email, syncedAt: Date())
    }

    func downloadSnapshot(passphrase: String) async throws -> String? {
        let googleIDToken = try googleIDToken()
        let firebaseSession = try await signInToFirebase(googleIDToken: googleIDToken)
        var request = URLRequest(url: firestoreDocumentURL(uid: firebaseSession.uid))
        request.httpMethod = "GET"
        request.setValue("Bearer \(firebaseSession.idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FirebaseSyncError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw FirebaseSyncError.invalidResponse }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let fields = object["fields"] as? [String: Any]
        else {
            throw FirebaseSyncError.invalidSnapshot
        }
        let envelope = try envelope(from: fields)
        return try decrypt(envelope: envelope, passphrase: passphrase)
    }

    private func signInToFirebase(googleIDToken: String) async throws -> FirebaseGoogleSession {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": "id_token=\(googleIDToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
            "returnIdpCredential": true
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FirebaseSyncError.invalidResponse
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let uid = object["localId"] as? String,
            let idToken = object["idToken"] as? String,
            let email = object["email"] as? String
        else {
            throw FirebaseSyncError.invalidResponse
        }
        return FirebaseGoogleSession(uid: uid, idToken: idToken, email: email)
    }

    private func googleIDToken() throws -> String {
        guard let token = KeychainStore.get(service: "pieroot.todo.gmail", account: "id_token"), !token.isEmpty else {
            throw FirebaseSyncError.missingGoogleIDToken
        }
        return token
    }

    private func firestoreDocumentURL(uid: String) -> URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/users/\(uid)/appData/snapshot")!
    }

    private func firestorePayload(email: String, envelope: FirebaseEncryptedEnvelope) -> [String: Any] {
        [
            "fields": [
                "version": ["integerValue": "1"],
                "provider": ["stringValue": "firebase-google"],
                "email": ["stringValue": email],
                "updatedAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
                "kdf": ["stringValue": envelope.kdf],
                "salt": ["stringValue": envelope.salt],
                "iterations": ["integerValue": "\(envelope.iterations)"],
                "iv": ["stringValue": envelope.iv],
                "ciphertext": ["stringValue": envelope.ciphertext]
            ]
        ]
    }

    private func envelope(from fields: [String: Any]) throws -> FirebaseEncryptedEnvelope {
        func stringField(_ name: String) -> String? {
            (fields[name] as? [String: Any])?["stringValue"] as? String
        }
        func intField(_ name: String) -> Int? {
            if let raw = (fields[name] as? [String: Any])?["integerValue"] as? String {
                return Int(raw)
            }
            return nil
        }
        guard
            let salt = stringField("salt"),
            let iv = stringField("iv"),
            let ciphertext = stringField("ciphertext"),
            let iterations = intField("iterations")
        else {
            throw FirebaseSyncError.invalidSnapshot
        }
        let kdf = stringField("kdf") ?? "PBKDF2WithHmacSHA256"
        return FirebaseEncryptedEnvelope(version: 1, kdf: kdf, salt: salt, iterations: iterations, iv: iv, ciphertext: ciphertext)
    }

    private func encrypt(snapshotJSON: String, passphrase: String) throws -> FirebaseEncryptedEnvelope {
        guard passphrase.count >= 8 else { throw FirebaseSyncError.invalidPassphrase }
        let salt = randomData(count: 16)
        let iv = randomData(count: 12)
        let key = try derivedKey(passphrase: passphrase, salt: salt, iterations: 210_000)
        let sealed = try AES.GCM.seal(Data(snapshotJSON.utf8), using: key, nonce: try AES.GCM.Nonce(data: iv))
        var ciphertextAndTag = sealed.ciphertext
        ciphertextAndTag.append(sealed.tag)
        return FirebaseEncryptedEnvelope(
            version: 1,
            kdf: "PBKDF2WithHmacSHA256",
            salt: salt.base64EncodedString(),
            iterations: 210_000,
            iv: iv.base64EncodedString(),
            ciphertext: ciphertextAndTag.base64EncodedString()
        )
    }

    private func decrypt(envelope: FirebaseEncryptedEnvelope, passphrase: String) throws -> String {
        guard passphrase.count >= 8 else { throw FirebaseSyncError.invalidPassphrase }
        guard
            let salt = Data(base64Encoded: envelope.salt),
            let iv = Data(base64Encoded: envelope.iv),
            let ciphertext = Data(base64Encoded: envelope.ciphertext)
        else {
            throw FirebaseSyncError.invalidSnapshot
        }
        let key = try derivedKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        guard ciphertext.count >= 16 else { throw FirebaseSyncError.invalidSnapshot }
        let tag = ciphertext.suffix(16)
        let encrypted = ciphertext.prefix(ciphertext.count - 16)
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: encrypted,
            tag: tag
        )
        let decrypted = try AES.GCM.open(sealed, using: key, authenticating: Data())
        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw FirebaseSyncError.invalidSnapshot
        }
        return text
    }

    private func derivedKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let derivedCount = derived.count
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase, passphrase.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress, derivedCount
                )
            }
        }
        guard status == kCCSuccess else { throw FirebaseSyncError.invalidResponse }
        return SymmetricKey(data: derived)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
