import Foundation

/// Presentation access is independent of UMP consent. Production currently has no ad-removal
/// entitlement; a future verified purchase can supply this policy without changing consent.
/// Never derive purchase access from a writable preference or a launch argument in production.
nonisolated enum AdPresentationPolicy: Equatable {
    case adSupported
    case adFree

    static let current: Self = {
        #if DEBUG || SIFT_QA
        return resolve(hasVerifiedAdRemoval: false, arguments: ProcessInfo.processInfo.arguments)
        #else
        return resolve(hasVerifiedAdRemoval: false, arguments: [])
        #endif
    }()

    var allowsAds: Bool { self == .adSupported }

    /// The entitlement input must come from a verified purchase, never persisted UI state.
    /// No purchase provider is connected today: `current` always supplies false.
    static func resolve(hasVerifiedAdRemoval: Bool, arguments: [String]) -> Self {
        if hasVerifiedAdRemoval { return .adFree }
        #if DEBUG || SIFT_QA
        if arguments.contains("-sift-test-ad-free") { return .adFree }
        #endif
        return .adSupported
    }
}
