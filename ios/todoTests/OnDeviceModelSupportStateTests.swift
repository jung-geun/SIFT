import Testing
@testable import todo

@Suite("On-device model support state")
struct OnDeviceModelSupportStateTests {
    @Test("지원 가능하고 모델이 있으면 선택지를 표시한다")
    func testAvailableModelChoices() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: true,
                availableModelCount: 1
            ) == .available
        )
    }

    @Test("메모리 기준을 충족하지 못하면 미지원 상태다")
    func testInsufficientMemoryIsUnsupported() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: false,
                availableModelCount: 0
            ) == .unsupported
        )
    }

    @Test("표시 가능한 모델이 없으면 미지원 상태다")
    func testEmptyModelCatalogIsUnsupported() {
        #expect(
            OnDeviceModelSupportState(
                isCapable: true,
                availableModelCount: 0
            ) == .unsupported
        )
    }
}
