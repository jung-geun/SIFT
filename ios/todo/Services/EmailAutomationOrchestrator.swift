import Foundation
import Combine
import SwiftData
import UIKit

/// Local, account-scoped action analysis. Mail discovery and body downloads belong
/// to MailboxIncrementalSyncCoordinator and never await this queue. Analysis stores
/// structured actions on the email; only explicit import creates review tasks.
@MainActor
final class EmailAutomationOrchestrator: ObservableObject {
    static let shared = EmailAutomationOrchestrator()

    /// Actual local analysis work, not a global lock or a mailbox-fetch indicator.
    @Published private(set) var isRunning = false

    private struct Account: Hashable {
        let provider: MailProvider
        let namespace: String
    }
    private enum Mode: Equatable {
        case foreground, background, manual
    }
    private struct Worker {
        let id: UUID
        let mode: Mode
        let task: Task<Int, Never>
    }


    nonisolated static let maxAutomaticAttempts = 5
    nonisolated static let baseRetryInterval: TimeInterval = 5 * 60
    nonisolated static let maxRetryInterval: TimeInterval = 24 * 60 * 60
    private static let retryKeyPrefix = "sift.local.mailAnalysisAttempt."
    private static let retryIndexKeyPrefix = "sift.local.mailAnalysisAttemptKeys."

    private struct RetryMarker {
        let source: String
        let count: Int
        let lastAttemptAt: Date
        let retryAt: Date?
    }
    private let defaults: UserDefaults
    private let makeContext: () -> ModelContext
    private let analysisService: EmailMessageAnalysisService
    private let accountAvailable: (MailProvider, String) -> Bool
    private let batteryAllowsAnalysis: () -> Bool
    private let now: () -> Date
    private var workers: [Account: Worker] = [:]
    private var requested: Set<Account> = []

    init(
        defaults: UserDefaults = .standard,
        makeContext: (() -> ModelContext)? = nil,
        analysisService: EmailMessageAnalysisService? = nil,
        accountAvailable: ((MailProvider, String) -> Bool)? = nil,
        batteryAllowsAnalysis: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
        self.makeContext = makeContext ?? { ModelContext(AppDataContainer.shared.emailContainer) }
        self.analysisService = analysisService ?? .shared
        self.accountAvailable = accountAvailable ?? { provider, namespace in
            switch provider {
            case .gmail:
                return IMAPCredentialStore.hasCredential(for: namespace)
                    && !IMAPCredentialStore.isCredentialRejected(for: namespace)
            case .outlook:
                return OutlookIMAPCredentialStore.hasCredential(for: namespace)
            }
        }
        self.batteryAllowsAnalysis = batteryAllowsAnalysis ?? {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let device = UIDevice.current
            return device.batteryState == .unknown || device.batteryState == .charging
                || device.batteryState == .full || device.batteryLevel < 0
                || device.batteryLevel >= 0.25
        }
    }

    /// Called after a durable body commit, or a foreground mailbox tick. Coalesces
    /// only this account; another account's slow model invocation cannot block it.
    func enqueue(provider: MailProvider, namespace: String) {
        let account = Account(provider: provider, namespace: namespace)
        guard isEligible(account, mode: .foreground) else { return }
        _ = start(account, mode: .foreground)
    }

    /// Compatibility entry point for foreground callers. The Todo context is not
    /// used: analysis is performed solely on durable complete-body email rows.
    /// Background callers must await this bounded pass inside their OS task and
    /// cancel it at expiration; this never schedules a background timer.
    @discardableResult
    func runIfEligible(context _: ModelContext, backgroundOnly: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        let mode: Mode = backgroundOnly ? .background : .foreground
        var tasks: [Task<Int, Never>] = []
        for provider in [MailProvider.gmail, .outlook] {
            guard let namespace = namespace(for: provider) else { continue }
            let account = Account(provider: provider, namespace: namespace)
            if isEligible(account, mode: mode) {
                tasks.append(start(account, mode: mode))
            }
        }
        let pendingTasks = tasks
        return await withTaskCancellationHandler {
            var succeeded = false
            for task in pendingTasks { succeeded = await task.value > 0 || succeeded }
            return succeeded && !Task.isCancelled
        } onCancel: {
            for task in pendingTasks { task.cancel() }
        }
    }

