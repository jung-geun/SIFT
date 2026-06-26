import SwiftUI

// MARK: - LegalDocument

enum LegalDocument: String, CaseIterable {
    case privacy = "privacy-policy"
    case terms   = "terms-of-service"

    var displayTitle: String {
        switch self {
        case .privacy: "개인정보 처리방침"
        case .terms:   "서비스 약관"
        }
    }

    var webURL: URL {
        switch self {
        case .privacy: URL(string: "https://jung-geun.github.io/SIFT/privacy-policy.html")!
        case .terms:   URL(string: "https://jung-geun.github.io/SIFT/terms-of-service.html")!
        }
    }
}

// MARK: - LegalDocumentView

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                legalHeader

                switch document {
                case .privacy: PrivacyPolicyContent()
                case .terms:   TermsOfServiceContent()
                }

                webLinkFooter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .navigationTitle(document.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private var legalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.displayTitle)
                .font(.title2.bold())
            HStack {
                Label("개인 개발자 jung-geun", systemImage: "person.circle")
                Spacer()
                Text("시행일: 2026년 6월 23일")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var webLinkFooter: some View {
        Link(destination: document.webURL) {
            Label("웹에서 원문 보기", systemImage: "safari")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
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
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
                Text(title)
                    .font(.headline)
            }
            Divider()
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LegalSubTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.bold())
            .padding(.top, 6)
    }
}

private struct LegalBody: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
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
                    Text("•").font(.subheadline).foregroundStyle(.secondary)
                    Text(item).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct InfoBox: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.subheadline)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Table

