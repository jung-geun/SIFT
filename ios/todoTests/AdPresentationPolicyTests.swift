import Foundation
import Testing
@testable import todo

@Suite("Advertisement presentation access")
struct AdPresentationPolicyTests {
    @Test("Without verified ad removal, ordinary launches remain ad-supported")
    func ordinaryLaunch() {
        #expect(AdPresentationPolicy.resolve(hasVerifiedAdRemoval: false, arguments: []).allowsAds)
    }

    @Test("Verified ad removal is independent of consent and launch arguments")
    func verifiedRemoval() {
        #expect(!AdPresentationPolicy.resolve(hasVerifiedAdRemoval: true, arguments: []).allowsAds)
        #expect(!AdPresentationPolicy.resolve(
            hasVerifiedAdRemoval: true, arguments: ["-sift-test-ad-free"]
        ).allowsAds)
    }

    @Test("Only test builds honor the exact internal ad-free launch argument")
    func testBuildOverride() {
        let policy = AdPresentationPolicy.resolve(
            hasVerifiedAdRemoval: false, arguments: ["SIFT", "-sift-test-ad-free"]
        )
        #if DEBUG || SIFT_QA
        #expect(!policy.allowsAds)
        #else
        #expect(policy.allowsAds)
        #endif
    }

    @Test("Similar arguments cannot enable ad removal")
    func exactArgumentOnly() {
        #expect(AdPresentationPolicy.resolve(
            hasVerifiedAdRemoval: false,
            arguments: ["-sift-test-ad-free=true", "sift-test-ad-free", "-SIFT-TEST-AD-FREE"]
        ).allowsAds)
    }
}

#if !targetEnvironment(macCatalyst)
@Suite("Advertising privacy failure explanations")
struct AdMobPrivacyOptionsErrorTests {
    private typealias Failure = AdMobConsentManager.PrivacyOptionsError
    private let umpDomain = "com.google.user_messaging_platform"

    @Test("Invalid app IDs and publisher misconfiguration require operator action", arguments: [2, 4])
    func publisherConfiguration(code: Int) {
        let error = NSError(domain: umpDomain, code: code)
        #expect(Failure.classify(error) == .configuration)
        #expect(Failure.classify(error).errorDescription == AdMobCopy.configurationError)
    }

    @Test("Network failures and form timeouts offer connection recovery", arguments: [3, 8])
    func networkFailure(code: Int) {
        let error = NSError(domain: umpDomain, code: code)
        #expect(Failure.classify(error) == .network)
        #expect(Failure.classify(error).errorDescription == AdMobCopy.networkError)
    }

    @Test("An unavailable form is not success or a fabricated no-form-required result")
    func unavailableForm() {
        let error = NSError(domain: umpDomain, code: 7)
        #expect(Failure.classify(error) == .formUnavailable)
        #expect(Failure.classify(error).errorDescription == AdMobCopy.formUnavailableError)
    }

    @Test("Other UMP failures remain unspecified", arguments: [1, 5, 6, 9, 999])
    func otherUMPFailures(code: Int) {
        #expect(Failure.classify(NSError(domain: umpDomain, code: code)) == .unavailable)
    }

    @Test("Matching codes or configuration text from another domain are not publisher evidence")
    func unrelatedDomain() {
        let error = NSError(
            domain: "another.sdk",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "no forms configured; private-sdk-detail"]
        )
        #expect(Failure.classify(error) == .unavailable)
        #expect(!Failure.classify(error).localizedDescription.contains("private-sdk-detail"))
    }

    @Test("Classification survives the manager's catch without becoming generic")
    func preservesClassifiedFailure() {
        for failure in [Failure.configuration, .network, .formUnavailable, .unavailable] {
            #expect(Failure.classify(failure) == failure)
        }
    }

    @Test("Publisher error details never enter user-facing explanations")
    func redactsSDKDescription() {
        let error = NSError(
            domain: umpDomain,
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "private-sdk-detail app-id account-token"]
        )
        let description = Failure.classify(error).localizedDescription
        #expect(!description.contains("private-sdk-detail"))
        #expect(!description.contains("account-token"))
    }
}
#endif
