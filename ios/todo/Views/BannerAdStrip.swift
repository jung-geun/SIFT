#if !targetEnvironment(macCatalyst)
import Combine
import SwiftUI
import UIKit
import GoogleMobileAds
import OSLog

/// Mount exactly once, outside the TabView, in a safe-area-respecting VStack(spacing: 0).
/// Pass false during onboarding/tutorials, on ineligible screens, or while a custom overlay
/// obscures the placement. Do not conditionally remove the strip, put it inside a ScrollView,
/// add padding/animation, use ignoresSafeArea, or constrain its parent to less than 50pt high.
///
/// The strip is either 0pt or 50pt high. The creative is always exactly 320x50, never clipped,
/// stretched, or scaled. A safe width below 320pt, keyboard visibility, inactive scenes,
/// and disappeared controllers hide it. Native sheets occlude a retained ad themselves.
@MainActor
struct BannerAdStrip: View {
    let isEligible: Bool

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var mount = BannerMountState()

    init(isEligible: Bool) {
        self.isEligible = isEligible
    }

    var body: some View {
        BannerHost(mount: mount, isEligible: isEligible && scenePhase == .active)
            .frame(height: mount.height)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ads.bottomBanner")
            .transaction {
                // Never animate through intermediate heights that could crop an ad.
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

/// Settings entry point, independent of whether this screen is ad-eligible. UMP alone decides
/// whether the row exists. Errors are generic/localized and appear only after a button action.
@MainActor
struct AdMobPrivacyOptionsRow: View {
    @ObservedObject private var consent = AdMobConsentManager.shared
    @StateObject private var presenter = PrivacyPresenterState()
    @State private var presentationTask: Task<Void, Never>?
    @State private var showsError = false

    init() {}

    var body: some View {
        Group {
            if consent.isPrivacyOptionsRequired {
                Button {
                    presentOptions()
                } label: {
                    Label(AdMobCopy.privacyTitle, systemImage: "hand.raised")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .disabled(consent.isBusy || presentationTask != nil)
                .accessibilityIdentifier("settings.adPrivacyOptions")
                .background(PrivacyOptionsPresenter(presenter: presenter).allowsHitTesting(false))
                .alert(AdMobCopy.errorTitle, isPresented: $showsError) {
                    Button(AdMobCopy.okayTitle, role: .cancel) {}
                } message: {
                    Text(AdMobCopy.errorMessage)
                }
            }
        }
        .onDisappear {
            // UMP's presentation itself cannot be cancelled. Its consent gate remains closed
            // until its callback; this only prevents a detached Settings row from alerting.
            presentationTask?.cancel()
            presentationTask = nil
            showsError = false
        }
    }

    private func presentOptions() {
        guard presentationTask == nil else { return }
        guard let controller = presenter.controller else {
            showsError = true
            return
        }
        presentationTask = Task { @MainActor in
            defer { presentationTask = nil }
            do {
                try await consent.presentPrivacyOptions(from: controller)
            } catch is CancellationError {
                // Navigation/background cancellation is not a user-facing SDK error.
            } catch {
                guard !Task.isCancelled, presenter.controller?.viewIfLoaded?.window != nil else { return }
                showsError = true
            }
        }
    }
}

@MainActor
private final class BannerMountState: ObservableObject {
    @Published var height: CGFloat = 0
}

@MainActor
private struct BannerHost: UIViewControllerRepresentable {
    let mount: BannerMountState
    let isEligible: Bool

    func makeUIViewController(context: Context) -> BannerHostController {
        let controller = BannerHostController(mount: mount)
        controller.isEligible = isEligible
        return controller
    }

    func updateUIViewController(_ controller: BannerHostController, context: Context) {
        controller.isEligible = isEligible
        controller.scheduleReconcile()
    }

    static func dismantleUIViewController(_ controller: BannerHostController, coordinator: ()) {
        controller.dismantle()
    }
}

/// A real, stable controller in the SwiftUI hierarchy, also used for ad-click presentation.
/// It remains mounted when the strip is collapsed; the creative is NOT mounted into a 0pt view.
@MainActor
private final class BannerHostController: UIViewController {
    let mount: BannerMountState
    var isEligible = false
    private(set) var isMounted = true
    private var hasAppeared = false
    private var isSuspended = false
    private var keyboardFrame: CGRect?
    private var reconcileScheduled = false
    private weak var observedTransition: (any UIViewControllerTransitionCoordinator)?
    private var observations: [AnyCancellable] = []

    init(mount: BannerMountState) {
        self.mount = mount
        super.init(nibName: nil, bundle: nil)
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification,
            UIScene.didActivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardWillHideNotification
        ]
        observations = names.map { name in
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    MainActor.assumeIsolated { self?.handle(notification) }
                }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(mount:)") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        isSuspended = false
        scheduleReconcile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        scheduleReconcile()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleReconcile()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        scheduleReconcile()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.scheduleReconcile()
        }
        scheduleReconcile()
    }

    var isPlacementEligible: Bool {
        isMounted && isEligible && hasAppeared && !isSuspended && !hasKeyboard
            && viewIfLoaded?.window?.isHidden == false
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    /// Horizontal fit can be evaluated while collapsed, without depending on its own height.
    var fitsPlacement: Bool { safeHorizontalRange.width >= 320 }

    private var hasKeyboard: Bool {
        guard let keyboardFrame, let window = viewIfLoaded?.window else { return false }
        let frame = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
        let overlap = window.bounds.intersection(frame)
        // Also hide for floating/split keyboards; hardware keyboards with no onscreen frame
        // do not reserve an empty strip. Window conversion handles multiwindow coordinates.
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    private var safeHorizontalRange: (left: CGFloat, width: CGFloat) {
        guard let window = viewIfLoaded?.window else { return (0, 0) }
        let windowSafe = view.convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
        let left = max(view.bounds.minX + view.safeAreaInsets.left, windowSafe.minX)
        let right = min(view.bounds.maxX - view.safeAreaInsets.right, windowSafe.maxX)
        return (left, max(0, right - left))
    }

    func reserveHeight(_ height: CGFloat) {
        guard mount.height != height else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { mount.height = height }
    }

    func mountBanner(_ banner: BannerView) {
        // SwiftUI first allocates the full strip. Never place a 50pt creative in a zero-height
        // container and rely on overflow, clipping, opacity, or scaling to conceal it.
        guard view.bounds.height >= 50, safeHorizontalRange.width >= 320,
              let window = view.window else { return }
        let origin = CGPoint(x: safeHorizontalRange.left + (safeHorizontalRange.width - 320) / 2,
                             y: view.bounds.midY - 25)
        let frame = CGRect(origin: origin, size: CGSize(width: 320, height: 50))
        let inWindow = view.convert(frame, to: window)
        guard window.safeAreaLayoutGuide.layoutFrame.contains(inWindow) else { return }
        banner.frame = frame
        banner.rootViewController = self
        if banner.superview !== view { view.addSubview(banner) }
    }

    private func observePresentationTransition() {
        var controller: UIViewController? = self
        while let current = controller {
            if let coordinator = current.transitionCoordinator
                ?? current.presentedViewController?.transitionCoordinator {
                guard observedTransition !== coordinator else { return }
                observedTransition = coordinator
                // Sheet callbacks can precede presentedViewController being cleared.
                // Re-evaluate after completion without polling or loading another ad.
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.scheduleReconcile()
                }
                return
            }
            controller = current.parent
        }
    }

    func scheduleReconcile() {
        guard isMounted else { return }
        observePresentationTransition()
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        // UIKit layout and representable updates must not synchronously publish SwiftUI state.
        // This is event coalescing, not a refresh timer or polling loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            guard self.isMounted else { return }
            BannerAdSession.shared.reconcile(self)
        }
    }

    func dismantle() {
        isMounted = false
        observations.removeAll()
        BannerAdSession.shared.detach(self)
    }

    private func handle(_ notification: Notification) {
        if let scene = notification.object as? UIScene,
           scene !== viewIfLoaded?.window?.windowScene { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
             UIScene.didEnterBackgroundNotification:
            isSuspended = true
        case UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification:
            isSuspended = false
        case UIResponder.keyboardWillHideNotification:
            keyboardFrame = nil
        case UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification:
            if let local = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool, !local { return }
            keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        default:
            break
        }
        scheduleReconcile()
    }
}

/// One process-wide banner, not one per tab/SwiftUI render. It is replaced ONLY when consent
/// changes, since BannerView has neither a request token nor an API to clear a loaded creative.
/// Object identity fences callbacks from a revoked/replaced ad. Ordinary visibility changes
/// detach and retain the same banner; no manual refresh/retry is performed, including on failure.
@MainActor
private final class BannerAdSession: NSObject, BannerViewDelegate {
    static let shared = BannerAdSession()

    private weak var host: BannerHostController?
    private var banner: BannerView?
    /// Retain an invalidated initial load until its terminal callback. The SDK cannot cancel it;
    /// do not start another initial request concurrently, even after a privacy edit.
    private var pendingBanner: BannerView?
    private var isLoaded = false
    private var didAttempt = false
    private var consentRevision: UInt64 = 0
    private var hadPermission = false
    private var consentSubscription: AnyCancellable?

    private override init() {
        super.init()
        consentSubscription = AdMobConsentManager.shared.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.consentDidChange(state) }
        }
    }

