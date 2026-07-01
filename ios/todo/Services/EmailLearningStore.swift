import Foundation

// MARK: - Email Learning Store

/// 이메일→할 일 변환 관련 사용자 행동 패턴을 온디바이스에서 학습·저장.
///
/// UserDefaults 기반 (MemoryService와 동일 패턴) — CloudKit 동기화 범위 밖.
/// 기능:
///   1. 삭제된 이메일 messageID 영속화 → 재폴링 시 재생성 방지 (독립 버그 수정)
///   2. 발신자 이메일별 삭제 횟수 집계 → 임계치 도달 시 자동 억제
///   3. 억제 목록을 설정 화면에서 확인·해제 가능
final class EmailLearningStore {

    static let shared = EmailLearningStore()
    private init() {}

    // MARK: - UserDefaults Keys

    private enum Key {
        static let dismissedIDs = "pieroot.todo.dismissedMessageIDs"     // [String]
        static let analyzedIDs  = "pieroot.todo.analyzedMessageIDs"      // [String]
        static let deletionCounts = "pieroot.todo.senderDeletionCounts"   // [String: Int]
        static let suppressedSenders = "pieroot.todo.suppressedSenders"  // [String]
    }
    /// analyzed ID 목록 최대 보존 개수 (FIFO — UserDefaults 무한 증가 방지)
    private let analyzedCap = 1_000
    /// 발신자 삭제 횟수 임계치(반복 미승인 메일 자동 억제)
    private let suppressionThreshold = 2
    /// dismissed ID 목록 최대 보존 개수 (FIFO — UserDefaults 무한 증가 방지)
    private let dismissedCap = 500

    // MARK: - Public Query API

    /// 해당 발신자 이메일이 억제 목록에 있는지 확인
    func isSuppressed(_ senderEmail: String) -> Bool {
        guard !senderEmail.isEmpty else { return false }
        return suppressedSendersSet().contains(senderEmail.lowercased())
    }

    /// 이미 분석한 messageID 집합.
    func analyzedMessageIDs() -> Set<String> {
        Set(SettingsStore.shared.get(Key.analyzedIDs, defaultValue: []))
    }

    /// 해당 messageID(sourceRef)가 이미 분석된 적 있는지 확인
    func hasAnalyzed(_ messageID: String) -> Bool {
        guard !messageID.isEmpty else { return false }
        return analyzedMessageIDs().contains(messageID)
    }

    /// dismissed(삭제 반영) messageID 집합.
    func dismissedMessageIDs() -> Set<String> {
        Set(SettingsStore.shared.get(Key.dismissedIDs, defaultValue: []))
    }

    /// 해당 messageID(sourceRef)가 이미 처리(삭제)된 적 있는지 확인
    func isDismissed(_ messageID: String) -> Bool {
        guard !messageID.isEmpty else { return false }
        return dismissedMessageIDs().contains(messageID)
    }

    // MARK: - Public Mutation API

    /// 이메일 분석 결과 messageID 기록.
    /// - messageIDs: 분석 대상으로 조회된 Gmail messageID 목록.
    ///
    /// 동작:
    ///   1. 비어있지 않은 messageID만 정리
    ///   2. 기존 목록 뒤에 중복 없이 append
    ///   3. FIFO 기준으로 analyzedCap만 유지 (가장 오래된 값 제거)
    func recordAnalyzed(messageIDs: [String]) {
        let normalized = messageIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        var list: [String] = SettingsStore.shared.get(Key.analyzedIDs, defaultValue: [])
        for messageID in normalized where !list.contains(messageID) {
            list.append(messageID)
        }
        if list.count > analyzedCap {
            list = Array(list.suffix(analyzedCap))
        }
        SettingsStore.shared.set(Key.analyzedIDs, value: list)
    }

    /// 이메일 할 일 삭제 시 호출.
    /// - messageID: Todo.sourceRef (Gmail API message ID)
    /// - senderEmail: Todo.sourceSenderEmail (학습 키)
    ///
    /// 동작:
    ///   1. messageID → dismissed 목록에 추가 (FIFO 캡)
    ///   2. senderEmail → 삭제 카운트 증가 → 임계치 도달 시 자동 억제
    func recordDeletion(senderEmail: String, messageID: String) {
        addDismissed(messageID)
        if !senderEmail.isEmpty {
            incrementDeletionCount(for: senderEmail.lowercased())
        }
    }

    /// 억제된 발신자 이메일 목록 반환 (설정 화면 표시용)
    func suppressedSenders() -> [String] {
        let list: [String] = SettingsStore.shared.get(Key.suppressedSenders, defaultValue: [])
        return list.sorted()
    }

    /// 발신자 억제를 수동으로 해제 (설정 화면 해제 버튼)
    func unsuppress(_ senderEmail: String) {
        let lower = senderEmail.lowercased()
        var list = suppressedSendersSet()
        list.remove(lower)
        SettingsStore.shared.set(Key.suppressedSenders, value: Array(list))

        // 삭제 카운트도 리셋 — 해제 후 다시 임계치부터 카운트
        var counts = deletionCounts()
        counts.removeValue(forKey: lower)
        saveDeletionCounts(counts)
    }

    // MARK: - Private Helpers

    private func suppressedSendersSet() -> Set<String> {
        let list: [String] = SettingsStore.shared.get(Key.suppressedSenders, defaultValue: [])
        return Set(list)
    }

    private func deletionCounts() -> [String: Int] {
        SettingsStore.shared.get(Key.deletionCounts, defaultValue: [:])
    }

    private func saveDeletionCounts(_ counts: [String: Int]) {
        SettingsStore.shared.set(Key.deletionCounts, value: counts)
    }

    private func addDismissed(_ messageID: String) {
        guard !messageID.isEmpty else { return }
        var list: [String] = SettingsStore.shared.get(Key.dismissedIDs, defaultValue: [])
        guard !list.contains(messageID) else { return }
        list.append(messageID)
        // FIFO 캡 — 오래된 것부터 제거
        if list.count > dismissedCap {
            list = Array(list.suffix(dismissedCap))
        }
        SettingsStore.shared.set(Key.dismissedIDs, value: list)
    }

    private func incrementDeletionCount(for senderEmail: String) {
        var counts = deletionCounts()
        let newCount = (counts[senderEmail] ?? 0) + 1
        counts[senderEmail] = newCount
        saveDeletionCounts(counts)

        // 임계치 도달 → 억제 목록에 추가
        if newCount >= suppressionThreshold {
            var suppressed = suppressedSendersSet()
            suppressed.insert(senderEmail)
            SettingsStore.shared.set(Key.suppressedSenders, value: Array(suppressed))
        }
    }
}
