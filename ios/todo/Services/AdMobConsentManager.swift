#if !targetEnvironment(macCatalyst)
import Combine
import UIKit
import GoogleMobileAds
import UserMessagingPlatform
import OSLog

/// Process-wide UMP/GMA owner. Mount `BannerAdStrip(isEligible:)` below the task filters;
/// it supplies a live, scene-specific presenter and starts consent when eligible and active.
/// Put `AdMobPrivacyOptionsRow()` in Settings, independently of ad eligibility.
///
@MainActor
final class AdMobConsentManager: ObservableObject {
    static let shared = AdMobConsentManager()

    #if DEBUG || SIFT_QA
    static let logger = Logger(subsystem: "pieroot.todo", category: "AdMob")
    #endif

    struct State: Equatable {
        var canRequestAds = false
        var isPrivacyOptionsRequired = false
        var isBusy = false
        var isSDKReady = false
        /// Every explicit privacy edit invalidates even an otherwise still-permitted ad.
        var revision: UInt64 = 0
    }

    @Published private(set) var state = State()

    var canRequestAds: Bool {
        state.canRequestAds && ConsentInformation.shared.canRequestAds
    }

    var isPrivacyOptionsRequired: Bool { state.isPrivacyOptionsRequired }
    var isBusy: Bool { state.isBusy }

    enum PrivacyOptionsError: LocalizedError {
        case unavailable

        var errorDescription: String? { AdMobCopy.errorMessage }
    }

    private enum InformationPhase {
        case notStarted, updating, finished
    }

    private enum StartupPhase {
        case notStarted, updating, needsForm, presentingForm, finished
    }

    private enum SDKPhase {
        case notStarted, starting, ready
    }

    private var informationPhase = InformationPhase.notStarted
    private var informationUpdateFailed = false
    private var startupPhase = StartupPhase.notStarted
    private var sdkPhase = SDKPhase.notStarted
    private var isEditingPrivacy = false
    private var revision: UInt64 = 0

    private init() {}

