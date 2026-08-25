import Foundation
import Testing
@testable import todo

@Suite("IMAP response decoder")
struct IMAPResponseDecoderTests {
    @Test("reassembles split literal bytes including CRLF and braces")
    func splitLiteral() throws {
        var decoder = IMAPResponseDecoder()
        let first = Data("* 1 FETCH (BODY[TEXT] {12}\r\nLine ".utf8)
        let second = Data("{two}\r\nA0001 OK\r\n".utf8)
        #expect(try decoder.append(first).isEmpty)
        let lines = try decoder.append(second)
        #expect(lines.first == "* 1 FETCH (BODY[TEXT] {12}Line {two}\r\n")
        #expect(lines.last == "A0001 OK")
    }

    @Test("rejects literals over the hard transfer cap")
    func rejectsOversizedLiteral() {
        var decoder = IMAPResponseDecoder()
        #expect(throws: IMAPResponseDecoderError.literalTooLarge(500_001)) {
            _ = try decoder.append(Data("* 1 FETCH (BODY[] {500001}\r\n".utf8))
        }
    }
}
