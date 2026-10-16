import Foundation
import Security

nonisolated struct OpenAIValidatedIdentity: Sendable {
    let subject: String
    let email: String?
}

/// Only OpenAI's discovered JWKS is accepted; token-provided key URLs and algorithms are never trusted.
nonisolated enum OpenAIJWTValidator {
    private struct Header: Decodable {
        let alg: String
        let kid: String
        let crit: [String]?
    }
    private struct Audience: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { values = [value] }
            else { values = try container.decode([String].self) }
        }
    }
    private struct Claims: Decodable {
        let iss: String
        let aud: Audience
        let sub: String
        let exp: Double
        let nonce: String?
        let email: String?
        let azp: String?
        let nbf: Double?
        let iat: Double?
    }
    private struct KeySet: Decodable { let keys: [Key] }
    private struct Key: Decodable {
        let kty: String
        let kid: String
        let alg: String?
        let use: String?
        let key_ops: [String]?
        let n: String?
        let e: String?
    }

    static func validate(_ token: String, jwks: Data, clientID: String, nonce: String,
                         now: Date, requireNonce: Bool = true) throws -> OpenAIValidatedIdentity {
        do {
            guard token.utf8.count <= 65536 else { throw OpenAIConnectionError.invalidIdentity }
            let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count == 3, let headerData = OpenAIOAuth.decode(pieces[0]),
                  let claimsData = OpenAIOAuth.decode(pieces[1]), let signature = OpenAIOAuth.decode(pieces[2]) else {
                throw OpenAIConnectionError.invalidIdentity
            }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: headerData)
            guard header.alg == "RS256", header.crit == nil || header.crit!.isEmpty else {
                throw OpenAIConnectionError.invalidIdentity
            }
            let keys = try decoder.decode(KeySet.self, from: jwks).keys.filter { $0.kid == header.kid }
            guard keys.count == 1, let key = keys.first, key.kty == "RSA",
                  key.alg == nil || key.alg == "RS256", key.use == nil || key.use == "sig",
                  key.key_ops == nil || key.key_ops!.contains("verify"),
                  let n = key.n.flatMap(OpenAIOAuth.decode), let e = key.e.flatMap(OpenAIOAuth.decode),
                  n.count >= 256, n.count <= 1024, !e.isEmpty, e.count <= 8 else {
                throw OpenAIConnectionError.invalidIdentity
            }
            let der = element(0x30, integer(n) + integer(e))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                               kSecAttrKeyClass: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
                  SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                        Data("\(pieces[0]).\(pieces[1])".utf8) as CFData,
                                        signature as CFData, nil) else { throw OpenAIConnectionError.invalidIdentity }
            let claims = try decoder.decode(Claims.self, from: claimsData)
            let time = now.timeIntervalSince1970
            guard claims.iss == OpenAIOAuth.issuer, claims.aud.values.contains(clientID),
                  !claims.sub.isEmpty, claims.exp.isFinite, claims.exp > time,
                  claims.nbf.map({ $0.isFinite && $0 <= time + 30 }) ?? true,
                  claims.iat.map({ $0.isFinite && $0 <= time + 30 }) ?? true,
                  claims.aud.values.count == 1 || claims.azp == clientID,
                  claims.azp == nil || claims.azp == clientID,
                  (!requireNonce && claims.nonce == nil) || claims.nonce == nonce else {
                throw OpenAIConnectionError.invalidIdentity
            }
            return OpenAIValidatedIdentity(subject: claims.sub, email: claims.email)
        } catch { throw OpenAIConnectionError.invalidIdentity }
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(0x02, bytes)
    }
    private static func element(_ tag: UInt8, _ bytes: Data) -> Data {
        var result = Data([tag])
        if bytes.count < 128 { result.append(UInt8(bytes.count)) }
        else {
            var count = bytes.count
            var length = [UInt8]()
            while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
            result.append(0x80 | UInt8(length.count)); result.append(contentsOf: length)
        }
        result.append(bytes)
        return result
    }
}
