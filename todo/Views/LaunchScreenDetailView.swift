import SwiftUI

// 6. 시작 화면 설정
struct LaunchScreenDetailView: View {
    @AppStorage("pieroot.todo.launchBehavior") private var launchBehavior = "lastUsed"
    @AppStorage("pieroot.todo.launchTab")     private var launchTab = 0

    var body: some View {
        Form {
            Section {
                Picker("시작 방식", selection: $launchBehavior) {
                    Text("마지막 화면").tag("lastUsed")
                    Text("고정 탭").tag("fixed")
                }
                .pickerStyle(.menu)

                if launchBehavior == "fixed" {
                    Picker("기본 탭", selection: $launchTab) {
                        Text("할 일").tag(0)
                        Text("캘린더").tag(1)
                        Text("메일").tag(2)
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("'마지막 화면'은 앱 종료 시 보던 탭으로 돌아옵니다. '고정 탭'은 항상 지정한 탭으로 시작합니다.")
            }
        }
        .navigationTitle("시작 화면")
        .navigationBarTitleDisplayMode(.inline)
    }
}
