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
        static let dismissedIDs      = "pieroot.todo.dismissedMessageIDs"   // [String]
        static let deletionCounts    = "pieroot.todo.senderDeletionCounts"  // [String: Int]
        static let suppressedSenders = "pieroot.todo.suppressedSenders"     // [String]
    }

    // MARK: - Configuration

    /// 같은 발신자를 이 횟수 이상 삭제하면 자동 억제
    private let suppressionThreshold = 2
    /// dismissed ID 목록 최대 보존 개수 (FIFO — UserDefaults 무한 증가 방지)
    private let dismissedCap = 500

    // MARK: - Public Query API

    /// 해당 발신자 이메일이 억제 목록에 있는지 확인
    func isSuppressed(_ senderEmail: String) -> Bool {
        guard !senderEmail.isEmpty else { return false }
        return suppressedSendersSet().contains(senderEmail.lowercased())
    }

    /// 해당 messageID(sourceRef)가 이미 처리(삭제)된 적 있는지 확인
    func isDismissed(_ messageID: String) -> Bool {
        guard !messageID.isEmpty else { return false }
        let list = UserDefaults.standard.stringArray(forKey: Key.dismissedIDs) ?? []
        return list.contains(messageID)
    }

    // MARK: - Public Mutation API

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
        (UserDefaults.standard.stringArray(forKey: Key.suppressedSenders) ?? []).sorted()
    }

    /// 발신자 억제를 수동으로 해제 (설정 화면 해제 버튼)
    func unsuppress(_ senderEmail: String) {
        let lower = senderEmail.lowercased()
        var list = suppressedSendersSet()
        list.remove(lower)
        UserDefaults.standard.set(Array(list), forKey: Key.suppressedSenders)

        // 삭제 카운트도 리셋 — 해제 후 다시 임계치부터 카운트
        var counts = deletionCounts()
        counts.removeValue(forKey: lower)
        saveDeletionCounts(counts)
    }

    // MARK: - Private Helpers

    private func suppressedSendersSet() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Key.suppressedSenders) ?? [])
    }

    private func deletionCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: Key.deletionCounts) as? [String: Int]) ?? [:]
    }

    private func saveDeletionCounts(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: Key.deletionCounts)
    }

    private func addDismissed(_ messageID: String) {
        guard !messageID.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: Key.dismissedIDs) ?? []
        guard !list.contains(messageID) else { return }
        list.append(messageID)
        // FIFO 캡 — 오래된 것부터 제거
        if list.count > dismissedCap {
            list = Array(list.suffix(dismissedCap))
        }
        UserDefaults.standard.set(list, forKey: Key.dismissedIDs)
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
            UserDefaults.standard.set(Array(suppressed), forKey: Key.suppressedSenders)
        }
    }
}
