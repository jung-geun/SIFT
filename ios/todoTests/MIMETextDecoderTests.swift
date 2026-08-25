import Testing
@testable import todo

@Suite("MIME text decoder")
struct MIMETextDecoderTests {
    @Test("selects multipart plain text and decodes base64")
    func multipartBase64() {
        let raw = """
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 8bit

        <b>HTML</b>
        --b
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        SGVsbG8gV29ybGQ=
        --b--
        """
        let result = MIMETextDecoder.decode(raw)
        #expect(result.text == "Hello World")
        #expect(result.html.contains("HTML"))
    }

    @Test("decodes quoted printable and sanitizes HTML fallback")
    func quotedPrintableAndHTML() {
        let plain = MIMETextDecoder.decode("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nHello=20world=21")
        #expect(plain.text == "Hello world!")
        let html = MIMETextDecoder.decode("Content-Type: text/html\n\n<script>bad()</script><p>Hello</p>")
        #expect(html.text == "Hello")
        #expect(!html.text.contains("script"))
    }

    @Test("decodes folded adjacent RFC2047 encoded-words without injecting whitespace")
    func foldedRFC2047Header() {
        let header = "=?UTF-8?B?67O07JWIIA==?= =?UTF-8?B?7JWM66a8?="
        #expect(MIMETextDecoder.decodeRFC2047(header) == "보안 알림")
    }

    @Test("removes image placeholders from readable text")
    func imagePlaceholderCleanup() {
        let result = MIMETextDecoder.decode("Hello [image: Google]\nWorld")
        #expect(result.text == "Hello \nWorld")
        #expect(!result.text.contains("[image:"))
    }

    @Test("descends multipart/mixed wrapping multipart/alternative, skipping the attachment sibling")
    func nestedMultipartMixedWithAttachment() {
        let raw = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: text/plain; charset=utf-8; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        attachment contents should not win
        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/html; charset=utf-8

        <b>HTML body</b>
        --inner
        Content-Type: text/plain; charset=utf-8

        Plain body
        --inner--
        --outer--
        """
        let result = MIMETextDecoder.decode(raw)
        #expect(result.text == "Plain body")
        #expect(result.html.contains("HTML body"))
    }

    @Test("decodes non-UTF8 MIME charsets through the IANA charset name")
    func nonUTF8Charset() {
        let result = MIMETextDecoder.decode(
            "Content-Type: text/plain; charset=iso-8859-1\n"
                + "Content-Transfer-Encoding: quoted-printable\n\n"
                + "caf=E9"
        )
        #expect(result.text == "café")
    }

    @Test("treats a headerless multipart child as ordinary plain text")
    func headerlessMultipartChild() {
        let raw = """
        Content-Type: multipart/alternative; boundary="b"

        --b

        Plain body without a content type
        --b--
        """
        #expect(MIMETextDecoder.decode(raw).text == "Plain body without a content type")
    }
}
