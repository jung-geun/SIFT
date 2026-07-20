import CryptoKit
import Foundation

/// Derives an opaque per-provider, per-account namespace without persisting raw account IDs.
actor MailAccountNamespaceStore {
    private let keyStore: VocabularyHMACKeyStore

    init(keyStore: VocabularyHMACKeyStore) {
        self.keyStore = keyStore
    }

    func namespace(provider: MailProvider, rawAccountID: String) async throws -> String? {
        guard !rawAccountID.isEmpty else { return nil }
        let key = try await keyStore.readOrCreate()
        let verifier = HMAC<SHA256>.authenticationCode(for: Data("SIFT User Vocabulary v1".utf8), using: SymmetricKey(data: key))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let payload = Data("\(provider.rawValue)\u{0}\(rawAccountID)".utf8)
        let account = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1:\(verifier):\(account)"
    }
}
