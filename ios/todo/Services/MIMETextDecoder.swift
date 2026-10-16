import Foundation

nonisolated struct MIMETextDecoder: Sendable {
    struct Result: Sendable, Equatable {
        let text: String
        let html: String
    }

    // The services fetch at most 500,000 body bytes. Allow room for MIME headers,
    // but reject oversized input before normalization, regexes, or part copies.
    static let maximumMessageBytes = 1_048_576
    static let maximumHeaderBytes = 65_536
    static let maximumParts = 256
    static let maximumDepth = 5

    /// Returns empty content for unsupported, attached, malformed, or over-budget
    /// MIME entities. `html` is decoded source, not safe-to-render sanitized HTML.
    static func decode(_ raw: String) -> Result {
        guard raw.utf8.count <= maximumMessageBytes else { return Result(text: "", html: "") }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let top = headersAndBody(normalized) else { return Result(text: "", html: "") }
        if top.headers.isEmpty {
            return Result(text: normalizeText(normalized.trimmingCharacters(in: .whitespacesAndNewlines)), html: "")
        }
        var found = MultipartFind()
        find(top, depth: 0, into: &found)
        if let plain = found.plain {
            return Result(text: normalizeText(plain), html: found.html ?? "")
        }
        if let html = found.html {
            return Result(text: normalizeText(sanitizeHTML(html)), html: html)
        }
        return Result(text: "", html: "")
    }

    private struct MultipartFind {
        var plain: String?
        var html: String?
        var visitedParts = 0
    }

    /// Traverse only readable leaves, with one shared budget for the entire tree.
    /// Never fall back to decoding a skipped attachment or an invalid multipart.
    private static func find(
        _ part: (headers: [String: String], body: String),
        depth: Int,
        into result: inout MultipartFind
    ) {
        guard depth <= maximumDepth, result.visitedParts < maximumParts else { return }
        result.visitedParts += 1
        guard !isAttachment(part.headers) else { return }
        let contentType = mediaType(part.headers["content-type"] ?? "text/plain")
        if contentType.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: part.headers["content-type"] ?? ""),
                  validBoundary(boundary) else { return }
            for section in multipartParts(part.body, boundary: boundary, limit: maximumParts - result.visitedParts) {
                guard result.visitedParts < maximumParts else { return }
                if let subpart = headersAndBody(String(section)) {
                    find(subpart, depth: depth + 1, into: &result)
                } else {
                    result.visitedParts += 1
                }
                if result.plain != nil && result.html != nil { return }
            }
        } else if result.plain == nil, contentType == "text/plain" {
            result.plain = decodePart(part)
        } else if result.html == nil, contentType == "text/html" {
            result.html = decodePart(part)
        }
    }

    private static func mediaType(_ value: String) -> String {
        String(value.prefix(while: { $0 != ";" })).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func isAttachment(_ headers: [String: String]) -> Bool {
        let disposition = headers["content-disposition"] ?? ""
        if mediaType(disposition) == "attachment" { return true }
        // Some senders omit disposition but still declare a named text file.
        return parameters(in: disposition).keys.contains { $0 == "filename" || $0.hasPrefix("filename*") }
            || parameters(in: headers["content-type"] ?? "").keys.contains { $0 == "name" || $0.hasPrefix("name*") }
    }

    private static func validBoundary(_ boundary: String) -> Bool {
        let bytes = boundary.utf8
        return !bytes.isEmpty && bytes.count <= 70 && bytes.last != 32
            && bytes.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || "'()+_,-./:=? ".utf8.contains(byte)
            }
    }

    /// RFC 2046 delimiters occupy an entire line, optionally followed by SP/HTAB.
    /// Substring views avoid copying every sibling body before traversal.
    private static func multipartParts(_ body: String, boundary: String, limit: Int) -> [Substring] {
        guard limit > 0 else { return [] }
        let marker = "--" + boundary
        var parts: [Substring] = []
        var partStart: String.Index?
        var cursor = body.startIndex
        while cursor < body.endIndex {
            let end = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let next = end == body.endIndex ? end : body.index(after: end)
            let line = body[cursor..<end]
            if line.hasPrefix(marker) {
                let tail = line.dropFirst(marker.count)
                let closing = tail.hasPrefix("--")
                let padding = closing ? tail.dropFirst(2) : tail
                if padding.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    if let start = partStart {
                        // The newline preceding a delimiter belongs to the delimiter.
                        let partEnd = cursor > start ? body.index(before: cursor) : cursor
                        parts.append(body[start..<partEnd])
                        if parts.count == limit { return parts }
                    }
                    if closing { return parts }
                    partStart = next
                }
            }
            cursor = next
        }
        // A partially fetched message may omit the closing delimiter.
        if let start = partStart, start < body.endIndex, parts.count < limit {
            parts.append(body[start...])
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

    private static func headersAndBody(_ value: String) -> (headers: [String: String], body: String)? {
        let pieces = value.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            return (headers: [:], body: value)
        }
        let headerBlock = String(pieces[0])
        guard headerBlock.utf8.count <= maximumHeaderBytes else { return nil }
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
        if headers.isEmpty && !headerBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (headers: [:], body: value)
        }
        return (headers, String(pieces[1]))
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
        parameters(in: value)[name.lowercased()]
    }

    private static func parameters(in value: String) -> [String: String] {
        var results: [String: String] = [:]
        for piece in value.split(separator: ";").dropFirst(1) {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            results[key] = val
        }
        return results
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
