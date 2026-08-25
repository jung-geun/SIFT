import Foundation
import Testing
@testable import todo

@Suite("Diagnostic export request")
struct DiagnosticExportRequestTests {
    @Test("export destination and payload stay coupled")
    func exportDestinationAndPayloadStayCoupled() {
        let payload = Data([1, 2, 3])

        let mail = DiagnosticExportRequest(
            data: payload,
            fileURL: nil,
            canSendMail: true
        )
        let share = DiagnosticExportRequest(
            data: payload,
            fileURL: nil,
            canSendMail: false
        )

        #expect(mail.destination == .mail)
        #expect(share.destination == .share)
        #expect(mail.data == payload)
        #expect(share.data == payload)
    }
}
