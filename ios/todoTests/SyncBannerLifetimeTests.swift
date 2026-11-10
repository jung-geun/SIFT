import Foundation
import Testing
@testable import todo

@Suite("AsyncDeadline bounds non-cancellable work")
struct AsyncDeadlineTests {
    @Test("Returns the value when the operation finishes before the limit")
    func returnsValueBeforeLimit() async throws {
        let value = try await AsyncDeadline.run(.seconds(5)) { 7 }
        #expect(value == 7)
    }

    @Test("Resumes with Expired while the operation ignores cancellation")
    func resumesAtDeadlineWithHungOperation() async throws {
        await #expect(throws: AsyncDeadline.Expired.self) {
            try await AsyncDeadline.run(.milliseconds(20)) {
                Thread.sleep(forTimeInterval: 1)
                return 1
            }
        }
    }
}
