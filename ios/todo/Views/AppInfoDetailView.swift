import SwiftUI
import SwiftData

// 8. 앱 정보
struct AppInfoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showDevChanges = false
    
    var body: some View {
        Form {
            Section {
                LabeledContent("버전") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
                    Text("\(version) (\(build))")
                }
                LabeledContent("이메일 연동") { Text("Gmail (1계정)") }

                Button {
                    NotificationCenter.default.post(name: .settingsDismissRequested, object: nil)
                    dismiss()
                } label: {
                    Label("튜토리얼 다시 보기", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("appInfo.replayTutorial")
                .buttonStyle(.borderless)

                Button {
                    showDevChanges = true
                } label: {
                    Label("개발 현황 및 예정 기능", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderless)
            }

            Section(header: Text("약관 및 정책")) {
                NavigationLink(destination: LegalDocumentView(document: .privacy)) {
                    Label("개인정보 처리방침", systemImage: "hand.raised.fill")
                }
                NavigationLink(destination: LegalDocumentView(document: .terms)) {
                    Label("서비스 약관", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("앱 정보")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDevChanges) {
            devChangesSheet
        }
    }
    
    private var devChangesSheet: some View {
        NavigationStack {
            List {
                Section {
                    devRow("✅", "SwiftData 기반 로컬/iCloud 데이터 저장소 구축")
                    devRow("✅", "최초 기동 시 iCloud 동기화 여부 설정 지원 (0단계 온보딩)")
                    devRow("✅", "iCloud 글로벌 설정 vs 기기별 로컬 설정 분리 및 중앙 관리")
                    devRow("✅", "Gmail OAuth2 연동 및 메일 자동 분석 (할 일 자동 추출)")
                    devRow("✅", "이메일 딥링크 지원 (앱 내에서 원본 메일로 바로 이동)")
                    devRow("✅", "캘린더 마감 자동 등록 및 완료 처리 정책 연동")
                    devRow("✅", "앱-시스템 캘린더 실시간 양방향 동기화 및 충돌 자동 해결")
                    devRow("✅", "완료된 항목 1달 경과 시 자동 숨김 처리")
                    devRow("✅", "데이터베이스 용량 초과 방지를 위한 자동 오래된 데이터 청소")
                    devRow("✅", "시간대/태그별 처리 속도 통계 기반 행동 패턴 메모리 분석")
                    devRow("✅", "설정 화면 8대 대분류 카테고리 분할 및 독립 뷰 리팩토링")
                    devRow("✅", "온디바이스 AI 최적화 (가상 모델 제거 및 MLX 모델 탑재)")
                } header: {
                    Text(AppLanguage.localized("appInfo.completed", defaultValue: "완료", language: .current, comment: "Development status section."))
                }

                Section {
                    devRow("🔄", "온디바이스 AI 고성능 모델 기기 메모리 최적화")
                    devRow("🔄", "백그라운드 캘린더 변경사항 감지 정확도 향상 및 자동 동기화 고도화")
                } header: {
                    Text(AppLanguage.localized("appInfo.inProgress", defaultValue: "진행 중", language: .current, comment: "Development status section."))
                }
                
                Section {
                    devRow("📋", "다중 이메일 계정 연동 및 Gmail 외 서비스(IMAP 등) 연동 확장")
                    devRow("📋", "Apple Foundation Models 정식 버전 대응 및 통합 재도입")
                    devRow("📋", "사용자 맞춤형 커스텀 파인튜닝 LLM 교체 및 간편 로드")
                } header: {
                    Text(AppLanguage.localized("appInfo.planned", defaultValue: "예정", language: .current, comment: "Development status section."))
                }
            }
            .navigationTitle("개발 현황")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { showDevChanges = false }
                }
            }
        }
    }
    
    @ViewBuilder
    private func devRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon).font(.body)
            Text(AppLanguage.localized(text, defaultValue: text, language: .current, comment: "Development status item.")).font(.subheadline)
        }
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView()
            .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
    }
}