    /// The explicit settings action is not automatic-analysis consent. It may
    /// analyze this selected account's cached bodies even when automation is off.
    /// Provider opt-in still belongs to EmailMessageAnalysisService.
    func analyzeNow(provider: MailProvider, namespace: String) async -> Int {
        let account = Account(provider: provider, namespace: namespace)
        guard !Task.isCancelled, isEligible(account, mode: .manual) else { return 0 }
        clearRetryMarkers(for: account)
        let task = start(account, mode: .manual)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Explicit user refreshes clear automatic retry caps/backoff for that
    /// account without touching CloudKit preferences or message content.
    func resetAutomaticRetries(provider: MailProvider, namespace: String) {
        guard let canonical = canonicalNamespace(for: provider, raw: namespace) else { return }
        clearRetryMarkers(for: Account(provider: provider, namespace: canonical))
    }

    func stopForegroundProcessing() {
        for (account, worker) in workers where worker.mode != .background {
            worker.task.cancel()
            requested.remove(account)
        }
    }

    private func start(_ account: Account, mode: Mode) -> Task<Int, Never> {
        requested.insert(account)
        let previous = workers[account]
        if let previous, !previous.task.isCancelled,
           previous.mode == mode || (previous.mode == .manual && mode == .foreground) { return previous.task }
        previous?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return 0 }
            // A lifecycle-mode change must finish the cancelled claim before a
            // new worker can analyze this account under its new permission gate.
            if let previous { _ = await previous.task.value }
            let result = await self.process(account, mode: mode)
            if self.workers[account]?.id == id {
                self.workers.removeValue(forKey: account)
                self.requested.remove(account)
                self.isRunning = !self.workers.isEmpty
            }
            return result
        }
        workers[account] = Worker(id: id, mode: mode, task: task)
        isRunning = true
        return task
    }

    private func process(_ account: Account, mode: Mode) async -> Int {
        let context = makeContext()
        var attempted = Set<EmailMessageKey>()
        var completed = 0
        repeat {
            requested.remove(account)
            guard !Task.isCancelled, isEligible(account, mode: mode) else { return 0 }
            let providerRaw = account.provider.rawValue
            let namespace = account.namespace
            let descriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate {
                    $0.providerRawValue == providerRaw && $0.sourceAccountNamespace == namespace
                        && $0.isInInbox
                },
                sortBy: [SortDescriptor(\.receivedAt, order: .reverse), SortDescriptor(\.rawMessageID)]
            )
            let rows: [EmailMessage]
            do { rows = try context.fetch(descriptor) }
            catch { return 0 }
            for email in rows {
                guard !Task.isCancelled, isEligible(account, mode: mode) else { return 0 }
                guard !EmailAnalysisContract.normalizedBody(email.body).isEmpty,
                      !attempted.contains(EmailMessageKey(email))
                else { continue }
                // A synced analysis with a matching body fingerprint is already
                // complete; skip local model work even before local body hydration.
                if EmailAnalysisContract.isCurrentAnalysis(email), email.analysisFailureReasonRaw == nil {
                    clearRetryMarker(for: email, account: account)
                    continue
                }
                guard email.hasCompleteBody, analysisService.needsAnalysis(email) else { continue }
                let retryKey = self.retryKey(for: email, account: account)
                let source = EmailAnalysisContract.fingerprint(subject: email.subject, body: email.body)
                    + ":\(analysisService.retryEligibilityVersion)"
                let existingMarker = readRetryMarker(forKey: retryKey)
                let priorCount: Int
                if let existingMarker, existingMarker.source == source {
                    if mode != .manual {
                        if existingMarker.count >= Self.maxAutomaticAttempts {
                            continue
                        }
                        let dueAt = existingMarker.retryAt
                            ?? existingMarker.lastAttemptAt.addingTimeInterval(
                                Self.retryDelay(forAttempt: existingMarker.count)
                            )
                        if now() < dueAt {
                            continue
                        }
                    }
                    priorCount = mode == .manual ? 0 : existingMarker.count
                } else {
                    if existingMarker != nil {
                        removeRetryMarker(forKey: retryKey, account: account)
                    }
                    priorCount = 0
                }
                attempted.insert(EmailMessageKey(email))
                let attemptNumber = priorCount + 1
                let attemptTime = now()
                writeRetryMarker(
                    RetryMarker(
                        source: source,
                        count: attemptNumber,
                        lastAttemptAt: attemptTime,
                        retryAt: attemptNumber >= Self.maxAutomaticAttempts
                            ? nil
                            : attemptTime.addingTimeInterval(Self.retryDelay(forAttempt: attemptNumber))
                    ),
                    forKey: retryKey,
                    account: account
                )
                do {
                    try await analysisService.analyze(email, context: context, isAuthorized: {
                        self.isEligible(account, mode: mode)
                    })
                    if EmailAnalysisContract.isCurrentAnalysis(email) { completed += 1 }
                    if EmailAnalysisContract.isCurrentAnalysis(email), email.analysisFailureReasonRaw == nil {
                        removeRetryMarker(forKey: retryKey, account: account)
                    }
                } catch is CancellationError {
                    if let existingMarker, existingMarker.source == source {
                        writeRetryMarker(existingMarker, forKey: retryKey, account: account)
                    } else {
                        removeRetryMarker(forKey: retryKey, account: account)
                    }
                    return 0
                } catch {
                    DiagnosticRecorder.shared.record(error: error, component: "mail.local", operation: "analysis")
                    // One unreadable/failed local message must not starve its peers.
                }
                if mode == .background && attempted.count >= MailboxPagingPolicy.bodyPrefetchBatchSize {
                    return completed
                }
            }
            // Body commits arriving while the model was suspended are picked up
            // without refetching a server page or rerunning failed rows this turn.
        } while requested.contains(account) && mode != .background
        return completed
    }

    private func namespace(for provider: MailProvider) -> String? {
        switch provider {
        case .gmail:
            return IMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.imap.account") ?? "")
        case .outlook:
            return OutlookIMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.outlook.account") ?? "")
        }
    }

    private func canonicalNamespace(for provider: MailProvider, raw: String) -> String? {
        switch provider {
        case .gmail:
            return IMAPCredentialStore.canonicalAccount(raw)
        case .outlook:
            return OutlookIMAPCredentialStore.canonicalAccount(raw)
        }
    }

    nonisolated static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, min(10, attempt - 1))
        return min(maxRetryInterval, baseRetryInterval * Double(1 << exponent))
    }

    private func retryKey(for email: EmailMessage, account: Account) -> String {
        let identity = "\(account.provider.rawValue)\u{0}\(account.namespace)\u{0}\(email.providerMessageID)"
        return Self.retryKeyPrefix + EmailAnalysisContract.fingerprint(subject: identity, body: "")
    }

    private func retryIndexKey(for account: Account) -> String {
        let identity = "\(account.provider.rawValue)\u{0}\(account.namespace)"
        return Self.retryIndexKeyPrefix + EmailAnalysisContract.fingerprint(subject: identity, body: "")
    }

    private func readRetryMarker(forKey key: String) -> RetryMarker? {
        guard let raw = defaults.dictionary(forKey: key),
              let source = raw["source"] as? String,
              let lastAttemptAt = raw["at"] as? Date
        else { return nil }
        let count = max(1, (raw["count"] as? Int) ?? 1)
        let retryAt = raw["retryAt"] as? Date
        return RetryMarker(source: source, count: count, lastAttemptAt: lastAttemptAt, retryAt: retryAt)
    }

    private func writeRetryMarker(_ marker: RetryMarker, forKey key: String, account: Account) {
        var payload: [String: Any] = [
            "source": marker.source,
            "count": marker.count,
            "at": marker.lastAttemptAt
        ]
        if let retryAt = marker.retryAt {
            payload["retryAt"] = retryAt
        }
        defaults.set(payload, forKey: key)
        let indexKey = retryIndexKey(for: account)
        var keys = Set(defaults.stringArray(forKey: indexKey) ?? [])
        if keys.insert(key).inserted {
            defaults.set(Array(keys), forKey: indexKey)
        }
    }

    private func clearRetryMarker(for email: EmailMessage, account: Account) {
        removeRetryMarker(forKey: retryKey(for: email, account: account), account: account)
    }

    private func removeRetryMarker(forKey key: String, account: Account) {
        defaults.removeObject(forKey: key)
        let indexKey = retryIndexKey(for: account)
        var keys = Set(defaults.stringArray(forKey: indexKey) ?? [])
        if keys.remove(key) != nil {
            if keys.isEmpty {
                defaults.removeObject(forKey: indexKey)
            } else {
                defaults.set(Array(keys), forKey: indexKey)
            }
        }
    }

    private func clearRetryMarkers(for account: Account) {
        let indexKey = retryIndexKey(for: account)
        for key in defaults.stringArray(forKey: indexKey) ?? [] {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: indexKey)
    }

    private func isEligible(_ account: Account, mode: Mode) -> Bool {
        guard namespace(for: account.provider) == account.namespace,
              accountAvailable(account.provider, account.namespace) else { return false }
        if mode == .manual { return true }
        guard defaults.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled"), batteryAllowsAnalysis()
        else { return false }
        let backgroundKey = account.provider == .gmail
            ? "pieroot.todo.imap.backgroundEnabled" : "pieroot.todo.outlook.backgroundEnabled"
        return mode != .background || defaults.bool(forKey: backgroundKey)
    }
}
