import SwiftUI

enum OnDeviceModelSupportState: Equatable {
    case available
    case unsupported

    init(isCapable: Bool, availableModelCount: Int) {
        self = isCapable && availableModelCount > 0
            ? .available
            : .unsupported
    }
}

// 3. TODO 자동 정렬 및 AI
struct IntelligenceDetailView: View {
    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        Form {
            Section {
                Label("마감일, 중요도, 태그, 출처와 행동 패턴을 사용해 우선순위를 정합니다.", systemImage: "list.number")
                    .fixedSize(horizontal: false, vertical: true)
                Label("사용자가 지정한 우선순위는 항상 유지됩니다.", systemImage: "hand.raised.fill")
                    .fixedSize(horizontal: false, vertical: true)
                Label("행동 프로필은 신뢰도와 갱신 시점이 충분할 때만 규칙을 개인화합니다.", systemImage: "brain.head.profile")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("TODO 우선순위 규칙")
            } footer: {
                Text("규칙 기반 정렬은 베타 provider를 켜지 않아도 항상 사용할 수 있습니다.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appFormStyle()
        .navigationTitle("TODO 우선순위 규칙")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            tutorial?.handlePriorityRulesDetailClosed()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let tutorial {
                AppTutorialTipHost(tutorial: tutorial, screen: .aiDetail)
            }
        }
    }
}
