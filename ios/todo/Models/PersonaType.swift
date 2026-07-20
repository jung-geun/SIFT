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
        displayName(language: .current)
    }

    func displayName(language: AppLanguage) -> String {
        let korean: String
        let english: String
        switch self {
        case .student:      korean = "학생"; english = "Student"
        case .officeWorker: korean = "직장인"; english = "Office Worker"
        case .freelancer:   korean = "프리랜서"; english = "Freelancer"
        case .jobSeeker:    korean = "취업준비생"; english = "Job Seeker"
        case .selfEmployed: korean = "자영업"; english = "Self-Employed"
        case .homemaker:    korean = "주부"; english = "Homemaker"
        case .other:        korean = "기타"; english = "Other"
        case .unspecified:  korean = "미설정"; english = "Not Set"
        }
        return language == .english ? english : korean
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
        presetDescriptions(language: .current)
    }

    func presetDescriptions(language: AppLanguage) -> [String] {
        switch self {
        case .student:
            return language == .english
                ? ["University student", "Graduate student", "High school student", "Studying for a certification", "Graduating soon"]
                : ["대학교 재학 중", "대학원 과정", "고등학생", "자격증 공부 중", "졸업 예정"]
        case .officeWorker:
            return language == .english
                ? ["IT / Development", "Planning / Marketing", "Sales / Customer Support", "Finance / Accounting", "Design", "HR / Education"]
                : ["IT/개발", "기획/마케팅", "영업/고객지원", "재무/회계", "디자인", "HR/교육"]
        case .freelancer:
            return language == .english
                ? ["Development / Programming", "Design / Video", "Translation / Writing", "Consulting", "Teaching / Tutoring"]
                : ["개발·프로그래밍", "디자인·영상", "번역·글쓰기", "컨설팅", "강의·튜터링"]
        case .jobSeeker:
            return language == .english
                ? ["Preparing for a large company", "Preparing for public service", "Applying to startups", "Targeting work abroad", "Preparing a portfolio"]
                : ["대기업 준비", "공기업·공무원", "스타트업 지원 중", "해외 취업 목표", "포트폴리오 준비 중"]
        case .selfEmployed:
            return language == .english
                ? ["Online shop", "Restaurant / Cafe", "Services", "B2B business", "Solo business"]
                : ["온라인 쇼핑몰", "음식점·카페", "서비스업", "B2B 사업", "1인 기업"]
        case .homemaker:
            return language == .english
                ? ["Childcare", "Parenting", "Household work", "Running a side business"]
                : ["육아 중", "학부모", "가사 전담", "부업 병행 중"]
        case .other:
            return language == .english
                ? ["Retired / Resting", "Preparing a business", "Several activities", "Specialized occupation"]
                : ["은퇴·휴식 중", "창업 준비 중", "다양한 활동 병행", "특수 직종"]
        case .unspecified:
            return []
        }
    }

    /// HeuristicEngine이 todo 제목·태그와 매칭할 가중 키워드
    var weightedKeywords: [String] {
        let korean: [String]
        let english: [String]
        switch self {
        case .student:
            korean = ["과제", "시험", "수업", "제출", "리포트", "발표", "레포트", "강의", "퀴즈", "프로젝트", "논문", "실습"]
            english = ["assignment", "exam", "class", "submit", "report", "presentation", "lecture", "quiz", "project", "thesis", "lab"]
        case .officeWorker:
            korean = ["회의", "보고", "마감", "프로젝트", "결재", "기획서", "미팅", "업무", "출장", "계약", "협의", "검토"]
            english = ["meeting", "report", "deadline", "project", "approval", "proposal", "business trip", "contract", "review"]
        case .freelancer:
            korean = ["납품", "클라이언트", "계약", "수정", "검수", "청구", "견적", "피드백", "마감", "포트폴리오"]
            english = ["delivery", "client", "contract", "revision", "invoice", "estimate", "feedback", "deadline", "portfolio"]
        case .jobSeeker:
            korean = ["지원", "면접", "서류", "이력서", "자소서", "자기소개서", "인적성", "필기", "채용", "공고"]
            english = ["application", "interview", "resume", "cover letter", "assessment", "recruitment", "vacancy", "portfolio"]
        case .selfEmployed:
            korean = ["발주", "재고", "정산", "매출", "세금", "고객", "배송", "주문", "공급", "계약"]
            english = ["purchase order", "inventory", "settlement", "sales", "tax", "customer", "shipping", "order", "supplier", "contract"]
        case .homemaker:
            korean = ["장보기", "청소", "육아", "병원", "학교", "준비물", "요리", "세탁", "모임"]
            english = ["groceries", "cleaning", "childcare", "hospital", "school", "supplies", "cooking", "laundry", "gathering"]
        case .other, .unspecified:
            korean = []
            english = []
        }
        return korean + english
    }

    /// CaseIterable 중 실제 온보딩 선택지로 표시할 case (unspecified 제외)
    static var selectable: [PersonaType] {
        allCases.filter { $0 != .unspecified }
    }
}
