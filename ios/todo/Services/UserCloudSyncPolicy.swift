import Foundation

/// Full storage is explicit and account-bound. A cold launch must identify the
/// current Apple account before any new content or credential copy is published.
nonisolated enum UserCloudSyncPolicy {
    static let consentKey = "pieroot.todo.iCloudFullDataConsentVersion"
    static let consentVersion = 1
    static let syncKey = "pieroot.todo.iCloudSyncEnabled"
    static let accountKey = "pieroot.todo.cloudSync.consentedAccount"
    static let didRestoreNotification = Notification.Name("pieroot.todo.fullCloudDataRestored")
    private static let authorizationLock = NSLock()
    nonisolated(unsafe) private static var verifiedAccount: String?
    nonisolated(unsafe) private static var authorizationEpoch: UInt64 = 0
    private static let usesSyntheticAuthorization: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["SIFT_UI_TESTING"] == "1"
            || NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }()

    static var hasAcceptedFullScope: Bool {
        UserDefaults.standard.integer(forKey: consentKey) == consentVersion
    }

    static var isRequested: Bool {
        isRequested(defaults: .standard, supported: SettingsStore.supportsICloud)
    }

    static var isEnabled: Bool {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        return allowsAuthorizationLocked(forRevocation: false)
    }

    static func isRequested(defaults: UserDefaults, supported: Bool) -> Bool {
        supported && defaults.bool(forKey: syncKey)
            && defaults.integer(forKey: consentKey) == consentVersion
    }

    static func isAuthorized(defaults: UserDefaults, supported: Bool, verifiedAccount: String?) -> Bool {
        defaults.bool(forKey: syncKey) && isAccountAuthorized(defaults: defaults, supported: supported, verifiedAccount: verifiedAccount)
    }

    static func isAccountAuthorized(defaults: UserDefaults, supported: Bool, verifiedAccount: String?) -> Bool {
        guard supported, defaults.integer(forKey: consentKey) == consentVersion, let verifiedAccount else { return false }
        return defaults.string(forKey: accountKey) == verifiedAccount
    }

    /// Disconnect may revoke a shared copy only for the currently verified
    /// consent account. A consent-version flag alone cannot authorize writes
    /// after an Apple-account change or a cold launch with sync disabled.
    static var canRevokePortableCredentials: Bool {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        return allowsAuthorizationLocked(forRevocation: true)
    }

    /// An in-flight file or credential operation cannot acquire authorization
    /// later, or resume under a new authorization of the same Apple account.
    static func captureAuthorization(forRevocation: Bool = false) -> @Sendable () -> Bool {
        authorizationLock.lock()
        let epoch = authorizationEpoch
        let initiallyAuthorized = allowsAuthorizationLocked(forRevocation: forRevocation)
        authorizationLock.unlock()
        return {
            guard initiallyAuthorized else { return false }
            authorizationLock.lock()
            defer { authorizationLock.unlock() }
            return epoch == authorizationEpoch && allowsAuthorizationLocked(forRevocation: forRevocation)
        }
    }

    /// Caller holds authorizationLock, including while reading the consent binding.
    private static func allowsAuthorizationLocked(forRevocation: Bool) -> Bool {
        if usesSyntheticAuthorization {
            return forRevocation ? SettingsStore.supportsICloud && hasAcceptedFullScope : isRequested
        }
        if forRevocation {
            return isAccountAuthorized(defaults: .standard, supported: SettingsStore.supportsICloud,
                                       verifiedAccount: verifiedAccount)
        }
        return isAuthorized(defaults: .standard, supported: SettingsStore.supportsICloud,
                            verifiedAccount: verifiedAccount)
    }

    static func authorizeAccount(_ fingerprint: String) {
        authorizationLock.lock()
        verifiedAccount = fingerprint
        authorizationEpoch &+= 1
        authorizationLock.unlock()
    }

    static func revokeAccountAuthorization() {
        authorizationLock.lock()
        verifiedAccount = nil
        authorizationEpoch &+= 1
        authorizationLock.unlock()
    }

    static var needsScopeConsent: Bool {
        SettingsStore.supportsICloud && UserDefaults.standard.bool(forKey: syncKey) && !hasAcceptedFullScope
    }
}
