import Foundation
import Testing
@testable import todo

@Suite("Diagnostic export request")
struct DiagnosticExportRequestTests {

    @Test("an incomplete report cannot produce a consent preview")
    func incompleteReportHasNoPreview() {
        #expect(DiagnosticReportPreview(data: Data("{}".utf8)) == nil)
        #expect(DiagnosticReportPreview(data: Data([0xFF])) == nil)
    }
}
