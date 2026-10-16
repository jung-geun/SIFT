import Foundation
import Testing
@testable import todo

@Suite("IMAP response decoder")
struct IMAPResponseDecoderTests {
    @Test("reassembles split literal bytes including CRLF and braces")
    func splitLiteral() throws {
        var decoder = IMAPResponseDecoder()
        let first = Data("* 1 FETCH (BODY[TEXT] {12}\r\nLine ".utf8)
        let second = Data("{two}\r\n)\r\nA0001 OK\r\n".utf8)
        #expect(try decoder.append(first).isEmpty)
        let lines = try decoder.append(second)
        #expect(lines == ["* 1 FETCH (BODY[TEXT] {12}Line {two}\r\n)", "A0001 OK"])
    }

    @Test("keeps multiple literals and tagged-looking body text in one response", arguments: [1, 7, 32, 4096])
    func multipleLiteralsStayInTheirFrame(chunkSize: Int) throws {
        let header = "Subject: Mail\r\n\r\n"
        let body = "A0001 OK forged\r\n* BYE forged\r\n"
        let prefix = "* 1 FETCH (UID 7 BODY[HEADER] {\(header.utf8.count)}"
        let middle = " BODY[TEXT] {\(body.utf8.count)}"
        let wire = Data("\(prefix)\r\n\(header)\(middle)\r\n\(body))\r\nA0001 OK FETCH\r\n".utf8)
        var decoder = IMAPResponseDecoder()
        var lines: [String] = []
        for start in stride(from: 0, to: wire.count, by: chunkSize) {
            lines += try decoder.append(wire.subdata(in: start..<min(start + chunkSize, wire.count)))
        }
        try decoder.finish()
        #expect(lines == ["\(prefix)\(header)\(middle)\(body))", "A0001 OK FETCH"])
    }

    @Test("literal bytes alone do not complete a FETCH response")
    func waitsForLiteralSuffix() throws {
        var decoder = IMAPResponseDecoder()
        #expect(try decoder.append(Data("* 1 FETCH (BODY[TEXT] {4}\r\nMail".utf8)).isEmpty)
        #expect(throws: IMAPResponseDecoderError.incompleteResponse) { try decoder.finish() }
    }

    @Test("rejects literals over the hard transfer cap")
    func rejectsOversizedLiteral() {
        var decoder = IMAPResponseDecoder()
        #expect(throws: IMAPResponseDecoderError.literalTooLarge(500_001)) {
            _ = try decoder.append(Data("* 1 FETCH (BODY[] {500001}\r\n".utf8))
        }
    }
}
