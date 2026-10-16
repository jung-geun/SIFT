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
        let key: String
        let korean: String
        let english: String
        switch self {
        case .student: (key, korean, english) = ("persona.type.student", "학생", "Student")
        case .officeWorker: (key, korean, english) = ("persona.type.officeWorker", "직장인", "Office Worker")
        case .freelancer: (key, korean, english) = ("persona.type.freelancer", "프리랜서", "Freelancer")
        case .jobSeeker: (key, korean, english) = ("persona.type.jobSeeker", "취업준비생", "Job Seeker")
        case .selfEmployed: (key, korean, english) = ("persona.type.selfEmployed", "자영업", "Self-Employed")
        case .homemaker: (key, korean, english) = ("persona.type.homemaker", "주부", "Homemaker")
        case .other: (key, korean, english) = ("persona.type.other", "기타", "Other")
        case .unspecified: (key, korean, english) = ("persona.type.unspecified", "미설정", "Not Set")
        }
        return AppLanguage.localized(
            key,
            defaultValue: language == .korean ? korean : english,
            language: language,
            comment: "Persona lifestyle type shown during onboarding and in the saved profile."
        )
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
            return [
                AppLanguage.localized(
                    "persona.preset.student.university",
                    defaultValue: language == .korean ? "대학교 재학 중" : "University student",
                    language: language,
                    comment: "Suggested self-description chip for the student persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.student.graduate",
                    defaultValue: language == .korean ? "대학원 과정" : "Graduate student",
                    language: language,
                    comment: "Suggested self-description chip for the student persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.student.highSchool",
                    defaultValue: language == .korean ? "고등학생" : "High school student",
                    language: language,
                    comment: "Suggested self-description chip for the student persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.student.certification",
                    defaultValue: language == .korean ? "자격증 공부 중" : "Studying for a certification",
                    language: language,
                    comment: "Suggested self-description chip for the student persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.student.graduating",
                    defaultValue: language == .korean ? "졸업 예정" : "Graduating soon",
                    language: language,
                    comment: "Suggested self-description chip for the student persona; selecting it does not translate existing user text."
                )
            ]
        case .officeWorker:
            return [
                AppLanguage.localized(
                    "persona.preset.officeWorker.development",
                    defaultValue: language == .korean ? "IT/개발" : "IT / Development",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.officeWorker.marketing",
                    defaultValue: language == .korean ? "기획/마케팅" : "Planning / Marketing",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.officeWorker.sales",
                    defaultValue: language == .korean ? "영업/고객지원" : "Sales / Customer Support",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.officeWorker.finance",
                    defaultValue: language == .korean ? "재무/회계" : "Finance / Accounting",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.officeWorker.design",
                    defaultValue: language == .korean ? "디자인" : "Design",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.officeWorker.hr",
                    defaultValue: language == .korean ? "HR/교육" : "HR / Education",
                    language: language,
                    comment: "Suggested self-description chip for the officeWorker persona; selecting it does not translate existing user text."
                )
            ]
        case .freelancer:
            return [
                AppLanguage.localized(
                    "persona.preset.freelancer.development",
                    defaultValue: language == .korean ? "개발·프로그래밍" : "Development / Programming",
                    language: language,
                    comment: "Suggested self-description chip for the freelancer persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.freelancer.design",
                    defaultValue: language == .korean ? "디자인·영상" : "Design / Video",
                    language: language,
                    comment: "Suggested self-description chip for the freelancer persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.freelancer.writing",
                    defaultValue: language == .korean ? "번역·글쓰기" : "Translation / Writing",
                    language: language,
                    comment: "Suggested self-description chip for the freelancer persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.freelancer.consulting",
                    defaultValue: language == .korean ? "컨설팅" : "Consulting",
                    language: language,
                    comment: "Suggested self-description chip for the freelancer persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.freelancer.teaching",
                    defaultValue: language == .korean ? "강의·튜터링" : "Teaching / Tutoring",
                    language: language,
                    comment: "Suggested self-description chip for the freelancer persona; selecting it does not translate existing user text."
                )
            ]
        case .jobSeeker:
            return [
                AppLanguage.localized(
                    "persona.preset.jobSeeker.largeCompany",
                    defaultValue: language == .korean ? "대기업 준비" : "Preparing for a large company",
                    language: language,
                    comment: "Suggested self-description chip for the jobSeeker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.jobSeeker.publicService",
                    defaultValue: language == .korean ? "공기업·공무원" : "Preparing for public service",
                    language: language,
                    comment: "Suggested self-description chip for the jobSeeker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.jobSeeker.startup",
                    defaultValue: language == .korean ? "스타트업 지원 중" : "Applying to startups",
                    language: language,
                    comment: "Suggested self-description chip for the jobSeeker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.jobSeeker.abroad",
                    defaultValue: language == .korean ? "해외 취업 목표" : "Targeting work abroad",
                    language: language,
                    comment: "Suggested self-description chip for the jobSeeker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.jobSeeker.portfolio",
                    defaultValue: language == .korean ? "포트폴리오 준비 중" : "Preparing a portfolio",
                    language: language,
                    comment: "Suggested self-description chip for the jobSeeker persona; selecting it does not translate existing user text."
                )
            ]
        case .selfEmployed:
            return [
                AppLanguage.localized(
                    "persona.preset.selfEmployed.onlineShop",
                    defaultValue: language == .korean ? "온라인 쇼핑몰" : "Online shop",
                    language: language,
                    comment: "Suggested self-description chip for the selfEmployed persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.selfEmployed.restaurant",
                    defaultValue: language == .korean ? "음식점·카페" : "Restaurant / Cafe",
                    language: language,
                    comment: "Suggested self-description chip for the selfEmployed persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.selfEmployed.services",
                    defaultValue: language == .korean ? "서비스업" : "Services",
                    language: language,
                    comment: "Suggested self-description chip for the selfEmployed persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.selfEmployed.b2b",
                    defaultValue: language == .korean ? "B2B 사업" : "B2B business",
                    language: language,
                    comment: "Suggested self-description chip for the selfEmployed persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.selfEmployed.solo",
                    defaultValue: language == .korean ? "1인 기업" : "Solo business",
                    language: language,
                    comment: "Suggested self-description chip for the selfEmployed persona; selecting it does not translate existing user text."
                )
            ]
        case .homemaker:
            return [
                AppLanguage.localized(
                    "persona.preset.homemaker.childcare",
                    defaultValue: language == .korean ? "육아 중" : "Childcare",
                    language: language,
                    comment: "Suggested self-description chip for the homemaker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.homemaker.parenting",
                    defaultValue: language == .korean ? "학부모" : "Parenting",
                    language: language,
                    comment: "Suggested self-description chip for the homemaker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.homemaker.household",
                    defaultValue: language == .korean ? "가사 전담" : "Household work",
                    language: language,
                    comment: "Suggested self-description chip for the homemaker persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.homemaker.sideBusiness",
                    defaultValue: language == .korean ? "부업 병행 중" : "Running a side business",
                    language: language,
                    comment: "Suggested self-description chip for the homemaker persona; selecting it does not translate existing user text."
                )
            ]
        case .other:
            return [
                AppLanguage.localized(
                    "persona.preset.other.retired",
                    defaultValue: language == .korean ? "은퇴·휴식 중" : "Retired / Resting",
                    language: language,
                    comment: "Suggested self-description chip for the other persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.other.business",
                    defaultValue: language == .korean ? "창업 준비 중" : "Preparing a business",
                    language: language,
                    comment: "Suggested self-description chip for the other persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.other.multipleActivities",
                    defaultValue: language == .korean ? "다양한 활동 병행" : "Several activities",
                    language: language,
                    comment: "Suggested self-description chip for the other persona; selecting it does not translate existing user text."
                ),
                AppLanguage.localized(
                    "persona.preset.other.specialized",
                    defaultValue: language == .korean ? "특수 직종" : "Specialized occupation",
                    language: language,
                    comment: "Suggested self-description chip for the other persona; selecting it does not translate existing user text."
                )
            ]
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
