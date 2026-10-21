import Foundation
import AuthenticationServices
import UIKit
import CryptoKit
import Security

nonisolated struct OpenAIProfile: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let clientID: String
    let subject: String
    let email: String?
    let hasPlanPermission: Bool
}

nonisolated enum OpenAIConnectionError: Error, LocalizedError, Equatable {
    case cancelled, unavailable, invalidCallback, invalidIdentity, signInRequired
    case permissionRequired, storage, network, invalidClient, exchangeFailed, refreshOwnerRequired
    case synchronizationPending, synchronizationConflict
    var errorDescription: String? {
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        switch self {
        case .synchronizationPending:
            return AppLanguage.localized(
                "error.openai.connection.synchronizationPending",
                defaultValue: language == .english
                    ? "Connected on this device. iCloud connection sync is pending; the local login is retained."
                    : "이 기기에서는 연결되었습니다. iCloud 연결 동기화가 대기 중이며 로컬 로그인은 유지됩니다.",
                language: language, comment: "Local ChatGPT credentials are saved while their portable publication is pending."
            )
        case .synchronizationConflict:
            return AppLanguage.localized(
                "error.openai.connection.synchronizationConflict",
                defaultValue: language == .english
                    ? "Connected on this device, but the iCloud connection changed elsewhere. Both versions were preserved; automatic sync is paused. Check the other device before reconnecting."
                    : "이 기기에서는 연결되었지만 다른 기기에서 iCloud 연결이 변경되었습니다. 두 버전을 모두 유지하고 자동 동기화를 중지했습니다. 다시 연결하기 전에 다른 기기를 확인하세요.",
                language: language, comment: "Conflicting local and portable ChatGPT credentials are preserved, not merged or discarded."
            )
        case .cancelled:
            return AppLanguage.localized(
                "error.openai.connection.cancelled",
                defaultValue: language == .english ? "ChatGPT sign-in was cancelled." : "ChatGPT 로그인이 취소되었습니다.",
                language: language,
                comment: "ChatGPT connection error when sign-in is cancelled."
            )
        case .unavailable:
            return AppLanguage.localized(
                "error.openai.connection.unavailable",
                defaultValue: language == .english ? "Unable to open ChatGPT sign-in on this device." : "이 기기에서 ChatGPT 로그인을 열 수 없습니다.",
                language: language,
                comment: "ChatGPT connection error when sign-in cannot be opened."
            )
        case .invalidCallback:
            return AppLanguage.localized(
                "error.openai.connection.invalidCallback",
                defaultValue: language == .english ? "ChatGPT sign-in could not be verified. Please try again." : "ChatGPT 로그인을 확인할 수 없습니다. 다시 시도해 주세요.",
                language: language,
                comment: "ChatGPT connection error when the sign-in callback cannot be verified."
            )
        case .invalidIdentity:
            return AppLanguage.localized(
                "error.openai.connection.invalidIdentity",
                defaultValue: language == .english ? "The ChatGPT identity could not be verified. Please sign in again." : "ChatGPT 계정의 신원을 확인할 수 없습니다. 다시 로그인해 주세요.",
                language: language,
                comment: "ChatGPT connection error when account identity cannot be verified."
            )
        case .signInRequired:
            return AppLanguage.localized(
                "error.openai.connection.signInRequired",
                defaultValue: language == .english ? "Please sign in to ChatGPT again." : "ChatGPT에 다시 로그인해 주세요.",
                language: language,
                comment: "ChatGPT connection error requiring a new sign-in."
            )
        case .refreshOwnerRequired:
            return AppLanguage.localized(
                "error.openai.connection.refreshOwnerRequired",
                defaultValue: language == .english
                    ? "This connection is refreshed by the device that connected it. On that device, open SIFT → Settings → AI → OpenAI · ChatGPT and refresh the model list, then wait for iCloud Keychain. Or reconnect on this device."
                    : "이 연결의 갱신은 원래 연결한 기기에서 처리합니다. 해당 기기의 SIFT → 설정 → AI → OpenAI · ChatGPT에서 모델 목록을 새로고침한 뒤 iCloud 키체인 동기화를 기다리거나, 이 기기에서 다시 연결하세요.",
                language: language,
                comment: "Shared rotating credentials have one installation owner; another installation must wait or explicitly reauthorize."
            )
        case .permissionRequired:
            return AppLanguage.localized(
                "error.openai.connection.permissionRequired",
                defaultValue: language == .english ? "Allow this app to use your ChatGPT plan before continuing." : "계속하려면 이 앱이 ChatGPT 요금제를 사용하도록 허용해 주세요.",
                language: language,
                comment: "ChatGPT connection error requiring permission to use the account's plan."
            )
        case .storage:
            return AppLanguage.localized(
                "error.openai.connection.storage",
                defaultValue: language == .english ? "Unable to save ChatGPT credentials securely on this device." : "이 기기에 ChatGPT 인증 정보를 안전하게 저장할 수 없습니다.",
                language: language,
                comment: "Generic ChatGPT secure credential storage error; never include underlying diagnostics."
            )
        case .network:
            return AppLanguage.localized(
                "error.openai.connection.network",
                defaultValue: language == .english ? "Unable to reach ChatGPT. Please try again." : "ChatGPT에 연결할 수 없습니다. 다시 시도해 주세요.",
                language: language,
                comment: "Generic ChatGPT connection error; never include tokens or response bodies."
            )
        case .invalidClient:
            return AppLanguage.localized(
                "error.openai.connection.invalidClient",
                defaultValue: language == .english ? "This ChatGPT registration is not accepted. Reconnect the app in ChatGPT settings." : "이 ChatGPT 앱 등록을 사용할 수 없습니다. ChatGPT 설정에서 앱을 다시 연결해 주세요.",
                language: language,
                comment: "ChatGPT connection error when the app registration must be reconnected."
            )
        case .exchangeFailed:
            return AppLanguage.localized(
                "error.openai.connection.exchangeFailed",
                defaultValue: language == .english ? "ChatGPT sign-in was not completed. Please try again." : "ChatGPT 로그인이 완료되지 않았습니다. 다시 시도해 주세요.",
                language: language,
                comment: "Generic ChatGPT sign-in exchange error; never include server response details."
            )
        }
    }
}

