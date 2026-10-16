import Foundation
import Testing
@testable import todo

@Suite("EmailHTMLSanitizer pure transformation and resource policy")
struct EmailHTMLSanitizerTests {

    @Test("CSP permits HTTPS visual resources for img-src, style-src, and font-src")
    func testHTTPSVisualResourcesPermittedInCSP() {
        let inputHTML = "<html><body><h1>Hello</h1></body></html>"
        let sanitized = EmailHTMLSanitizer.sanitize(inputHTML)

        #expect(sanitized.contains("img-src data: cid: blob: https:;"))
        #expect(sanitized.contains("style-src 'unsafe-inline' https:;"))
        #expect(sanitized.contains("font-src data: https:;"))

        let imageURL = URL(string: "https://example.com/newsletter/header.png")!
        let styleURL = URL(string: "https://cdn.example.com/styles.css")!
        let fontURL = URL(string: "https://fonts.example.com/font.woff2")!

        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(imageURL) == true)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(styleURL) == true)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(fontURL) == true)
    }

    @Test("Resource allowlist blocks insecure HTTP URLs")
    func testHTTPResourcesBlockedInAllowlist() {
        let httpImageURL = URL(string: "http://example.com/newsletter/header.png")!
        let httpScriptURL = URL(string: "http://cdn.example.com/script.js")!

        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(httpImageURL) == false)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(httpScriptURL) == false)
    }

    @Test("CSP strictly blocks active network, iframe, form, media, and object directives")
    func testBlockedCSPDirectivesRemainBlocked() {
        let sanitized = EmailHTMLSanitizer.sanitize("<p>Test</p>")

        #expect(sanitized.contains("default-src 'none';"))
        #expect(sanitized.contains("connect-src 'none';"))
        #expect(sanitized.contains("frame-src 'none';"))
        #expect(sanitized.contains("media-src 'none';"))
        #expect(sanitized.contains("object-src 'none';"))
        #expect(sanitized.contains("base-uri 'none';"))
        #expect(sanitized.contains("form-action 'none';"))
    }

    @Test("Script elements of all forms are completely removed")
    func testScriptElementsRemoved() {
        let input = """
        <html>
        <head>
          <script>alert('xss1')</script>
          <SCRIPT type="text/javascript">console.log('xss2')</SCRIPT>
          <script src="https://evil.com/bad.js"></script>
          <script src="https://evil.com/selfclosing.js"/>
        </head>
        <body>
          <p>Content</p>
        </body>
        </html>
        """
        let sanitized = EmailHTMLSanitizer.sanitize(input)

        #expect(!sanitized.contains("alert('xss1')"))
        #expect(!sanitized.contains("console.log('xss2')"))
        #expect(!sanitized.contains("bad.js"))
        #expect(!sanitized.contains("selfclosing.js"))
        #expect(!sanitized.contains("<script"))
        #expect(!sanitized.contains("<SCRIPT"))
    }

    @Test("Base elements are completely removed")
    func testBaseElementsRemoved() {
        let input = """
        <html>
        <head>
          <base href="http://evil.com/">
          <BASE href="https://example.com" target="_blank">
          <base href="https://example.com"></base>
        </head>
        <body>
          <p>Content</p>
        </body>
        </html>
        """
        let sanitized = EmailHTMLSanitizer.sanitize(input)

        #expect(!sanitized.contains("<base"))
        #expect(!sanitized.contains("<BASE"))
        #expect(!sanitized.contains("evil.com"))
    }

    @Test("Quoted and unquoted inline event handlers are removed without breaking valid attributes")
    func testInlineEventHandlersRemoved() {
        let input = """
        <body onload="init()">
          <img src="https://example.com/photo.jpg" onload=doSomething() alt="on=top" />
          <a href="https://example.com" onclick='trackClick()' ONMOUSEOVER=hoverTracker()>Link</a>
        </body>
        """
        let sanitized = EmailHTMLSanitizer.sanitize(input)

        #expect(!sanitized.contains("onload="))
        #expect(!sanitized.contains("init()"))
        #expect(!sanitized.contains("doSomething()"))
        #expect(!sanitized.contains("onclick="))
        #expect(!sanitized.contains("trackClick()"))
        #expect(!sanitized.contains("ONMOUSEOVER="))
        #expect(!sanitized.contains("hoverTracker()"))

        // Valid attributes like src, href, alt remain intact
        #expect(sanitized.contains("src=\"https://example.com/photo.jpg\""))
        #expect(sanitized.contains("href=\"https://example.com\""))
        #expect(sanitized.contains("alt=\"on=top\""))
    }

    @Test("HTTPS is restricted to visual subresources, not main-frame navigation")
    func testOnlyInitialLocalDocumentMayNavigateMainFrame() {
        var gate = EmailHTMLMainFrameNavigationGate()
        let allowsInitialDocument = gate.allows(URL(string: "about:blank")!)
        let allowsReplacementDocument = gate.allows(URL(string: "about:blank")!)
        let allowsRemoteDocument = gate.allows(URL(string: "https://example.com/redirect")!)

        gate.reset()
        let allowsRemoteInitialDocument = gate.allows(URL(string: "https://example.com/redirect")!)

        #expect(allowsInitialDocument)
        #expect(!allowsReplacementDocument)
        #expect(!allowsRemoteDocument)
        #expect(!allowsRemoteInitialDocument)
    }

    @Test("Local and internal schemes remain permitted in allowlist")
    func testOtherAllowedSchemesInAllowlist() {
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(URL(string: "about:blank")!) == true)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(URL(string: "data:image/png;base64,iVBORw0KGgo=")!) == true)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(URL(string: "blob:https://example.com/uuid")!) == true)
        #expect(EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(URL(string: "cid:image001.png@01D8.1234")!) == true)
    }

    @Test("the trusted CSP precedes sender resources with valid, missing, or malformed heads", arguments: [
        "<html><head><iframe src='https://example.invalid/frame'></iframe></head><body>Mail</body></html>",
        "<html><head><iframe src='https://example.invalid/frame'></iframe><body>Mail</body>",
        "<iframe src='https://example.invalid/frame'></iframe><p>Mail</p>"
    ])
    func policyPrecedesUntrustedResources(input: String) throws {
        let sanitized = EmailHTMLSanitizer.sanitize(input)
        let policy = try #require(sanitized.range(of: "Content-Security-Policy"))
        let resource = try #require(sanitized.range(of: "<iframe"))
        #expect(policy.lowerBound < resource.lowerBound)
    }

    @Test("sender links cannot launch active documents, files, or arbitrary app commands", arguments: [
        "javascript:alert(1)", "data:text/html,private", "file:///private/data",
        "sift-calendar://todo/private", "com.googleusercontent.apps.client:/oauth2callback?code=private",
        "https:relative-path"
    ])
    func unsafeExternalLinks(rawURL: String) throws {
        #expect(!EmailHTMLSanitizer.isAllowedExternalLinkURL(try #require(URL(string: rawURL))))
    }

    @Test("explicit web, mail, and phone links remain usable", arguments: [
        "https://example.com/help", "http://example.com/help", "mailto:person@example.com", "tel:+821012345678"
    ])
    func safeExternalLinks(rawURL: String) throws {
        #expect(EmailHTMLSanitizer.isAllowedExternalLinkURL(try #require(URL(string: rawURL))))
    }
}