    private static var adUnitID: String? {
        #if DEBUG || SIFT_QA || targetEnvironment(simulator)
        // Google's fixed 320x50 banner test unit. Release-QA must define SIFT_QA too.
        return "ca-app-pub-3940256099942544/2934735716"
        #else
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ADMOBBannerAdUnitID") as? String,
              value.hasPrefix("ca-app-pub-"), value.contains("/"),
              !value.contains("$("), !value.contains("3940256099942544") else { return nil }
        return value
        #endif
    }

    func reconcile(_ candidate: BannerHostController) {
        // Multiple windows/accidental extra mounts never reparent the same UIKit view or
        // controller simultaneously. The first mounted host owns the one process placement.
        if host == nil { host = candidate }
        guard host === candidate else {
            candidate.reserveHeight(0)
            return
        }
        guard candidate.isPlacementEligible else {
            hide()
            return
        }

        let consent = AdMobConsentManager.shared
        consent.prepare(from: candidate)
        guard candidate.fitsPlacement, consent.canRequestAds,
              consent.state.isSDKReady, !consent.isBusy else {
            hide()
            return
        }

        if !didAttempt, pendingBanner == nil, let unit = Self.adUnitID {
            let next = BannerView(adSize: AdSizeBanner)
            next.frame = CGRect(x: 0, y: 0, width: 320, height: 50)
            next.adUnitID = unit
            next.rootViewController = candidate
            next.delegate = self
            next.isAutoloadEnabled = false
            banner = next
            pendingBanner = next
            didAttempt = true
            #if DEBUG || SIFT_QA
            AdMobConsentManager.logger.debug("Banner initial request started.")
            #endif
            // GADBannerViewDelegate.h explicitly allows adding the banner on didReceiveAd.
            // Its frame is already 320x50 and its real presenter is mounted in the window.
            // Loading does not depend on mounting an invisible/zero-size ad to the hierarchy.
            let request = Request()
            let extras = Extras()
            extras.additionalParameters = ["npa": "1"]
            request.register(extras)
            next.load(request)
        }

        guard isLoaded, let banner else {
            hide()
            return
        }
        candidate.reserveHeight(50)
        candidate.mountBanner(banner)
    }

