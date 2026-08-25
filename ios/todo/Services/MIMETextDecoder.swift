import Foundation

nonisolated struct MIMETextDecoder: Sendable {
    struct Result: Sendable, Equatable {
        let text: String
        let html: String
    }

    static func decode(_ raw: String) -> Result {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let top = headersAndBody(normalized)
        if top.headers.isEmpty {
            return Result(text: normalizeText(normalized.trimmingCharacters(in: .whitespacesAndNewlines)), html: "")
        }
        let contentType = top.headers["content-type"]?.lowercased() ?? ""
        var found = MultipartFind()
        find(top, depth: 0, into: &found)
        if let plain = found.plain {
            return Result(text: normalizeText(plain), html: found.html ?? "")
        }
        if let html = found.html {
            return Result(text: normalizeText(sanitizeHTML(html)), html: html)
        }
        if contentType.hasPrefix("multipart/") {
            // Every part was an attachment, or none carried readable text.
            return Result(text: "", html: "")
        }
        let decoded = decodePart(top)
        return contentType.contains("text/html")
            ? Result(text: normalizeText(sanitizeHTML(decoded)), html: decoded)
            : Result(text: normalizeText(decoded), html: "")
    }

    private struct MultipartFind {
        var plain: String?
        var html: String?
    }

    /// Depth-first walk of a (possibly nested) multipart tree. Recurses into any
    /// `multipart/*` child (e.g. `multipart/mixed` wrapping `multipart/alternative`
    /// when an attachment is present) instead of only matching leaves one level
    /// deep, and skips parts marked `Content-Disposition: attachment` so a `.txt`
    /// attachment sibling never wins over the real message body.
    private static func find(
        _ part: (headers: [String: String], body: String),
        depth: Int,
        into result: inout MultipartFind
    ) {
        guard depth <= 5, !isAttachment(part.headers) else { return }
        let declaredContentType = part.headers["content-type"]?.lowercased() ?? ""
        let contentType = declaredContentType.isEmpty ? "text/plain" : declaredContentType
        if contentType.hasPrefix("multipart/"),
           let boundary = parameter("boundary", in: part.headers["content-type"] ?? "") {
            let subparts = multipartParts(part.body, boundary: boundary)
            for subpart in subparts {
                find(subpart, depth: depth + 1, into: &result)
                if result.plain != nil && result.html != nil { return }
            }
            return
        }
        if result.plain == nil, contentType.contains("text/plain") {
            result.plain = decodePart(part)
        } else if result.html == nil, contentType.contains("text/html") {
            result.html = decodePart(part)
        }
    }

    private static func isAttachment(_ headers: [String: String]) -> Bool {
        (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment")
    }

    private static func multipartParts(
        _ body: String,
        boundary: String
    ) -> [(headers: [String: String], body: String)] {
        let marker = "--\(boundary)"
        var parts: [(headers: [String: String], body: String)] = []
        for section in body.components(separatedBy: marker).dropFirst() {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "--" || trimmed.hasPrefix("--\n") {
                break
            }
            let parsed = headersAndBody(section)
            guard !parsed.headers.isEmpty
                    || !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            parts.append(parsed)
        }
        return parts
    }

    /// Decodes RFC 2047 encoded-word values used by Subject, From, and other
    /// Internet message headers.
    static func decodeRFC2047(_ header: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?]*)\\?="
        ) else {
            return header
        }

        let matches = regex.matches(
            in: header,
            range: NSRange(header.startIndex..., in: header)
        )
        guard !matches.isEmpty else { return header }

        var result = ""
        var cursor = header.startIndex
        var hasPreviousEncodedWord = false
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: header),
                  let charsetRange = Range(match.range(at: 1), in: header),
                  let encodingRange = Range(match.range(at: 2), in: header),
                  let encodedRange = Range(match.range(at: 3), in: header)
            else {
                continue
            }

            let between = String(header[cursor..<fullRange.lowerBound])
            if !hasPreviousEncodedWord
                || !between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += between
            }

            let charset = String(header[charsetRange])
            let encoding = String(header[encodingRange]).uppercased()
            let encoded = String(header[encodedRange])
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let stringEncoding = cfEncoding == kCFStringEncodingInvalidId
                ? String.Encoding.utf8
                : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))

            let decoded: String?
            if encoding == "B" {
                var base64 = encoded
                let remainder = base64.count % 4
                if remainder != 0 {
                    base64 += String(repeating: "=", count: 4 - remainder)
                }
                if let data = Data(
                    base64Encoded: base64,
                    options: .ignoreUnknownCharacters
                ) {
                    decoded = String(data: data, encoding: stringEncoding)
                        ?? String(data: data, encoding: .utf8)
                } else {
                    decoded = nil
                }
            } else {
                decoded = decodeRFC2047QuotedPrintable(encoded, encoding: stringEncoding)
            }

            result += decoded ?? String(header[fullRange])
            cursor = fullRange.upperBound
            hasPreviousEncodedWord = true
        }
        result += header[cursor...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headersAndBody(_ value: String) -> (headers: [String: String], body: String) {
        let pieces = value.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerBlock = String(pieces.first ?? "")
        var headers: [String: String] = [:]
        var current: String?
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.first == " " || line.first == "\t", let current {
                headers[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":"), isFieldName(line[..<colon]) {
                let key = line[..<colon].lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
            } else {
                current = nil
            }
        }
        return (headers, pieces.count == 2 ? String(pieces[1]) : "")
    }

    /// RFC 5322 `field-name` is 1*ftext, i.e. printable US-ASCII excluding SP —
    /// so a body line like "Hello [image: Google]" (contains a space before the
    /// colon) is rejected rather than misread as a header.
    static func isFieldName(_ name: Substring) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            return ascii > 32 && ascii < 127
        }
    }

    private static func decodePart(_ part: (headers: [String: String], body: String)) -> String {
        let encoding = part.headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
        let bytes: Data
        switch encoding {
        case "base64":
            bytes = Data(base64Encoded: part.body.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            bytes = decodeQuotedPrintable(part.body)
        default:
            bytes = Data(part.body.utf8)
        }
        let charset = parameter("charset", in: part.headers["content-type"] ?? "")
        return decodeData(bytes, charset: charset)
    }

    private static func decodeData(_ data: Data, charset: String?) -> String {
        guard let charset else {
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        }
        let normalized = charset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
        let stringEncoding = cfEncoding == kCFStringEncodingInvalidId
            ? String.Encoding.utf8
            : String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            )
        return String(data: data, encoding: stringEncoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data {
        var output = Data()
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 2 < bytes.count,
               let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high * 16 + low)
                index += 3
            } else if bytes[index] == 61, index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        for piece in value.split(separator: ";").dropFirst(1) {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return nil
    }

    private static func sanitizeHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func decodeRFC2047QuotedPrintable(
        _ text: String,
        encoding: String.Encoding
    ) -> String? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "_" {
                bytes.append(0x20)
                index = text.index(after: index)
            } else if character == "=" {
                let highIndex = text.index(after: index)
                guard highIndex < text.endIndex else {
                    bytes.append(0x3D)
                    break
                }
                let lowIndex = text.index(after: highIndex)
                guard lowIndex < text.endIndex,
                      let byte = UInt8(
                        String([text[highIndex], text[lowIndex]]),
                        radix: 16
                      )
                else {
                    bytes.append(0x3D)
                    index = highIndex
                    continue
                }
                bytes.append(byte)
                index = text.index(after: lowIndex)
            } else {
                bytes.append(contentsOf: character.utf8)
                index = text.index(after: index)
            }
        }
        return String(data: Data(bytes), encoding: encoding)
            ?? String(data: Data(bytes), encoding: .utf8)
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\[image:\s*[^\]]+\]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
