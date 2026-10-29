import SwiftUI

// MARK: - LegalDocument

enum LegalDocument: String, CaseIterable {
    case privacy = "privacy-policy"
    case terms   = "terms-of-service"

    var displayTitle: String {
        let (key, fallback): (String, String) = switch self {
        case .privacy: ("legal.privacy.title", "개인정보 처리방침")
        case .terms: ("legal.terms.title", "서비스 약관")
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Legal document title.")
    }

    var webURL: URL {
        switch self {
        case .privacy: URL(string: "https://jung-geun.github.io/SIFT/privacy-policy.html")!
        case .terms:   URL(string: "https://jung-geun.github.io/SIFT/terms-of-service.html")!
        }
    }

    var effectiveDate: String {
        let (key, fallback): (String, String) = switch self {
        case .privacy: ("legal.privacy.effectiveDate", "시행일: 2026년 7월 31일")
        case .terms: ("legal.terms.effectiveDate", "시행일: 2026년 10월 13일")
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Effective date for this legal document.")
    }
}
private func legalLocalized(_ source: String) -> String {
    AppLanguage.localized(
        "legal.text.\(source)",
        defaultValue: source,
        language: .current,
        comment: "Localized legal document content; preserve the Korean source meaning and structure."
    )
}

private func legalCopy(_ key: String, defaultValue: String) -> String {
    AppLanguage.localized(
        key,
        defaultValue: defaultValue,
        language: .current,
        comment: "Localized user-facing legal disclosure."
    )
}

// MARK: - LegalDocumentView

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.item) {
                legalHeader

                switch document {
                case .privacy: PrivacyPolicyContent()
                case .terms:   TermsOfServiceContent()
                }

                webLinkFooter
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, AppTheme.Spacing.section)
        }
        .navigationTitle(document.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .background(AppTheme.canvas)
    }

    private var legalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.displayTitle)
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    AppLanguage.localized("legal.developer", defaultValue: "개인 개발자 jung-geun", language: .current, comment: "Legal document developer attribution."),
                    systemImage: "person.circle"
                )
                Text(document.effectiveDate)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private var webLinkFooter: some View {
        Link(destination: document.webURL) {
            Label(
                AppLanguage.localized(
                    "legal.web.original",
                    defaultValue: "웹에서 원문 보기",
                    language: .current,
                    comment: "Link to the Korean legal document on the web."
                ),
                systemImage: "safari"
            )
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Shared Components
private struct LegalCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                Text(legalLocalized(title))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.headline)
            Divider()
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

private struct LegalSubTitle: View {
    let text: String
    var body: some View {
        Text(legalLocalized(text))
            .font(.headline)
    }
}

private struct LegalBody: View {
    let text: String
    var body: some View {
        Text(legalLocalized(text))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LegalBullets: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").font(.body).foregroundStyle(.secondary)
                    Text(legalLocalized(item)).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LegalLocalizedBullets: View {
    let items: [(key: String, defaultValue: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.key) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").font(.body).foregroundStyle(.secondary)
                    Text(legalCopy(item.key, defaultValue: item.defaultValue))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct InfoBox: View {
    let text: String
    var localizationKey: String? = nil
    private var localizedText: String {
        if let localizationKey { return legalCopy(localizationKey, defaultValue: text) }
        return legalLocalized(text)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.body)
            Text(localizedText).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.item)
        .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
    }
}

// MARK: - Table

nonisolated private struct LegalTableCell: Hashable {
    let key: String
    let defaultValue: String

    init(source: String) {
        key = "legal.text.\(source)"
        defaultValue = source
    }

    init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var localized: String {
        AppLanguage.localized(
            key,
            defaultValue: defaultValue,
            language: .current,
            comment: "Localized legal table cell."
        )
    }
}

private struct LegalTable: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let headers: [LegalTableCell]
    let rows: [[LegalTableCell]]

    init(headers: [String], rows: [[String]]) {
        self.headers = headers.map(LegalTableCell.init(source:))
        self.rows = rows.map { $0.map(LegalTableCell.init(source:)) }
    }

    init(headers: [String], cells: [[LegalTableCell]]) {
        self.headers = headers.map(LegalTableCell.init(source:))
        rows = cells
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            VStack(alignment: .leading, spacing: 4) {
                                if headers.indices.contains(column) {
                                    Text(headers[column].localized)
                                        .font(.headline)
                                }
                                Text(cell.localized)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                tableRow(cells: headers, isHeader: true, isEven: false)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    Divider()
                    tableRow(cells: row, isHeader: false, isEven: i.isMultiple(of: 2))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private func tableRow(cells: [LegalTableCell], isHeader: Bool, isEven: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                Text(cell.localized)
                    .font(isHeader ? .footnote.weight(.semibold) : .footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isHeader
                            ? AppTheme.neutralFill
                            : (isEven ? AppTheme.canvas : AppTheme.surface)
                    )
                if i < cells.count - 1 {
                    Rectangle().fill(Color(.separator)).frame(width: 0.5)
                }
            }
        }
    }
}

// MARK: - Third Party Card

private struct ThirdPartyCard: View {
    let name: String
    let provider: String
    let items: String
    let url: URL
    var itemsLocalizationKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            VStack(alignment: .leading, spacing: 3) {
                Text(legalLocalized(name)).font(.headline)
                Text(legalLocalized(provider)).font(.footnote).foregroundStyle(.secondary)
                Text(itemsLocalizationKey.map { legalCopy($0, defaultValue: items) } ?? legalLocalized(items)).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Link(destination: url) {
                Text(legalLocalized("방침 보기"))
                    .font(.body)
            }
        }
        .padding(AppTheme.Spacing.item)
        .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
    }
}

// MARK: - Privacy Policy

private struct PrivacyPolicyContent: View {
    var body: some View {
        LegalCard(number: 1, title: "수집하는 정보 및 목적") {
            LegalSubTitle(text: "1-1. 직접 입력 정보")
            LegalTable(
                headers: ["항목", "목적"],
                rows: [
                    ["할 일 제목·메모·마감일·태그·우선순위", "할 일 관리"],
                    ["페르소나 유형·설명", "AI 우선순위 개인화"],
                ]
            )

            LegalSubTitle(text: "1-2. 자동 생성·수집 정보")
            LegalTable(
                headers: ["항목", "수집 경위", "목적"],
                rows: [
                    ["Audit 이벤트 (등록·완료·삭제 시각·출처)", "할 일 처리 시 자동 기록", "행동 패턴 분석"],
                    ["행동 패턴·루틴 분석 결과 (주기·기록된 완료 시각·신뢰도)", "동의 후 기기 내 학습, 별도 동의·요청 시 OpenAI 서술", "사용자 확인 후 추천·일정 검토"],
                    ["앱 설정값 (AI 제공자, 이메일·캘린더 옵션 등)", "설정 저장", "기능 동작"],
                ]
            )

            LegalSubTitle(text: "1-3. 이메일 연동 (Gmail·Outlook, 선택, 명시적 동의 후 활성화)")
            LegalLocalizedBullets(items: [
                ("legal.text.수집 항목: 메시지 제목·발신자·스니펫·본문. Gmail OAuth는 gmail.modify 권한으로 열람·읽음 처리·휴지통 동작을 제공하며 IMAP 연결은 Gmail·Outlook 앱 비밀번호를 사용", "수집 항목: 메시지 제목·발신자·스니펫·본문. Gmail OAuth는 gmail.modify 권한으로 열람·읽음 처리·휴지통 동작을 제공하며 IMAP 연결은 Gmail·Outlook 앱 비밀번호를 사용"),
                ("legal.text.목적: 마감·일정 관련 이메일에서 할 일 자동 추출", "목적: 마감·일정 관련 이메일에서 할 일 자동 추출"),
                ("legal.privacy.email.storage", "메시지는 우선 기기에 저장합니다. 전체 iCloud 저장에 명시적으로 동의하면 메일 본문과 분석 결과도 같은 Apple 계정에서 저장·복원합니다. 이는 외부 AI로 데이터를 전송하는 동의가 아닙니다."),
                ("legal.privacy.email.credentials", "OAuth 토큰·IMAP 앱 비밀번호는 해당 제공자의 인증을 위해 Keychain에 저장합니다. 전체 iCloud 저장을 켜면 같은 Apple 계정의 기기에서 iCloud 키체인을 통해 복원할 수 있습니다."),
                ("legal.text.HTML 메일을 열면 HTTPS 이미지·스타일·글꼴을 자동으로 불러올 수 있으며, 해당 외부 호스트는 열람 시각과 기기 IP를 기록할 수 있음. JavaScript·양식·프레임·미디어·HTTP 리소스는 차단", "HTML 메일을 열면 HTTPS 이미지·스타일·글꼴을 자동으로 불러올 수 있으며, 해당 외부 호스트는 열람 시각과 기기 IP를 기록할 수 있음. JavaScript·양식·프레임·미디어·HTTP 리소스는 차단"),
                ("legal.text.자동 메일 후보·요약은 기기 내에서 처리합니다. 메일 전송 동의 후 상세에서 직접 외부 분석을 요청할 때만 선택한 메일의 제목·평문 본문을 OpenAI로 전송하며 원문과 로컬 요약은 보존합니다.", "자동 메일 후보·요약은 기기 내에서 처리합니다. 메일 전송 동의 후 상세에서 직접 외부 분석을 요청할 때만 선택한 메일의 제목·평문 본문을 OpenAI로 전송하며 원문과 로컬 요약은 보존합니다."),
            ])

            LegalSubTitle(text: "1-4. 캘린더 연동 (선택, 시스템 권한 허용 후 활성화)")
            LegalBullets([
                "수집 항목: 캘린더 이벤트 (EventKit, 읽기·쓰기)",
                "목적: 마감일 있는 할 일을 시스템 캘린더에 자동 등록, 캘린더 일정을 할 일로 가져오기",
            ])
            LegalLocalizedBullets(items: [
                ("legal.privacy.calendar.remoteBoundary", "처리 위치: 기기 내 EventKit. OpenAI로 보내는 별도 캘린더 이벤트 컨텍스트는 제목을 Busy로 가리고 시작·종료 시각만 포함합니다. 다만 외부 캘린더에서 가져와 진행중으로 확정한 할 일은 일반 할 일 공유 동의 범위에 포함되어 제목·메모가 전송될 수 있습니다."),
                ("calendar.settings.autoRegisterFooter", "선택한 출처의 마감이 있는 진행 중 할 일만 자동으로 등록합니다. 검토 대기·캘린더 출처 할 일과 건강 루틴은 제외됩니다. 긴급·최우선 할 일도 이 동의가 필요합니다. 캘린더 접근 권한과 쓰기 가능한 등록 대상이 필요하며, 자동 등록을 꺼도 기존 일정은 삭제되지 않습니다."),
                ("legal.privacy.calendar.completionActions", "'일정 유지'는 일정을 그대로 둡니다. 기본값인 '알람만 끄기'는 일정은 남기고 알람만 끕니다. '이벤트 삭제'는 일정을 삭제합니다. 이 처리는 SIFT가 해당 할 일을 위해 만든 일정에만 적용되며, 외부 캘린더의 원본 일정에는 적용되지 않습니다."),
                ("calendar.destination.footer", "일정을 내보내기 전에 쓰기 가능한 캘린더를 선택하세요. 이 선택은 이 기기에만 저장됩니다. 캘린더는 자동으로 선택되지 않으며 시스템 기본값도 명시적으로 선택해야 합니다. 위 항목을 열어 캘린더를 선택하거나 사용할 수 없는 대상을 바꾸세요."),
            ])

            LegalSubTitle(text: "1-5. 할 일 우선순위 정렬 AI")
            LegalLocalizedBullets(items: [
                ("legal.privacy.ai.default", "기본값은 Apple Intelligence입니다. 지원하지 않는 기기에서는 베타 기능에서 로컬 언어 모델을 직접 다운로드하고 사용을 허용할 수 있습니다. 사용 가능한 모델이 없으면 규칙 기반으로 처리합니다."),
            ])
            LegalBullets([
                "OpenAI 제공자 활성화·ChatGPT 계정의 구독 사용 권한·데이터별 전송 동의가 있어야 외부 분석을 실행합니다. 할 일·메일·루틴·페르소나 동의는 기기별로 분리합니다.",
                "기초 요청은 gpt-6-luna, 메일 중요 내용·루틴·페르소나의 직접 고급 재요청은 gpt-6.1-sol입니다. 계정에 모델이 없으면 다른 모델로 몰래 대체하지 않습니다.",
                "자동 할 일 정렬에서 메일·회의 출처 내용은 항상 기기 내 규칙으로 처리합니다. 회의 음성·전사·화자 정보는 OpenAI로 보내지 않습니다.",
                "OpenAI 요청은 공개 Responses API에서 store:false·stream:true로 실행하며 완료된 응답만 사용합니다. 이는 제공자의 모든 서버 보관이 0일이라는 보장이 아니며 OpenAI 데이터 정책이 적용됩니다.",
            ])
            LegalLocalizedBullets(items: [
                ("openai.connection.testExplanation", "테스트는 저장된 앱 데이터 대신 고정 메시지만 전송하며 구독 한도를 사용합니다. 제공자 활성화나 데이터별 전송 동의 없이 실행할 수 있습니다."),
            ])

            Text(legalCopy(
                "legal.privacy.diagnostics.title",
                defaultValue: "1-6. 사용자 동의형 오류 진단 (선택)"
            ))
            .font(.subheadline.bold())
            LegalLocalizedBullets(items: [
                ("legal.privacy.diagnostics.collected", "수집 항목: 오류 발생 시각·반복 횟수, 소스 파일·줄 번호·함수, 오류 도메인·코드·유형·메시지(파일 경로와 이메일 주소 제거, 300자 제한)와 하위 오류 사슬, 오류 당시 앱 버전·빌드·운영체제 버전·빌드·앱 실행 상태·기능 설정·언어·기기 언어 설정에서 파생한 국가/지역·시간대·UTC 오프셋·달력·24시간 설정, 보고서 준비 시점의 기기 모델 식별자·메모리·저장 공간·화면 크기·프로세서 수·언어·지역·시간대, 앱이 남긴 최근 오류 로그(최대 300건, 30분), Apple이 나중에 제공할 수 있는 충돌·멈춤·메모리 종료 진단. 국가/지역은 실제 위치가 아닌 기기 언어 설정에서 파생합니다."),
                ("legal.privacy.diagnostics.excluded", "제외 항목: 실제 위치·GPS 위치, 기기 이름, 음성 녹음, 전사문, 할 일, 이메일 본문·제목·주소, 페르소나, 계정 식별자, 인증 토큰"),
                ("legal.privacy.diagnostics.storage", "명시적으로 허용한 경우에만 기기 로컬의 백업 제외·파일 보호 저장소에 제한된 개수로 보관하며, 동의 철회 또는 삭제 시 즉시 제거"),
                ("feedback.legal.transmission", "오류 보고·기능 제안은 입력 내용과 앱·OS·언어 정보를 검토하고 직접 승인한 경우에만 HTTPS로 Cloudflare의 SIFT 비공개 접수함에 전송합니다. 진단은 별도로 포함을 선택한 경우에만 첨부합니다. 계정·메일 연결 없이 운영자만 확인하며, 접수 내용·운영 메모는 30일 후 정기 삭제합니다. Cloudflare는 네트워크 정보를 처리하고, 앱은 원본 IP 대신 일별 HMAC 제한 키를 최대 2일 보관합니다. 개별 답변은 제공하지 않습니다."),
                ("legal.privacy.diagnostics.deliveryLimit", "Apple 시스템 진단은 지연되거나 제공되지 않을 수 있고 모든 강제 종료를 포착하지 않음"),
            ])

            Text(legalCopy("legal.privacy.audioImport.title", defaultValue: "1-7. 로컬 오디오 가져오기 (선택)"))
                .font(.subheadline.bold())
            LegalLocalizedBullets(items: [
                ("legal.privacy.audioImport.storage", "사용자가 선택한 오디오를 읽기 전용으로 열어 기기 내 회의 음성으로 변환·저장합니다. 원본은 바꾸지 않고 기본 파일명만 기록합니다. 전체 iCloud 저장에 명시적으로 동의하면 음성 복사본과 전사문을 같은 Apple 계정에서 저장·복원합니다. 외부 AI로 보내지는 않습니다. 회의 삭제 시 앱 안의 복사본을 삭제합니다."),
                ("legal.privacy.audioImport.processing", "가져오기는 마이크 권한이나 자동 모델 다운로드를 시작하지 않습니다. 파일 제공자가 원본을 내려받는 경우 해당 제공자의 정책이 적용됩니다. 오프라인 모델 미설치나 전사 실패 후에도 가져온 음성을 보존해 재시도할 수 있습니다."),
            ])

            Text(legalCopy("health.title", defaultValue: "건강·운동 기록"))
                .font(.subheadline.bold())
                .accessibilityIdentifier("privacy.healthHistory")
            LegalLocalizedBullets(items: [
                ("health.history.disclosure", "운동 또는 복약 기록을 각 항목별로 최근 최대 90일까지만 읽습니다. 승인한 출처만 루틴을 제안하며, 직접 검토하고 확정하기 전에는 활성화되지 않습니다."),
                ("health.privacy.local", "원본 기록과 루틴 후보는 백업에서 제외된 보호 저장소에 기기 내에서만 보관됩니다. 동기화하거나 OpenAI로 보내지 않습니다. 이 기능은 HealthKit·캘린더에 쓰거나 알림을 예약하지 않습니다."),
                ("health.autoCreate.disclosure", "생성된 할 일의 제목과 일정은 건강 정보를 드러낼 수 있습니다. 건강 데이터·루틴 후보·건강 기록에서 생성된 할 일은 iCloud에서 제외합니다. 다만 암호화된 Firebase 스냅샷을 수동으로 내보내면 생성된 할 일은 포함됩니다. 생성하려면 승인한 출처, 직접 확정하고 활성화한 루틴, 이 별도의 동의가 모두 필요합니다. HealthKit·캘린더 쓰기나 알림은 실행하지 않습니다. 허용 후 새로고침하여 다음 미래 일정의 할 일을 생성하세요."),
                ("health.medication.safety", "복약 기록은 처방전이나 처방 일정의 증거가 아닙니다. 본인이 의료진에게 안내받은 일정과 이 알림을 대조해 확인하세요. 이 기능은 처방·용량 변경을 권하지 않으며 복용 누락이나 보충 복용에 대한 조언을 제공하지 않습니다."),
            ])
            Text(legalCopy("health.erase", defaultValue: "로컬 건강 기록 지우기"))
                .font(.subheadline.bold())
            LegalLocalizedBullets(items: [
                ("health.erase.disclosure", "지우면 모든 항목의 연결과 자동 생성 동의를 중지하고 로컬 원본 기록·출처 승인·루틴 후보를 삭제합니다. 이미 생성된 할 일은 남습니다. 중복 방지를 위해 비임상 처리 일정 표식은 유지합니다. HealthKit 기록과 iOS 건강 권한은 변경하지 않습니다."),
            ])
            Text(legalCopy("health.reset", defaultValue: "모든 건강 데이터 및 중복 방지 기록 초기화"))
                .font(.subheadline.bold())
            LegalLocalizedBullets(items: [
                ("health.reset.warning", "연결과 자동 생성 동의를 중지하고 로컬 건강 기록·후보·비임상 중복 방지 표식을 모두 삭제합니다. 이미 생성된 할 일은 남습니다. 다시 연결하고 출처를 승인한 뒤 루틴을 확정하고 생성을 허용하면, 이전 할 일을 완료하거나 삭제했더라도 이미 처리한 일정이 다시 생성될 수 있습니다."),
            ])

            Text(legalCopy("legal.privacy.ads.title", defaultValue: "1-11. Google AdMob 광고 및 동의"))
                .font(.subheadline.bold())
            LegalLocalizedBullets(items: [
                ("legal.privacy.ads.requests", "광고를 제공하는 버전에 적용됩니다. 비개인 맞춤 광고를 요청하고 게시자 퍼스트 파티 ID를 비활성화합니다. ATT 추적 허용 팝업이나 IDFA 접근 권한은 요청하지 않지만, 이것이 SDK의 데이터 수집이나 추적 가능성이 없다는 뜻은 아닙니다."),
                ("legal.privacy.ads.consent", "광고 요청 전 Google UMP로 동의 상태를 확인하고 필요한 안내·동의 양식을 표시합니다. UMP가 광고 요청을 허용하는 경우에만 요청하며, 필요한 경우 설정에서 광고 개인정보 옵션을 다시 열어 선택을 변경할 수 있습니다."),
                ("legal.privacy.ads.data", "Google 광고·동의 SDK는 IP 주소와 그로부터 추정한 대략적 위치, 앱·기기 식별자, 광고 조회·클릭 등 상호작용, 충돌·진단·성능 정보를 광고 제공·부정행위 방지·측정 및 동의 관리에 처리할 수 있습니다. 일부 식별자·광고 및 상호작용 정보는 사용자와 연결되거나 추적에 사용될 수 있습니다. 비개인 맞춤 광고도 완전 익명이나 수집 없음이 아닙니다."),
                ("legal.privacy.ads.boundary", "SIFT는 할 일·이메일·캘린더·건강·음성·전사·페르소나 내용을 광고 타기팅에 전달하지 않습니다. HealthKit 데이터는 광고에 절대 사용하지 않으며 광고 SDK로 보내지 않습니다. SDK의 진단 처리는 별도 선택형 SIFT 오류 보고와 구분됩니다."),
                ("legal.privacy.ads.controls", "Google의 처리·보관·삭제에는 Google 정책과 적용되는 UMP 선택이 따릅니다. 앱 데이터나 로컬 진단을 삭제해도 Google이 이미 처리한 정보가 즉시 삭제되는 것은 아닙니다. Google 정책에서 개인정보 관리·삭제 방법을 확인하세요."),
            ])
            Link(legalCopy("legal.privacy.ads.policyLink", defaultValue: "Google 광고 데이터 처리 방침"), destination: URL(string: "https://policies.google.com/technologies/partner-sites")!)
            Link(legalCopy("legal.privacy.ads.disclosureLink", defaultValue: "Google SDK 데이터 공개 안내"), destination: URL(string: "https://developers.google.com/admob/ios/privacy/data-disclosure")!)
        }

        LegalCard(number: 2, title: "정보 저장 위치") {
            LegalTable(
                headers: ["저장소", "저장 항목"],
                cells: [
                    [
                        LegalTableCell(key: "legal.privacy.storage.local", defaultValue: "기기 내 앱 저장소"),
                        LegalTableCell(key: "legal.privacy.storage.localDetail", defaultValue: "앱 데이터는 기기에서 계속 사용할 수 있습니다. iCloud 저장을 꺼도 로컬 데이터와 다른 기기의 데이터는 삭제하지 않습니다."),
                    ],
                    [
                        LegalTableCell(key: "legal.privacy.storage.cloud", defaultValue: "iCloud 비공개 저장소 (선택)"),
                        LegalTableCell(key: "legal.privacy.storage.cloudDetail", defaultValue: "할 일·페르소나·감사/행동 기록·메일 본문/분석·회의 음성/전사·화자/편집·루틴·학습 사전·설정 — 전체 범위에 동의한 경우에만 저장합니다."),
                    ],
                    [
                        LegalTableCell(key: "legal.privacy.storage.keychain", defaultValue: "Keychain / iCloud 키체인 (선택)"),
                        LegalTableCell(key: "legal.privacy.storage.keychainDetail", defaultValue: "이메일 OAuth 토큰·IMAP 앱 비밀번호·ChatGPT 연결 정보. 다른 기기에서 복원하려면 iCloud 키체인과 같은 Apple 계정이 필요합니다."),
                    ],
                    [
                        LegalTableCell(key: "legal.privacy.storage.excluded", defaultValue: "iCloud 저장 제외"),
                        LegalTableCell(key: "legal.privacy.storage.excludedDetail", defaultValue: "건강 데이터와 건강 기록에서 생성된 할 일·OS 권한·기기별 승인·재다운로드 가능한 모델 파일. 권한 확인과 모델 설치는 각 기기에서 진행합니다."),
                    ],
                    [
                        LegalTableCell(key: "legal.privacy.diagnostics.storeLabel", defaultValue: "기기 내 로컬 진단 저장소 (선택)"),
                        LegalTableCell(key: "legal.privacy.diagnostics.storeDetail", defaultValue: "동의한 오류 시각·소스 파일·줄 번호·함수·코드·유형·메시지, 오류 당시 OS·언어/지역·실행 상태·설정 스냅샷, 보고서 준비 시점의 기기 사양·언어/지역 설정, 최근 앱 오류 로그 및 제한된 Apple 시스템 진단 — iCloud·백업 제외"),
                    ],
                ]
            )
            InfoBox(text: "전체 iCloud 저장은 선택 사항이며 확대된 범위에 명시적으로 동의해야 합니다. 저장된 권한 내역만으로 새 기기에 권한을 부여하지 않습니다. 외부 AI 전송·메일 백그라운드 접근·캘린더 선택은 해당 기기에서 확인하며 복원된 메일 작업은 자동 재실행하지 않습니다. 데이터는 같은 Apple 계정에 연결되며 Apple의 전송이 끝난 뒤 다른 기기에 적용됩니다. 연결 정보 복원에는 iCloud 키체인도 필요합니다. 건강정보·OS 권한·모델 파일은 제외합니다. 저장을 꺼도 로컬 데이터와 다른 기기의 데이터는 삭제하지 않습니다.", localizationKey: "legal.privacy.openai.syncBoundary")
                .padding(.top, 6)
            InfoBox(text: "이 연결의 갱신은 원래 연결한 기기에서 처리합니다. 해당 기기의 SIFT → 설정 → AI → OpenAI · ChatGPT에서 모델 목록을 새로고침한 뒤 iCloud 키체인 동기화를 기다리거나, 이 기기에서 다시 연결하세요.", localizationKey: "error.openai.connection.refreshOwnerRequired")
                .padding(.top, 6)
        }

        LegalCard(number: 3, title: "제3자 처리위탁 및 데이터 국외 이전") {
            VStack(spacing: 6) {
                ThirdPartyCard(name: "Apple Inc.", provider: "미국 외 다수", items: "선택적 전체 iCloud 저장: 할 일·메일·회의 녹음/전사·루틴·학습 사전·설정·연결 정보. 건강정보·OS 권한·재다운로드 가능한 모델 파일은 제외합니다.", url: URL(string: "https://www.apple.com/legal/privacy/")!, itemsLocalizationKey: "legal.privacy.apple.storage")
                ThirdPartyCard(name: "Google LLC", provider: "미국 외 다수", items: "Gmail 메시지 조회·사용자가 실행한 읽음/휴지통 반영 / OAuth 또는 IMAP 인증", url: URL(string: "https://policies.google.com/privacy")!)
                ThirdPartyCard(name: "Google LLC", provider: "미국 외 다수", items: "광고 제공 버전: IP·대략적 위치·앱/기기 식별자·광고 상호작용·진단/성능 정보 — 광고 제공·부정행위 방지·측정·동의 관리", url: URL(string: "https://policies.google.com/privacy")!, itemsLocalizationKey: "legal.privacy.ads.recipient")
                ThirdPartyCard(name: "Microsoft Corporation", provider: "미국 외 다수", items: "Outlook IMAP 인증·메일 조회·사용자가 실행한 읽음/휴지통 반영", url: URL(string: "https://privacy.microsoft.com/privacystatement")!)
                ThirdPartyCard(name: "OpenAI", provider: "미국 외 다수", items: "ChatGPT 로그인·선택한 구독 사용 및 데이터별로 동의한 외부 분석", url: URL(string: "https://openai.com/policies/privacy-policy/")!)
            }
        }

        LegalCard(number: 4, title: "Google API Services 사용자 데이터 정책") {
            LegalBody(text: "SIFT의 Google API로부터 받은 정보의 사용 및 다른 앱·서비스로의 전송은, Limited Use 요건을 포함한 Google API Services User Data Policy를 준수합니다.")
            LegalBullets([
                "Gmail 데이터는 앱 내 메일 후보 판단·요약·할 일 추출에 사용",
                "메일 본문의 외부 분석은 별도 동의와 선택한 메일에 대한 직접 요청이 있어야 하며, 자동 수집·요약·할 일 정렬은 기기 내에서 처리합니다.",
                "광고 또는 제3자 마케팅 목적으로 사용하지 않음",
                "SIFT는 이메일을 모델 학습용 데이터셋으로 수집·제공하지 않습니다. 사용자가 동의해 전송한 API 데이터에는 OpenAI의 데이터 처리·보관 정책이 적용됩니다.",
            ])
            .padding(.top, 4)
            Link(destination: URL(string: "https://developers.google.com/terms/api-services-user-data-policy")!) {
                Label("Google API Services User Data Policy", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .padding(.top, 4)
        }

        LegalCard(number: 5, title: "정보 보관 및 파기") {
            LegalTable(
                headers: ["정보", "보관 기간", "파기 방법"],
                cells: [
                    ["할 일·페르소나 등 앱 데이터", "앱 삭제 또는 직접 삭제 시까지", "기기 데이터 삭제 / iCloud 컨테이너 삭제"].map(LegalTableCell.init(source:)),
                    ["이메일 메시지 (로컬)", "연동 해제 시 삭제 가능", "앱 데이터 삭제"].map(LegalTableCell.init(source:)),
                    ["이메일 OAuth 토큰·IMAP 앱 비밀번호", "연동 해제 시 즉시 삭제", "Keychain SecItemDelete"].map(LegalTableCell.init(source:)),
                    ["iCloud 데이터", "iCloud.com에서 직접 삭제 시", "Apple CloudKit 삭제"].map(LegalTableCell.init(source:)),
                    ["루틴 근거·추천 피드백", "사용자가 루틴 기록을 삭제할 때까지", "설정 → 루틴 학습·추천 → 모두 삭제"].map(LegalTableCell.init(source:)),
                    ["OpenAI 토큰·계정 연결 기록", "연결 해제 시 토큰 제거, 계정 매핑은 재연결용 유지", "OpenAI 설정 → 연결 해제 또는 연결 기록 모두 삭제"].map(LegalTableCell.init(source:)),
                    [
                        LegalTableCell(key: "legal.privacy.diagnostics.retentionLabel", defaultValue: "사용자 동의형 로컬 진단 로그"),
                        LegalTableCell(key: "legal.privacy.diagnostics.retentionCondition", defaultValue: "동의 철회 또는 앱에서 삭제 시"),
                        LegalTableCell(key: "legal.privacy.diagnostics.retentionDeletion", defaultValue: "기기 로컬 진단 저장소 삭제"),
                    ],
                ]
            )
        }

        LegalCard(number: 6, title: "이용자의 권리 및 행사 방법") {
            LegalBullets([
                "할 일·페르소나 삭제: 앱 내에서 직접 삭제",
                "이메일 연동 해제: 설정 → 이메일 연동 → 연결 해제 (OAuth 토큰·IMAP 앱 비밀번호 삭제)",
                "캘린더 권한 철회: iOS 설정 → 개인정보 보호 → 캘린더 → SIFT 비활성화",
                "iCloud 동기화 해제: 설정 → iCloud 동기화 → 비활성화",
                "루틴·근거·추천 피드백 삭제: 설정 → 루틴 학습·추천 → 모두 삭제 (이미 승인한 할 일은 별도 삭제)",
                "OpenAI 연결 해제는 토큰을 지우고 원격 세션 철회를 시도합니다. 원격 철회가 확인되지 않으면 ChatGPT 설정에서 직접 연결을 끊을 수 있습니다. 계정 매핑까지 지우려면 연결 기록 모두 삭제를 사용하세요.",
                "모든 데이터 삭제: 앱 삭제 시 로컬 전체 삭제 (iCloud 데이터는 iCloud.com에서 별도 삭제)",
            ])
            LegalBody(text: "정보 열람·정정·삭제·처리정지 요청: pieroot.02@gmail.com (영업일 5일 이내 처리)")
                .padding(.top, 8)
        }

        LegalCard(number: 7, title: "데이터 보안") {
            LegalLocalizedBullets(items: [
                ("legal.privacy.openai.credentials", "이메일 OAuth 토큰·IMAP 앱 비밀번호·ChatGPT 등록/OAuth 토큰은 Keychain에 저장합니다. 전체 iCloud 저장에 동의하면 iCloud 키체인을 통해 연결 정보를 복원할 수 있습니다. 기기 host ID와 로컬 승인은 이전하지 않으며 모델은 기기마다 설치해야 합니다."),
            ])
            LegalLocalizedBullets(items: [
                ("legal.privacy.routines.security", "루틴은 보호된 로컬 파일에 원자적으로 저장합니다. 전체 iCloud 저장에 동의하면 루틴·근거·피드백·수락 예약도 동기화합니다. 외부 AI 전송은 각 기기에서 기본 꺼짐이며 OpenAI 인증 정보·요청·응답·원문은 진단 로그에 기록하지 않습니다."),
            ])
            LegalBullets([
                "iCloud 데이터는 Apple의 전송 중·저장 시 암호화 인프라 이용",
                "앱은 비보안 암호화를 사용하지 않음 (ITSAppUsesNonExemptEncryption = NO)",
            ])
        }

        LegalCard(number: 8, title: "아동 개인정보") {
            LegalBody(text: "본 앱은 만 14세 미만 아동을 대상으로 하지 않으며, 의도적으로 아동의 개인정보를 수집하지 않습니다. 아동의 정보가 수집된 사실을 인지하면 즉시 삭제합니다.")
        }

        LegalCard(number: 9, title: "방침 변경") {
            LegalBody(text: "본 방침이 변경될 경우, 앱 업데이트 노트 또는 앱 내 알림을 통해 최소 7일 전에 고지합니다. 변경된 방침의 시행일 이후 앱을 계속 사용하면 변경 사항에 동의한 것으로 간주합니다.")
        }

        LegalCard(number: 10, title: "문의") {
            LegalBullets([
                "이메일: pieroot.02@gmail.com",
                "응대 기간: 영업일 기준 5일 이내",
            ])
        }
    }
}

// MARK: - Terms of Service

private struct TermsOfServiceContent: View {
    var body: some View {
        LegalCard(number: 1, title: "서비스 정의") {
            LegalBody(text: "SIFT는 이메일·캘린더·수동 할 일을 기본적으로 기기 내에서 분류·정리하는 개인 생산성 앱입니다. 별도 동의 후 OpenAI·ChatGPT 구독으로 외부 분석을 요청할 수 있습니다. 구독 연결은 로컬 개인 프로젝트·오픈소스와 승인된 앱 범위에 제공되며, 유료·원격 호스팅 배포에는 OpenAI 승인이 필요합니다. 일반 배포 승인 여부를 보장하지 않습니다.")
        }

        LegalCard(number: 2, title: "이용 조건") {
            LegalLocalizedBullets(items: [
                ("legal.terms.use.allowed", "본 서비스는 개인적·상업적 목적으로 이용할 수 있습니다."),
                ("legal.terms.use.licenseConditions", "SIFT 자체 소스코드·문서·프로젝트 자산은 Apache License 2.0에 따라 수정·재배포·수익화할 수 있습니다. 별도 허가는 필요하지 않으며, 라이선스 사본 제공·저작권 및 관련 NOTICE 유지·변경 파일 표시 등 라이선스 조건을 준수해야 합니다."),
                ("legal.terms.use.lawful", "법령이나 타인의 권리를 침해하는 방식으로 사용할 수 없습니다."),
            ])
        }

        LegalCard(number: 3, title: "제3자 서비스") {
            LegalBody(text: "서비스는 아래 제3자 서비스와 연동됩니다. 각 서비스의 독자적인 이용약관 및 개인정보 처리방침이 함께 적용됩니다.")
            VStack(spacing: 6) {
                ThirdPartyCard(name: "Gmail API", provider: "Google LLC", items: "메일 조회·사용자가 실행한 읽음/휴지통 반영", url: URL(string: "https://policies.google.com/terms")!)
                ThirdPartyCard(name: "iCloud / CloudKit", provider: "Apple Inc.", items: "선택적 전체 iCloud 저장: 할 일·메일·회의 녹음/전사·루틴·학습 사전·설정·연결 정보. 건강정보·OS 권한·재다운로드 가능한 모델 파일은 제외합니다.", url: URL(string: "https://www.apple.com/legal/internet-services/icloud/")!, itemsLocalizationKey: "legal.privacy.apple.storage")
                ThirdPartyCard(name: "Outlook IMAP", provider: "Microsoft Corporation", items: "Outlook IMAP 인증·메일 조회·사용자가 실행한 읽음/휴지통 반영", url: URL(string: "https://www.microsoft.com/servicesagreement")!)
                ThirdPartyCard(name: "OpenAI · ChatGPT", provider: "OpenAI", items: "선택적 계정 연결·구독 사용·명시적 외부 분석", url: URL(string: "https://openai.com/policies/terms-of-use/")!)
            }
            .padding(.top, 6)
            LegalBody(text: "제3자 서비스 이용으로 발생하는 책임은 해당 제공사와의 관계에서 이용자가 직접 부담합니다.")
                .padding(.top, 8)
        }
        
        LegalCard(number: 4, title: "서비스 내용 및 가용성") {
            LegalBullets([
                "서비스는 현재 상태 그대로(as-is) 무료로 제공됩니다.",
                "운영자는 사전 통보 없이 기능을 변경·중단·종료할 수 있습니다.",
                "온디바이스 AI와 OpenAI 분석의 가용성은 OS·기기 상태, 계정 권한·구독 한도·모델 제공 여부에 따라 달라집니다. 자동 고급 모델 재호출은 하지 않습니다.",
                "iOS 26.5 이상, 특정 기기 성능을 요구하는 온디바이스 AI 기능은 구형 기기에서 이용이 제한될 수 있습니다.",
            ])
        }

        LegalCard(number: 5, title: "AI 분석 결과 면책") {
            LegalBody(text: "서비스가 이메일·캘린더에서 자동 추출하거나 AI가 생성한 할 일·우선순위·요약은 참고용입니다.")
            LegalBullets([
                "중요한 마감·일정은 반드시 직접 확인하시기 바랍니다.",
                "AI 분석의 부정확성·누락으로 인한 손해에 대해 운영자는 책임을 지지 않습니다.",
            ])
            .padding(.top, 4)
        }

        LegalCard(number: 6, title: "데이터 손실 및 동기화") {
            LegalBullets([
                "앱 삭제, 기기 초기화, iCloud 오류 등으로 인한 데이터 손실에 대해 운영자는 책임을 지지 않습니다.",
                "중요한 데이터는 별도로 백업하시기 바랍니다.",
                "iCloud 동기화 충돌·지연은 Apple 인프라에 의존하므로 운영자가 보장할 수 없습니다.",
            ])
        }

        LegalCard(number: 7, title: "지식재산권") {
            LegalLocalizedBullets(items: [
                ("legal.terms.ownership.project", "SIFT 자체 소스코드·문서·프로젝트 자산의 저작권은 해당 저작권자에게 있으며 Apache License 2.0의 이용 권한이 부여됩니다. 이 약관은 해당 라이선스의 권한을 제한하지 않습니다. 프로젝트의 LICENSE와 NOTICE를 확인하세요."),
                ("legal.terms.ownership.thirdParty", "제3자 라이브러리·모델 가중치·아이콘 등은 각 저작권자의 별도 라이선스를 따르며, SIFT의 Apache-2.0 전환으로 재라이선스되지 않습니다. Apple·Google·Microsoft·OpenAI 서비스의 이용 권한도 각 제공사의 조건을 따릅니다."),
                ("legal.terms.ownership.trademarks", "Apache License 2.0은 SIFT 또는 제3자의 상표 사용 권한이나 공식 앱·운영자와의 제휴를 보장하지 않습니다."),
                ("legal.terms.ownership.userData", "이용자가 앱에 입력한 데이터(할 일·메모 등)는 이용자 본인의 소유이며, 운영자는 이를 마케팅·학습 등 목적으로 사용하지 않습니다."),
            ])
        }

        LegalCard(number: 8, title: "책임 제한") {
            LegalBody(text: "관련 법령이 허용하는 최대 범위에서, 운영자는 서비스 이용으로 인한 간접적·우발적·결과적 손해에 대해 책임을 지지 않습니다. 운영자의 최대 배상 책임은 이용자가 서비스에 지불한 금액(무료 서비스의 경우 0원)으로 제한됩니다.")
        }

        LegalCard(number: 9, title: "약관 변경") {
            LegalBody(text: "약관이 변경될 경우 앱 업데이트 노트 또는 앱 내 알림을 통해 최소 7일 전에 고지합니다. 변경된 약관의 시행일 이후 서비스를 계속 사용하면 변경 사항에 동의한 것으로 간주합니다.")
        }

        LegalCard(number: 10, title: "준거법 및 분쟁 해결") {
            LegalBody(text: "본 약관은 대한민국 법률에 따라 해석·적용됩니다. 서비스 이용과 관련된 분쟁은 운영자의 주소지를 관할하는 법원을 1심 관할 법원으로 합니다.")
        }

        LegalCard(number: 11, title: "문의") {
            LegalBullets([
                "이메일: pieroot.02@gmail.com",
                "응대 기간: 영업일 기준 5일 이내",
            ])
        }
    }
}

// MARK: - Preview

#Preview("개인정보 처리방침") {
    NavigationStack { LegalDocumentView(document: .privacy) }
}

#Preview("서비스 약관") {
    NavigationStack { LegalDocumentView(document: .terms) }
}
