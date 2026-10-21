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