    /// Idempotent. The banner calls this only from an eligible foreground scene.
    /// A backgrounded consent update waits for a usable presenter instead of presenting
    /// into an inactive scene. There is one info update and at most one startup form per process.
    func prepare(from presenter: UIViewController) {
        guard AdPresentationPolicy.current.allowsAds else { return }
        if startupPhase == .finished {
            startSDKIfPermitted()
            return
        }
        guard AdMobPresentation.isReady(presenter) else { return }

        switch startupPhase {
        case .notStarted:
            if informationPhase == .finished {
                startupPhase = informationUpdateFailed ? .finished : .needsForm
                publishState()
            } else {
                startupPhase = .updating
                updateInformationIfNeeded()
            }
        case .needsForm:
            startupPhase = .presentingForm
            publishState()
            ConsentForm.loadAndPresentIfRequired(from: presenter) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Startup UMP failures are deliberately non-intrusive. UMP itself decides
                    // whether previously collected consent still permits ad requests.
                    #if DEBUG || SIFT_QA
                    Self.logger.debug("Startup consent form flow completed.")
                    #endif
                    self.startupPhase = .finished
                    self.publishState()
                }
            }
        case .finished:
            startSDKIfPermitted()
        case .updating, .presentingForm:
            break
        }
    }

    /// Explicit Settings entry, independent of placement access. UMP reports .unknown on a
    /// fresh launch until this session requests an update; a cached getter is not sufficient.
    /// This refresh alone never presents a startup form or initializes Google Mobile Ads.
    func refreshPrivacyOptionsRequirement() {
        updateInformationIfNeeded()
    }

    /// One session-wide information request shared by Settings and placement startup.
    private func updateInformationIfNeeded() {
        guard informationPhase == .notStarted else { return }
        informationPhase = .updating
        publishState()
        ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) {
            [weak self] error in
            // Do not move an SDK NSError across isolation boundaries or expose it to users.
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG || SIFT_QA
                if failed {
                    Self.logger.debug("Consent information update failed.")
                } else {
                    Self.logger.debug("Consent information update completed.")
                }
                #endif
                self.informationPhase = .finished
                self.informationUpdateFailed = failed
                if self.startupPhase == .updating {
                    self.startupPhase = failed ? .finished : .needsForm
                }
                self.publishState()
            }
        }
    }

    /// Call only for an explicit privacy-options button action. UMP does not provide a
    /// cancellation API: cancellation suppresses the caller's alert, but the gate stays closed
    /// until UMP dismisses/completes. Never overlap a startup form or another privacy form.
    /// Returns false when Google reports that no consent or privacy form is needed.
    func presentPrivacyOptions(from presenter: UIViewController) async throws -> Bool {
        try Task.checkCancellation()
        guard !isBusy, AdMobPresentation.isReady(presenter) else {
            throw PrivacyOptionsError.unavailable
        }

        isEditingPrivacy = true
        revision &+= 1
        // Subscribers synchronously remove/invalidate the ad BEFORE UMP can edit choices.
        publishState()
        defer {
            isEditingPrivacy = false
            startupPhase = .finished
            // UMP updates canRequestAds and privacyOptionsRequirementStatus before completion.
            publishState()
        }

        do {
            // Explicit user action may retry a previous failed configuration/network update.
            // Keep the privacy gate closed for the entire update + presentation operation.
            let failed: Bool = await withCheckedContinuation { continuation in
                ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { error in
                    continuation.resume(returning: error != nil)
                }
            }
            informationPhase = .finished
            informationUpdateFailed = failed
            try Task.checkCancellation()
            guard !failed, AdMobPresentation.isReady(presenter) else {
                throw PrivacyOptionsError.unavailable
            }
            if ConsentInformation.shared.consentStatus == .required {
                try await ConsentForm.loadAndPresentIfRequired(from: presenter)
            } else if ConsentInformation.shared.privacyOptionsRequirementStatus == .required {
                try await ConsentForm.presentPrivacyOptionsForm(from: presenter)
            } else {
                return false
            }
            try Task.checkCancellation()
            return true
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PrivacyOptionsError.unavailable
        }
    }

    private func startSDKIfPermitted() {
        guard AdPresentationPolicy.current.allowsAds,
              sdkPhase == .notStarted, canRequestAds,
              UIApplication.shared.applicationState == .active else { return }
        // Set before invoking the SDK, including when completion is synchronous.
        sdkPhase = .starting
        MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState = .disabled
        // This unobtrusive placement must not interrupt meeting/audio capture.
        MobileAds.shared.isApplicationMuted = true
        MobileAds.shared.start { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sdkPhase = .ready
                #if DEBUG || SIFT_QA
                Self.logger.debug("Mobile Ads SDK initialization completed.")
                #endif
                self.publishState()
            }
        }
    }

    private func publishState() {
        let busy = isEditingPrivacy || informationPhase == .updating
            || (startupPhase != .notStarted && startupPhase != .finished)
        let next = State(
            canRequestAds: startupPhase == .finished && !isEditingPrivacy
                && ConsentInformation.shared.canRequestAds,
            isPrivacyOptionsRequired: informationPhase == .finished
                && ConsentInformation.shared.privacyOptionsRequirementStatus == .required,
            isBusy: busy,
            isSDKReady: sdkPhase == .ready,
            revision: revision
        )
        // The internal startup phase can advance without changing these public flags
        // (updating -> needsForm). Still notify the mounted host so it advances the flow.
        state = next
    }
}

/// Only use a controller in the caller's own window/scene; never select a global key window.
@MainActor
enum AdMobPresentation {
    static func isReady(_ controller: UIViewController) -> Bool {
        guard let window = controller.viewIfLoaded?.window,
              !window.isHidden,
              window.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active,
              !controller.isBeingPresented, !controller.isBeingDismissed,
              controller.presentedViewController == nil else { return false }
        var ancestor = controller.parent
        while let current = ancestor {
            if current.isBeingPresented || current.isBeingDismissed
                || current.presentedViewController != nil { return false }
            ancestor = current.parent
        }
        return true
    }
}

/// Catalog-backed copy; never expose raw SDK errors.
nonisolated enum AdMobCopy {

    static var privacyTitle: String { localized("ads.consent.title", "광고 동의 및 개인정보") }
    static var errorTitle: String { localized("ads.privacy.error.title", "광고 개인정보 설정") }
    static var errorMessage: String { localized("ads.privacy.error.message", "현재 광고 개인정보 설정을 열 수 없습니다. 잠시 후 다시 시도하세요.") }
    static var explanation: String { localized("ads.consent.explanation", "Google에서 필요한 광고 동의와 개인정보 선택을 확인합니다. 선택은 Google 양식에서 변경할 수 있습니다.") }
    static var notRequired: String { localized("ads.consent.notRequired", "현재 Google에서 표시할 동의 양식이나 변경할 개인정보 옵션이 없다고 안내했습니다.") }
    static var okayTitle: String { localized("action.close", "닫기") }

    private static func localized(_ key: String, _ fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current,
                              comment: "Ad privacy options; no SDK error details are shown.")
    }
}
#endif