private struct LegalTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            tableRow(cells: headers, isHeader: true, isEven: false)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Divider()
                tableRow(cells: row, isHeader: false, isEven: i.isMultiple(of: 2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
    }

    @ViewBuilder
    private func tableRow(cells: [String], isHeader: Bool, isEven: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                Text(cell)
                    .font(isHeader ? .caption.bold() : .caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isHeader
                            ? Color.accentColor.opacity(0.15)
                            : (isEven ? Color(.systemGroupedBackground) : Color(.secondarySystemGroupedBackground))
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

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.bold())
                Text(provider).font(.caption2).foregroundStyle(.secondary)
                Text(items).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Link(destination: url) {
                Text("방침 보기")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
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
                    ["행동 패턴 분석 결과 (시간대·태그별 완료율)", "온디바이스 AI 분석", "AI 우선순위 조정"],
                    ["앱 설정값 (AI 제공자, 이메일·캘린더 옵션 등)", "설정 저장", "기능 동작"],
                ]
            )

            LegalSubTitle(text: "1-3. Gmail 연동 (선택, 명시적 동의 후 활성화)")
            LegalBullets([
                "수집 항목: 메시지 제목·발신자·스니펫·본문 (읽기 전용, gmail.readonly)",
                "목적: 마감·일정 관련 이메일에서 할 일 자동 추출",
                "저장 위치: 기기 내 별도 로컬 전용 저장소 — iCloud 동기화 및 외부 전송 완전 차단",
                "OAuth 토큰: 기기 Keychain에만 저장",
            ])

            LegalSubTitle(text: "1-4. 캘린더 연동 (선택, 시스템 권한 허용 후 활성화)")
            LegalBullets([
                "수집 항목: 캘린더 이벤트 (EventKit, 읽기·쓰기)",
                "목적: 마감일 있는 할 일을 시스템 캘린더에 자동 등록, 캘린더 일정을 할 일로 가져오기",
                "처리 위치: 기기 내 EventKit 프레임워크 (앱 외부 서버로 전송하지 않음)",
            ])

            LegalSubTitle(text: "1-5. 할 일 우선순위 정렬 AI")
            LegalBullets([
                "기본값: 온디바이스 AI (Apple Foundation Models 또는 MLX Qwen)",
                "할 일 우선순위 정렬 데이터는 외부 서비스로 전송하지 않음",
                "이메일 본문은 전송하지 않음",
            ])
        }

        LegalCard(number: 2, title: "정보 저장 위치") {
            LegalTable(
                headers: ["저장소", "저장 항목"],
                rows: [
                    ["기기 내 로컬 (SwiftData)", "할 일·페르소나·Audit 이벤트·분석 결과 (iCloud 비활성 시)"],
                    ["기기 내 로컬 전용 (emailContainer)", "Gmail 메시지 전체 — iCloud 동기화 완전 제외"],
                    ["iCloud CloudKit 비공개 DB (선택)", "할 일·페르소나·Audit 이벤트·분석 결과 (iCloud 활성 시)"],
                    ["iCloud Key-Value Store (선택)", "앱 설정값 (AI 제공자 선택 등)"],
                    ["기기 Keychain", "Gmail OAuth 토큰"],
                ]
            )
            InfoBox(text: "이메일 본문은 기기 내 별도 로컬 저장소에만 보관됩니다. iCloud를 활성화하면 할 일 등 동기화 항목은 사용자의 비공개 CloudKit 데이터베이스에 저장됩니다.")
                .padding(.top, 6)
        }

        LegalCard(number: 3, title: "제3자 처리위탁 및 데이터 국외 이전") {
            VStack(spacing: 6) {
                ThirdPartyCard(name: "Apple Inc.", provider: "미국 외 다수", items: "할 일·페르소나·설정값 (iCloud 활성 시) — 기기 간 동기화", url: URL(string: "https://www.apple.com/legal/privacy/")!)
                ThirdPartyCard(name: "Google LLC", provider: "미국 외 다수", items: "Gmail 메시지 목록 읽기, OAuth 토큰 교환 — 이메일 연동", url: URL(string: "https://policies.google.com/privacy")!)
            }
        }

        LegalCard(number: 4, title: "Google API Services 사용자 데이터 정책") {
            LegalBody(text: "SIFT의 Google API로부터 받은 정보의 사용 및 다른 앱·서비스로의 전송은, Limited Use 요건을 포함한 Google API Services User Data Policy를 준수합니다.")
            LegalBullets([
                "Gmail 데이터는 앱 내 할 일 추출 기능에만 사용",
                "광고 또는 제3자 마케팅 목적으로 사용하지 않음",
                "AI 모델 학습에 사용하지 않음",
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
                rows: [
                    ["할 일·페르소나 등 앱 데이터", "앱 삭제 또는 직접 삭제 시까지", "기기 데이터 삭제 / iCloud 컨테이너 삭제"],
                    ["이메일 메시지 (로컬)", "연동 해제 시 삭제 가능", "앱 데이터 삭제"],
                    ["Gmail OAuth 토큰", "연동 해제 시 즉시 삭제", "Keychain SecItemDelete"],
                    ["iCloud 데이터", "iCloud.com에서 직접 삭제 시", "Apple CloudKit 삭제"],
                ]
            )
        }

        LegalCard(number: 6, title: "이용자의 권리 및 행사 방법") {
            LegalBullets([
                "할 일·페르소나 삭제: 앱 내에서 직접 삭제",
                "Gmail 연동 해제: 설정 → 이메일 연동 → 연결 해제 (토큰 즉시 삭제)",
                "캘린더 권한 철회: iOS 설정 → 개인정보 보호 → 캘린더 → SIFT 비활성화",
                "iCloud 동기화 해제: 설정 → iCloud 동기화 → 비활성화",
                "모든 데이터 삭제: 앱 삭제 시 로컬 전체 삭제 (iCloud 데이터는 iCloud.com에서 별도 삭제)",
            ])
            LegalBody(text: "정보 열람·정정·삭제·처리정지 요청: pieroot.02@gmail.com (영업일 5일 이내 처리)")
                .padding(.top, 8)
        }

        LegalCard(number: 7, title: "데이터 보안") {
            LegalBullets([
                "Gmail OAuth 토큰은 iOS Keychain에 암호화 저장",
                "이메일 본문은 온디바이스 전용 저장소에 보관, 네트워크 전송 없음",
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
            LegalBody(text: "SIFT는 이메일·캘린더·수동 입력으로 수집한 할 일을 온디바이스 AI로 분류·정리하는 iOS/macOS 개인 생산성 앱입니다. 운영자가 개인적으로 개발·배포하는 무료 서비스입니다.")
        }

        LegalCard(number: 2, title: "이용 조건") {
            LegalBullets([
                "본 서비스는 개인적·비상업적 목적으로만 이용할 수 있습니다.",
                "서비스를 역공학·역컴파일·수정·재배포하거나 허가 없이 상업적으로 이용할 수 없습니다.",
                "법령이나 타인의 권리를 침해하는 방식으로 사용할 수 없습니다.",
            ])
        }

        LegalCard(number: 3, title: "제3자 서비스") {
            LegalBody(text: "서비스는 아래 제3자 서비스와 연동됩니다. 각 서비스의 독자적인 이용약관 및 개인정보 처리방침이 함께 적용됩니다.")
            VStack(spacing: 6) {
                ThirdPartyCard(name: "Gmail API", provider: "Google LLC", items: "받은편지함 읽기 전용 연동", url: URL(string: "https://policies.google.com/terms")!)
                ThirdPartyCard(name: "iCloud / CloudKit", provider: "Apple Inc.", items: "할 일 데이터 기기 간 동기화", url: URL(string: "https://www.apple.com/legal/internet-services/icloud/")!)
            }
            .padding(.top, 6)
            LegalBody(text: "제3자 서비스 이용으로 발생하는 책임은 해당 제공사와의 관계에서 이용자가 직접 부담합니다.")
                .padding(.top, 8)
        }
        
        LegalCard(number: 4, title: "서비스 내용 및 가용성") {
            LegalBullets([
                "서비스는 현재 상태 그대로(as-is) 무료로 제공됩니다.",
                "운영자는 사전 통보 없이 기능을 변경·중단·종료할 수 있습니다.",
                "온디바이스 AI 및 Apple/Google 시스템 서비스의 가용성은 OS·기기 상태에 따라 달라질 수 있습니다.",
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
            LegalBody(text: "서비스의 소스코드·디자인·브랜딩은 운영자의 지식재산입니다. 이용자가 앱에 입력한 데이터(할 일·메모 등)는 이용자 본인의 소유이며, 운영자는 이를 마케팅·학습 등 목적으로 사용하지 않습니다.")
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
