import Foundation
import Testing
@testable import todo

// MARK: - 사용자 맞춤 단어장: 편집 diff 추출 + 승격 규칙 (FM 불필요, 결정론적)
//
// SwiftData/AFM 없이 실행 가능한 순수 로직만 검증한다 — CI 파이프라인 포함.

@Suite("MeetingGlossary 편집 diff 추출")
struct MeetingGlossaryDiffTests {

    @Test("단일 토큰 치환 → (오인식 → 정규) 쌍 추출")
    func singleTokenSubstitution() {
        let pairs = UserVocabularyService.replacementPairs(before: "다음 쿠버네이트 배포를 논의했습니다",
        after: "다음 쿠버네티스 배포를 논의했습니다")
        #expect(pairs.count == 1)
        #expect(pairs.first?.from == "쿠버네이트")
        #expect(pairs.first?.to == "쿠버네티스")
    }

    @Test("변경 없음 → 빈 배열")
    func noChange() {
        let pairs = UserVocabularyService.replacementPairs(before: "동일한 문장입니다",
        after: "동일한 문장입니다")
        #expect(pairs.isEmpty)
    }

    @Test("대규모 재작성(3토큰 초과 교체) → 학습 스킵")
    func largeRewriteSkipped() {
        let pairs = UserVocabularyService.replacementPairs(before: "회의 시작 부분 잡담 인사말 날씨 이야기",
        after: "완전히 다른 문장 구조 새로운 내용 추가")
        #expect(pairs.isEmpty)
    }

    @Test("순수 숫자 교정은 어휘가 아니므로 스킵")
    func numericReplacementSkipped() {
        let pairs = UserVocabularyService.replacementPairs(before: "예산은 350 입니다",
        after: "예산은 3500 입니다")
        #expect(pairs.isEmpty)
    }

    @Test("너무 짧은 토큰(1자) 치환은 스킵")
    func shortTokenSkipped() {
        let pairs = UserVocabularyService.replacementPairs(before: "그 안을 검토",
        after: "이 안을 검토")
        #expect(pairs.isEmpty)
    }

    @Test("대소문자만 다른 변경은 스킵")
    func caseOnlyChangeSkipped() {
        let pairs = UserVocabularyService.replacementPairs(before: "우리는 kubernetes 를 씁니다",
        after: "우리는 Kubernetes 를 씁니다")
        // 동일 어휘의 표기 대소문자만 다르면 학습 대상 아님.
        #expect(pairs.isEmpty)
    }

    @Test("삽입/삭제만 있는 편집은 치환 쌍이 아님")
    func pureInsertionSkipped() {
        let pairs = UserVocabularyService.replacementPairs(before: "견적서를 보냅니다",
        after: "다음 주에 견적서를 보냅니다")
        #expect(pairs.isEmpty)
    }

    @Test("단순 어순 변경은 학습하지 않음(가짜 치환 방지)")
    func wordReorderNotLearned() {
        // 토큰이 이동만 했을 뿐 어휘 교정이 아니므로 (from→to) 쌍이 없어야 한다.
        let pairs = UserVocabularyService.replacementPairs(before: "빠른 갈색 여우가 뛰었다",
        after: "갈색 빠른 여우가 뛰었다")
        #expect(pairs.isEmpty)
    }

    @Test("치환 토큰이 편집 후에도 남아있으면 학습하지 않음")
    func movedTokenNotLearned() {
        // "회의록"이 after에도 존재 → 이동일 뿐 교정 아님.
        let pairs = UserVocabularyService.replacementPairs(before: "회의록 공유 부탁드립니다",
        after: "공유 부탁드립니다 회의록")
        #expect(pairs.allSatisfy { $0.from != "회의록" })
    }
}

@Suite("MeetingGlossaryTerm 승격 규칙")
struct MeetingGlossaryPromotionTests {

    @Test("사용자 편집 유래 용어는 즉시 승격")
    func editDiffPromotedImmediately() {
        let term = MeetingGlossaryTerm(canonical: "쿠버네티스", frequency: 1, source: MeetingGlossaryTerm.Source.editDiff.rawValue)
        #expect(term.isPromoted(corroborationThreshold: 2))
    }

    @Test("AFM 교정 candidate는 코로보레이션 전까지 미승격")
    func correctionCandidateNotPromotedBelowThreshold() {
        let term = MeetingGlossaryTerm(canonical: "쿠버네티스", frequency: 1, source: MeetingGlossaryTerm.Source.correction.rawValue)
        #expect(!term.isPromoted(corroborationThreshold: 2))
    }

    @Test("AFM 교정 candidate는 임계 도달 시 승격")
    func correctionCandidatePromotedAtThreshold() {
        let term = MeetingGlossaryTerm(canonical: "쿠버네티스", frequency: 2, source: MeetingGlossaryTerm.Source.correction.rawValue)
        #expect(term.isPromoted(corroborationThreshold: 2))
    }

    @Test("되돌려진(reverted) 용어는 빈도와 무관하게 미승격")
    func revertedNeverPromoted() {
        let term = MeetingGlossaryTerm(canonical: "쿠버네티스", frequency: 9, source: MeetingGlossaryTerm.Source.editDiff.rawValue)
        term.reverted = true
        #expect(!term.isPromoted(corroborationThreshold: 2))
    }

    @Test("빈 canonical은 미승격")
    func emptyCanonicalNotPromoted() {
        let term = MeetingGlossaryTerm(canonical: "", frequency: 5, source: MeetingGlossaryTerm.Source.editDiff.rawValue)
        #expect(!term.isPromoted(corroborationThreshold: 2))
    }
}
