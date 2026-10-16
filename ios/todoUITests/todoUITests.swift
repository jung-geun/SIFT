import XCTest

@MainActor
final class AppSmokeUITests: SIFTUITestCase {
    func testLaunchShowsPrimaryNavigation() throws {
        launch()

        step("핵심 탭과 할 일 추가 버튼 확인") {
            require(app.tabBars.buttons["할 일"], message: "할 일 탭이 없습니다.")
            require(app.tabBars.buttons["회의"], message: "회의 탭이 없습니다.")
            require(app.buttons["todo.addButton"], message: "할 일 추가 버튼이 없습니다.")
        }
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            app.terminate()
        }
    }
}