/// Only protected Keychain records carry credentials. Tombstones contain client IDs, never tokens.
@MainActor protocol OpenAICredentialStore {
    var synchronizationEnabled: Bool { get }
    var synchronizationIssue: OpenAIConnectionError? { get }
    func load() throws -> Data?
    func save(_ data: Data) throws
    func deleteAll() throws
    func blockedClientIDs() -> Set<String>
    func block(_ clientID: String)
    func unblock(_ clientID: String) throws
    func quarantinedCredentialIDs() -> [String: Set<String>]
    func quarantine(clientID: String, credentialID: String)
}

extension OpenAICredentialStore {
    var synchronizationIssue: OpenAIConnectionError? { nil }
}

@MainActor final class OpenAIKeychainCredentialStore: OpenAICredentialStore {
    private let deviceService: String
    private let portableService: String
    private let defaults: UserDefaults
    private let blockedKey = "pieroot.todo.openai.signedOutClientIDs"
    private let deletedKey = "pieroot.todo.openai.credentialsDeleted"
    private let quarantineKey = "pieroot.todo.openai.rejectedCredentialIDs"
    var synchronizationEnabled: Bool { SettingsStore.isICloudSyncEnabled }
    private(set) var synchronizationIssue: OpenAIConnectionError?
    private var publicationKey: String { "pieroot.todo.openai.device.publication.\(deviceService)" }
    private struct PublicationState: Codable {
        var baseDigest: Data?
        var baseKnown: Bool
        var localDigest: Data
        var pending: Bool
        var conflicted: Bool
    }

