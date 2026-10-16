import XCTest

@MainActor
class SIFTUITestCase: XCTestCase {
    enum Language: String {
        case korean = "ko"
        case english = "en"
        case spanish = "es"
        case japanese = "ja"
        case simplifiedChinese = "zh-Hans"
        case french = "fr"
        case italian = "it"
        case german = "de"

        var appleLanguages: String { "(\(rawValue))" }
        var locale: String {
            switch self {
            case .korean: "ko_KR"
            case .english: "en_US"
            case .spanish: "es_ES"
            case .japanese: "ja_JP"
            case .simplifiedChinese: "zh_CN"
            case .french: "fr_FR"
            case .italian: "it_IT"
            case .german: "de_DE"
            }
        }
    }

    enum StartTab: Int {
        case todos = 0
        case calendar = 1
        case mail = 2
        case meetings = 3
    }

    struct LaunchConfiguration {
        var language: Language = .korean
        var startTab: StartTab = .todos
        var showsAllTabs = true
        var hasCompletedTutorial = true
        var setsLanguageOverride = true
        var additionalArguments: [String] = []
        var environment: [String: String] = [:]
    }

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.terminate()

        #if targetEnvironment(macCatalyst)
        throw XCTSkip(
            "Mac Catalyst interaction tests are not reliable under XCUIAutomation. "
                + "The Mac scheme is covered by build and launch smoke verification."
        )
        #endif
    }

    override func record(_ issue: XCTIssue) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Failure - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.record(issue)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func launch(_ configuration: LaunchConfiguration = LaunchConfiguration()) {
        var arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", configuration.language.appleLanguages,
            "-AppleLocale", configuration.language.locale,
            "-pieroot.todo.hasOnboarded", "YES",
            "-pieroot.todo.hasCompletedTutorial", configuration.hasCompletedTutorial ? "YES" : "NO",
            "-pieroot.todo.iCloudSyncEnabled", "NO",
            "-pieroot.todo.launchBehavior", "fixed",
            "-pieroot.todo.launchTab", String(configuration.startTab.rawValue),
            "-ui-test-in-memory-store",
            "-ui-test-suppress-crash-prompt"
        ]
        if configuration.setsLanguageOverride {
            arguments.append(contentsOf: [
                "-pieroot.todo.appLanguageOverride", configuration.language.rawValue
            ])
        }
        if configuration.showsAllTabs {
            arguments.append("-pieroot.todo.uiTestShowAllTabs")
        }
        arguments.append(contentsOf: configuration.additionalArguments)

        app.launchArguments = arguments
        app.launchEnvironment = ["SIFT_UI_TESTING": "1"].merging(configuration.environment) { _, new in new }
        app.launch()

        step("앱이 준비될 때까지 대기") {
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 10),
                "앱이 foreground 실행 상태가 되지 않았습니다."
            )
        }
    }

    func step(_ name: String, _ block: () throws -> Void) rethrows {
        try XCTContext.runActivity(named: name) { _ in
            try block()
        }
    }

    func require(_ element: XCUIElement, timeout: TimeInterval = 10, message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message)
    }

    func requireHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement? = nil,
        maxSwipes: Int = 6,
        message: String
    ) {
        let surface = scrollView ?? app
        for _ in 0..<maxSwipes where !element.isHittable {
            surface.swipeUp()
        }
        require(element, timeout: 2, message: message)
        XCTAssertTrue(element.isHittable, message)
    }

    func tap(_ element: XCUIElement, timeout: TimeInterval = 10, message: String) {
        require(element, timeout: timeout, message: message)
        XCTAssertTrue(element.isHittable, "\(message) 요소가 보이지만 탭할 수 없습니다.")
        element.tap()
    }

    func openSettings() {
        tap(app.buttons["todo.moreActionsMenu"], message: "To-Do More 메뉴를 열 수 없습니다.")
        tap(app.buttons["todo.settingsButton"], message: "More 메뉴에서 Settings를 열 수 없습니다.")
        require(app.buttons["settings.closeButton"], message: "Settings 화면이 열리지 않았습니다.")
    }

    func replaceText(in element: XCUIElement, with text: String) {
        tap(element, message: "텍스트 입력 필드를 찾지 못했습니다.")
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }
}