    func detach(_ candidate: BannerHostController) {
        guard host === candidate else { return }
        banner?.removeFromSuperview()
        banner?.rootViewController = nil
        host = nil
        // Retain the loaded banner/request for a later mount; no cancelled SDK request is
        // represented as completed, and no new request is issued just because a view remounts.
    }

    private func hide() {
        banner?.removeFromSuperview()
        host?.reserveHeight(0)
    }

    private func consentDidChange(_ state: AdMobConsentManager.State) {
        if consentRevision != state.revision || (hadPermission && !state.canRequestAds) {
            invalidateBanner()
        }
        consentRevision = state.revision
        hadPermission = state.canRequestAds
        host?.scheduleReconcile()
    }

    private func invalidateBanner() {
        if let banner {
            banner.removeFromSuperview()
            banner.rootViewController = nil
            // Preserve the delegate solely to drain an in-flight initial request. The old
            // object can never pass the current-banner identity check below.
            if pendingBanner !== banner { banner.delegate = nil }
        }
        banner = nil
        isLoaded = false
        didAttempt = false
        host?.reserveHeight(0)
    }

    /// Returns false for a retired request and releases it without ever displaying its ad.
    private func acceptCallback(_ result: BannerView) -> Bool {
        if pendingBanner === result { pendingBanner = nil }
        guard banner === result else {
            result.delegate = nil
            result.rootViewController = nil
            result.removeFromSuperview()
            host?.scheduleReconcile()
            return false
        }
        guard AdMobConsentManager.shared.canRequestAds,
              !AdMobConsentManager.shared.isBusy else {
            invalidateBanner()
            host?.scheduleReconcile()
            return false
        }
        return true
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        guard acceptCallback(bannerView) else { return }
        #if DEBUG || SIFT_QA
        AdMobConsentManager.logger.debug("Banner request loaded.")
        #endif
        isLoaded = true
        host?.scheduleReconcile()
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        guard acceptCallback(bannerView) else { return }
        #if DEBUG || SIFT_QA
        AdMobConsentManager.logger.debug("Banner request failed.")
        #endif
        isLoaded = false
        hide()
        // No blank strip, SDK error alert, diagnostics, manual retry, or refresh timer.
    }

    func bannerViewDidDismissScreen(_ bannerView: BannerView) {
        guard banner === bannerView else { return }
        host?.scheduleReconcile()
    }
}

@MainActor
private final class PrivacyPresenterState: ObservableObject {
    weak var controller: UIViewController?
}

@MainActor
private struct PrivacyOptionsPresenter: UIViewControllerRepresentable {
    let presenter: PrivacyPresenterState

    func makeCoordinator() -> PrivacyPresenterState { presenter }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        presenter.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: PrivacyPresenterState) {
        if coordinator.controller === controller { coordinator.controller = nil }
    }
}
#endif