    #if DEBUG
    var afterPortableReadForTesting: (() -> Void)?
    #endif

    init(deviceService: String = "pieroot.todo.openai.device",
         portableService: String = "pieroot.todo.openai.credentials",
         defaults: UserDefaults = .standard) {
        self.deviceService = deviceService
        self.portableService = portableService
        self.defaults = defaults
    }

    private func capturePortableAuthorization() -> @Sendable () -> Bool {
        let lease = UserCloudSyncPolicy.captureAuthorization()
        let initiallyAllowed = lease()
        return { initiallyAllowed && lease() }
    }

    private func publicationState() throws -> PublicationState? {
        try defaults.data(forKey: publicationKey).map { try JSONDecoder().decode(PublicationState.self, from: $0) }
    }

    private func savePublicationState(_ state: PublicationState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: publicationKey)
    }

    /// Canonicalize set/order differences before hashing; never persist credential bytes in defaults.
    private func portableDigest(_ snapshot: OpenAIConnection.PortableSnapshot) throws -> Data {
        let encoded = try JSONEncoder().encode(snapshot)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var registrations = object["registrations"] as? [[String: Any]] else {
            throw OpenAIConnectionError.storage
        }
        for index in registrations.indices {
            if var tokens = registrations[index]["tokens"] as? [String: Any],
               let scopes = tokens["scopes"] as? [String] {
                tokens["scopes"] = scopes.sorted()
                registrations[index]["tokens"] = tokens
            }
        }
        registrations.sort { ($0["clientID"] as? String ?? "") < ($1["clientID"] as? String ?? "") }
        object["registrations"] = registrations
        return Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)))
    }

    private func preparePublication(_ snapshot: OpenAIConnection.Snapshot,
                                    authorization: @Sendable () -> Bool) throws -> PublicationState {
        let localDigest = try portableDigest(OpenAIConnection.PortableSnapshot(snapshot))
        if var state = try publicationState() {
            // A second local commit retains the FIRST unresolved portable base.
            state.localDigest = localDigest
            state.pending = true
            return state
        }
        var state = PublicationState(baseDigest: nil, baseKnown: false, localDigest: localDigest,
                                     pending: true, conflicted: false)
        if authorization() {
            let data = try readPortable(authorization: authorization)
            if authorization() {
                state.baseKnown = true
                if let data {
                    state.baseDigest = try portableDigest(JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self, from: data))
                }
            }
        }
        return state
    }

    private func noteReceipt(_ snapshot: OpenAIConnection.Snapshot, portable: OpenAIConnection.PortableSnapshot,
                             authorization: @Sendable () -> Bool) throws {
        let state = PublicationState(baseDigest: try portableDigest(portable), baseKnown: true,
                                     localDigest: try portableDigest(OpenAIConnection.PortableSnapshot(snapshot)),
                                     pending: false, conflicted: false)
        guard authorization() else { return }
        try savePublicationState(state)
        synchronizationIssue = nil
    }

    /// A pending device choice must not freeze a receiver on an older access token.
    /// Reconstruct the prior portable base by undoing only verified same-grant
    /// rotations; advance its receipt only when the complete base digest matches.
    private func mergingPendingRotations(_ snapshot: OpenAIConnection.Snapshot,
                                         state: PublicationState,
                                         remote: OpenAIConnection.PortableSnapshot) throws
        -> (snapshot: OpenAIConnection.Snapshot, state: PublicationState)? {
        var merged = snapshot
        var priorBase = remote
        let blocked = blockedClientIDs()
        let quarantined = quarantinedCredentialIDs()
        var changed = false
        for index in snapshot.registrations.indices {
            let current = snapshot.registrations[index]
            guard !blocked.contains(current.clientID), current.subject != nil,
                  let tokens = current.tokens,
                  let remoteIndex = remote.registrations.firstIndex(where: { $0.clientID == current.clientID }),
                  remote.registrations[remoteIndex].subject == current.subject,
                  let incoming = remote.registrations[remoteIndex].tokens,
                  incoming.refreshOwnerID == tokens.refreshOwnerID,
                  incoming.isNewerRotation(than: tokens),
                  quarantined[current.clientID]?.contains(incoming.quarantineID) != true else { continue }
            priorBase.registrations[remoteIndex] = current
            merged.registrations[index] = remote.registrations[remoteIndex]
            changed = true
        }
        guard changed else { return nil }
        var next = state
        let mergedDigest = try portableDigest(OpenAIConnection.PortableSnapshot(merged))
        let remoteDigest = try portableDigest(remote)
        if state.baseKnown,
           try portableDigest(priorBase) == state.baseDigest
            || (remoteDigest == state.baseDigest && mergedDigest == state.localDigest) {
            next.baseDigest = remoteDigest
            next.conflicted = false
        }
        next.localDigest = mergedDigest
        return (merged, next)
    }

    private func attemptPublication(_ snapshot: OpenAIConnection.Snapshot, state: PublicationState,
                                    authorizing clientID: String? = nil,
                                    authorization: @Sendable () -> Bool) throws {
        synchronizationIssue = state.conflicted ? .synchronizationConflict : .synchronizationPending
        guard authorization() else { return }
        do {
            try savePortable(snapshot, authorizing: clientID, state: state, authorization: authorization)
        } catch {
            var pending = state
            pending.conflicted = (error as? OpenAIConnectionError) == .synchronizationConflict
            try savePublicationState(pending)
            synchronizationIssue = pending.conflicted ? .synchronizationConflict : .synchronizationPending
        }
    }

    func load() throws -> Data? {
        let authorization = capturePortableAuthorization()
        // ThisDeviceOnly v1 is also the migration source. Never promote this record:
        // it owns the host identity, independently of the portable registration.
        let local = try KeychainStore.getDeviceOnly(service: deviceService, account: "connections.v1")
        let state = try publicationState()
        synchronizationIssue = state?.pending == true
            ? (state?.conflicted == true ? .synchronizationConflict : .synchronizationPending) : nil
        // Opt-out pauses copying. It neither deletes another device's login nor
        // imports cloud bytes into the now-local installation.
        guard authorization() else { return local }
        guard !defaults.bool(forKey: deletedKey) else { return local }
        var snapshot = try local.map { try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: $0) }
            ?? OpenAIConnection.Snapshot()
        let previous = snapshot
        if let state, state.pending, local != nil {
            var pending = state
            var result = local
            let portableData = try readPortable(authorization: authorization)
            guard authorization() else { return local }
            if let portableData {
                let remote = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self, from: portableData)
                if let updated = try mergingPendingRotations(snapshot, state: pending, remote: remote) {
                    guard authorization() else { return local }
                    // Write ahead so a skipped/failed local commit can replay the
                    // same rotation without losing the outstanding device choice.
                    try savePublicationState(updated.state)
                    do { try saveDevice(updated.snapshot, authorization: authorization) }
                    catch { try savePublicationState(state); throw error }
                    guard authorization() else { return local }
                    snapshot = updated.snapshot
                    pending = updated.state
                    result = try JSONEncoder().encode(snapshot)
                }
            }
            guard try portableDigest(OpenAIConnection.PortableSnapshot(snapshot)) == pending.localDigest else {
                synchronizationIssue = .synchronizationConflict
                return result
            }
            // Different authorizations remain protected by the pending base.
            try attemptPublication(snapshot, state: pending, authorization: authorization)
            return result
        }
        let portableData = try readPortable(authorization: authorization)
        guard authorization() else { return local }
        if let value = portableData {
            let remote = try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self, from: value)
            // Persist the receiving host before adopting any imported credentials.
            guard authorization() else { return local }
            if local == nil { try saveDevice(snapshot, authorization: authorization) }
            let blocked = blockedClientIDs()
            var repairOwnedRotation = false
            for var registration in remote.registrations {
                if blocked.contains(registration.clientID) { registration.tokens = nil }
                if var tokens = registration.tokens, tokens.refreshOwnerID == nil {
                    // Unknown imported ownership must never be claimed by the receiving host.
                    tokens.refreshOwnerID = "unassigned"
                    registration.tokens = tokens
                }
                if let index = snapshot.registrations.firstIndex(where: { $0.clientID == registration.clientID }) {
                    // A registration is bound to its validated subject; never merge by email.
                    guard snapshot.registrations[index].subject == nil
                            || registration.subject == snapshot.registrations[index].subject else {
                        throw OpenAIConnectionError.invalidIdentity
                    }
                    if let current = snapshot.registrations[index].tokens, let incoming = registration.tokens,
                       current.isNewerRotation(than: incoming) {
                        repairOwnedRotation = repairOwnedRotation
                            || current.refreshOwnerID == OpenAIOAuth.refreshOwnerID(for: snapshot.hostID)
                        continue
                    }
                    snapshot.registrations[index] = registration
                } else {
                    snapshot.registrations.append(registration)
                }
            }
            // Device-local selection wins, unless this installation has no active account yet.
            if snapshot.selectedID == nil { snapshot.selectedID = remote.selectedID }
            if snapshot.activeID == nil, let active = remote.activeID, !blocked.contains(active) {
                snapshot.activeID = active
            }
            if snapshot.incompleteID == nil { snapshot.incompleteID = remote.incompleteID }
            guard authorization() else { return local }
            if repairOwnedRotation {
                let repair = PublicationState(baseDigest: try portableDigest(remote), baseKnown: true,
                                              localDigest: try portableDigest(OpenAIConnection.PortableSnapshot(snapshot)),
                                              pending: true, conflicted: false)
                try savePublicationState(repair)
                try attemptPublication(snapshot, state: repair, authorization: authorization)
            }
            if snapshot == previous, let local {
                if !repairOwnedRotation { try noteReceipt(snapshot, portable: remote, authorization: authorization) }
                return local
            }
            let data = try JSONEncoder().encode(snapshot)
            guard authorization() else { return local }
            if snapshot != previous || local == nil { try saveDevice(snapshot, authorization: authorization) }
            guard authorization() else { return local }
            if !repairOwnedRotation { try noteReceipt(snapshot, portable: remote, authorization: authorization) }
            return data
        }
        // Existing device-only login becomes portable only after the checked opt-in write.
        if local != nil {
            let state = try preparePublication(snapshot, authorization: authorization)
            try savePublicationState(state)
            try attemptPublication(snapshot, state: state, authorization: authorization)
        }
        return local
    }

    func save(_ data: Data) throws {
        let authorization = capturePortableAuthorization()
        let snapshot = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: data)
        let previousState = defaults.data(forKey: publicationKey)
        let state = try preparePublication(snapshot, authorization: authorization)
        // Journal before committing the canonical login so restart cannot import an older grant.
        try savePublicationState(state)
        do { try saveDevice(snapshot) }
        catch {
            if let previousState { defaults.set(previousState, forKey: publicationKey) }
            else { defaults.removeObject(forKey: publicationKey) }
            throw error
        }
        synchronizationIssue = state.conflicted ? .synchronizationConflict : .synchronizationPending
        if !defaults.bool(forKey: deletedKey) {
            try attemptPublication(snapshot, state: state, authorization: authorization)
        }
    }

    private func saveDevice(_ snapshot: OpenAIConnection.Snapshot,
                            authorization: @Sendable () -> Bool = { true }) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard authorization() else { return }
        try KeychainStore.setDeviceOnly(service: deviceService, account: "connections.v1", data: data,
                                       access: .backgroundAfterFirstUnlock)
    }

    private func savePortable(_ snapshot: OpenAIConnection.Snapshot, authorizing clientID: String? = nil,
                              state: PublicationState, authorization: @Sendable () -> Bool) throws {
        guard authorization() else { return }
        var portable = OpenAIConnection.PortableSnapshot(snapshot)
        let blocked = blockedClientIDs()
        let quarantined = quarantinedCredentialIDs()
        let portableData = try readPortable(authorization: authorization)
        guard authorization() else { return }
        let remote = try portableData.map { try JSONDecoder().decode(OpenAIConnection.PortableSnapshot.self, from: $0) }
        let remoteDigest = try remote.map { try portableDigest($0) }
        guard try portableDigest(portable) == state.localDigest else {
            throw OpenAIConnectionError.synchronizationConflict
        }
        guard remoteDigest == state.localDigest
                || (state.baseKnown && remoteDigest == state.baseDigest)
                || (!state.baseKnown && remote == nil) else {
            throw OpenAIConnectionError.synchronizationConflict
        }
        if let remote {
            // A save based on an older local account list must not remove an
            // unrelated account added by another installation in the meantime.
            var known = Set(portable.registrations.map(\.clientID))
            for registration in remote.registrations where known.insert(registration.clientID).inserted {
                portable.registrations.append(registration)
            }
            for index in portable.registrations.indices {
                let registration = portable.registrations[index]
                guard !blocked.contains(registration.clientID),
                      let incoming = remote.registrations.first(where: { $0.clientID == registration.clientID }),
                      incoming.subject == registration.subject else { continue }
                // Account selection or an unrelated save cannot publish a local quarantine as shared deletion.
                if registration.tokens == nil, quarantined[registration.clientID] != nil, registration.clientID != clientID {
                    portable.registrations[index] = incoming
                    if portable.activeID == nil, remote.activeID == registration.clientID { portable.activeID = remote.activeID }
                } else if let current = registration.tokens, let replacement = incoming.tokens,
                          replacement.isNewerRotation(than: current) {
                    portable.registrations[index] = incoming
                }
            }
        }
        for index in portable.registrations.indices
            where blocked.contains(portable.registrations[index].clientID) && portable.registrations[index].clientID != clientID {
            portable.registrations[index].tokens = nil
        }
        if let active = portable.activeID, blocked.contains(active), active != clientID { portable.activeID = nil }
        let data = try JSONEncoder().encode(portable)
        guard authorization() else { return }
        try KeychainStore.setSynchronizable(service: portableService, account: "connections.v1", data: data)
        // A successful local Security write is not a cross-device compare-and-swap.
        // Leave the intent dirty if authorization expired during the write.
        try noteReceipt(snapshot, portable: portable, authorization: authorization)
    }

    private func readPortable(authorization: @Sendable () -> Bool) throws -> Data? {
        guard authorization() else { return nil }
        let data = try KeychainStore.getSynchronizable(service: portableService, account: "connections.v1")
        #if DEBUG
        afterPortableReadForTesting?()
        #endif
        guard authorization() else { return nil }
        return data
    }

    func deleteAll() throws {
        let authorization = capturePortableAuthorization()
        // Keep this local tombstone even after secure erasure succeeds: delayed delivery
        // must not undo app-data deletion. Only explicit successful OAuth reopens import.
        defaults.set(true, forKey: deletedKey)
        defaults.removeObject(forKey: publicationKey)
        synchronizationIssue = nil
        try KeychainStore.deleteDeviceOnly(service: deviceService, account: "connections.v1")
        if authorization() {
            try KeychainStore.deleteSynchronizable(service: portableService, account: "connections.v1")
        }
    }

    func blockedClientIDs() -> Set<String> { Set(defaults.stringArray(forKey: blockedKey) ?? []) }
    func block(_ clientID: String) {
        var ids = blockedClientIDs(); ids.insert(clientID)
        defaults.set(Array(ids), forKey: blockedKey)
    }
    func quarantinedCredentialIDs() -> [String: Set<String>] {
        (defaults.dictionary(forKey: quarantineKey) as? [String: [String]] ?? [:]).mapValues { Set($0) }
    }
    func quarantine(clientID: String, credentialID: String) {
        var rejected = quarantinedCredentialIDs()
        rejected[clientID, default: []].insert(credentialID)
        defaults.set(rejected.mapValues { Array($0) }, forKey: quarantineKey)
    }
    func unblock(_ clientID: String) throws {
        let authorization = capturePortableAuthorization()
        // Explicit verified sign-in is the sole path that can clear local tombstones.
        // This is the tail of the SAME OAuth commit. Do not reacquire permission
        // to retry a save whose publication expired; a later load owns that retry.
        let deferred = try publicationState()?.pending == true
        if !deferred, let data = try KeychainStore.getDeviceOnly(service: deviceService, account: "connections.v1") {
            let snapshot = try JSONDecoder().decode(OpenAIConnection.Snapshot.self, from: data)
            let state = try preparePublication(snapshot, authorization: authorization)
            try savePublicationState(state)
            try attemptPublication(snapshot, state: state, authorizing: clientID, authorization: authorization)
        }
        var ids = blockedClientIDs(); ids.remove(clientID)
        defaults.set(Array(ids), forKey: blockedKey)
        defaults.removeObject(forKey: deletedKey)
        var rejected = quarantinedCredentialIDs(); rejected.removeValue(forKey: clientID)
        defaults.set(rejected.mapValues { Array($0) }, forKey: quarantineKey)
    }
}

