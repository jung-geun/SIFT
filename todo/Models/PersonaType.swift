import Foundation

// MARK: - PersonaType

/// 사용자 생활 유형 — 온보딩에서 선택, HeuristicEngine 우선순위 가중치에 반영.
enum PersonaType: String, CaseIterable, Codable, Sendable {
    case student       = "student"
    case officeWorker  = "officeWorker"
    case freelancer    = "freelancer"
    case jobSeeker     = "jobSeeker"
    case selfEmployed  = "selfEmployed"
    case homemaker     = "homemaker"
    case other         = "other"
    case unspecified   = ""

    var displayName: String {
        switch self {
        case .student:      "학생"
        case .officeWorker: "직장인"
        case .freelancer:   "프리랜서"
        case .jobSeeker:    "취업준비생"
        case .selfEmployed: "자영업"
        case .homemaker:    "주부"
        case .other:        "기타"
        case .unspecified:  "미설정"
        }
    }

    var systemImage: String {
        switch self {
        case .student:      "graduationcap"
        case .officeWorker: "briefcase"
        case .freelancer:   "laptopcomputer"
        case .jobSeeker:    "doc.text.magnifyingglass"
        case .selfEmployed: "storefront"
        case .homemaker:    "house"
        case .other:        "person"
        case .unspecified:  "questionmark.circle"
        }
    }

    /// 온보딩 2단계에서 제시하는 자기소개 프리셋 칩
    var presetDescriptions: [String] {
        switch self {
        case .student:
            return ["대학교 재학 중", "대학원 과정", "고등학생", "자격증 공부 중", "졸업 예정"]
        case .officeWorker:
            return ["IT/개발", "기획/마케팅", "영업/고객지원", "재무/회계", "디자인", "HR/교육"]
        case .freelancer:
            return ["개발·프로그래밍", "디자인·영상", "번역·글쓰기", "컨설팅", "강의·튜터링"]
        case .jobSeeker:
            return ["대기업 준비", "공기업·공무원", "스타트업 지원 중", "해외 취업 목표", "포트폴리오 준비 중"]
        case .selfEmployed:
            return ["온라인 쇼핑몰", "음식점·카페", "서비스업", "B2B 사업", "1인 기업"]
        case .homemaker:
            return ["육아 중", "학부모", "가사 전담", "부업 병행 중"]
        case .other:
            return ["은퇴·휴식 중", "창업 준비 중", "다양한 활동 병행", "특수 직종"]
        case .unspecified:
            return []
        }
    }

    /// HeuristicEngine이 todo 제목·태그와 매칭할 가중 키워드
    var weightedKeywords: [String] {
        switch self {
        case .student:
            return ["과제", "시험", "수업", "제출", "리포트", "발표", "레포트", "강의", "퀴즈", "프로젝트", "논문", "실습"]
        case .officeWorker:
            return ["회의", "보고", "마감", "프로젝트", "결재", "기획서", "미팅", "업무", "출장", "계약", "협의", "검토"]
        case .freelancer:
            return ["납품", "클라이언트", "계약", "수정", "검수", "청구", "견적", "피드백", "마감", "포트폴리오"]
        case .jobSeeker:
            return ["지원", "면접", "서류", "이력서", "자소서", "자기소개서", "인적성", "필기", "채용", "공고"]
        case .selfEmployed:
            return ["발주", "재고", "정산", "매출", "세금", "고객", "배송", "주문", "공급", "계약"]
        case .homemaker:
            return ["장보기", "청소", "육아", "병원", "학교", "준비물", "요리", "세탁", "모임"]
        case .other, .unspecified:
            return []
        }
    }

    /// CaseIterable 중 실제 온보딩 선택지로 표시할 case (unspecified 제외)
    static var selectable: [PersonaType] {
        allCases.filter { $0 != .unspecified }
    }
}