@MainActor protocol OpenAIAuthTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

@MainActor final class OpenAIURLSessionTransport: NSObject, OpenAIAuthTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw OpenAIConnectionError.network
        }
        return (data, response.statusCode)
    }
    // Never forward a code, refresh token, or ID-token hint across a server redirect.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor protocol OpenAILoopbackListening: AnyObject {
    func start() async throws -> URL
    func callback() async throws -> URL
    func stop()
}

@MainActor protocol OpenAIAuthenticationBrowser: AnyObject {
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool
    func cancel()
}

@MainActor final class OpenAISystemAuthenticationBrowser: NSObject, OpenAIAuthenticationBrowser,
                                                            ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: UIWindow?
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }), let window = scene.keyWindow else { return false }
        anchor = window
        // Apple's native callback matcher supports custom schemes and HTTPS, not SIWC's HTTP loopback.
        // The local listener completes the attempt; no unsupported "http" callback interception is used.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
            Task { @MainActor in onCancel() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        return session.start()
    }
    // Keep the real anchor until this per-attempt browser is released: UIKit may still be dismissing it.
    func cancel() { session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // start() requires a real foreground window before the authentication session exists.
        anchor!
    }
}

nonisolated enum OpenAIOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func refreshOwnerID(for hostID: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(hostID.utf8))))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenAIConnectionError.unavailable
        }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func issuedClient(_ value: String) -> Bool {
        value.hasPrefix("oaiapp_") && value.count > 7 && value.count < 256
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func callbackValues(_ url: URL, redirect: URL, state: String, clientID: String?) throws -> (code: String, clientID: String) {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == "http", actual.host == "127.0.0.1", actual.port == redirect.port,
              actual.path == "/auth/callback", actual.user == nil, actual.password == nil, actual.fragment == nil else {
            throw OpenAIConnectionError.invalidCallback
        }
        var values = [String: String]()
        for item in actual.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw OpenAIConnectionError.invalidCallback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw OpenAIConnectionError.invalidCallback }
        if let error = values["error"] {
            throw error == "access_denied" ? OpenAIConnectionError.permissionRequired : .exchangeFailed
        }
        guard let code = values["code"], !code.isEmpty, code.count < 16384,
              let issued = values["client_id"] ?? clientID, issuedClient(issued),
              clientID == nil || issued == clientID else { throw OpenAIConnectionError.invalidCallback }
        return (code, issued)
    }
}
