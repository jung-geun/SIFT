import Foundation

nonisolated enum IMAPResponseDecoderError: Error, Equatable {
    case literalTooLarge(Int)
    case invalidLiteralLength
    case literalLengthOverflow
    case lineTooLong
    case responseTooLarge
    case tooManyResponses
    case invalidUTF8
    case incompleteResponse
}

/// Frames logical IMAP responses, not physical lines: literal bytes never become
/// independently actionable tagged responses. Declaration CRLFs are omitted in
/// the returned `{length}<bytes>` representation expected by the service parsers.
nonisolated struct IMAPResponseDecoder: Sendable {
    static let maximumLiteralBytes = maximumResponseBytes
    static let maximumLineBytes = 65_536
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let maximumResponsesPerAppend = 10_000
    private static let crlf = Data([13, 10])

    private var buffer = Data()
    private var response = Data()
    private var pendingLiteralLength: Int?
    private var scanOffset = 0
    private var failure: IMAPResponseDecoderError?

    var hasPendingData: Bool {
        !buffer.isEmpty || !response.isEmpty || pendingLiteralLength != nil
    }

    mutating func finish() throws {
        if let failure { throw failure }
        if hasPendingData {
            fail(.incompleteResponse)
            throw IMAPResponseDecoderError.incompleteResponse
        }
    }

    mutating func append(_ chunk: Data) throws -> [String] {
        if let failure { throw failure }
        do {
            // Bound before copying, including fragments retained from prior reads.
            guard chunk.count <= Self.maximumResponseBytes - buffer.count - response.count else {
                throw IMAPResponseDecoderError.responseTooLarge
            }
            buffer.append(chunk)
            var output: [String] = []
            var outputBytes = 0
            while true {
                if let length = pendingLiteralLength {
                    guard buffer.count >= length else { break }
                    response.append(buffer.prefix(length))
                    buffer.removeFirst(length)
                    pendingLiteralLength = nil
                    scanOffset = 0
                    // A literal is an embedded value, not the end of a response.
                    // Keep FETCH's closing syntax and any following literals in this frame.
                    continue
                }

                let start = buffer.index(buffer.startIndex, offsetBy: scanOffset)
                guard let range = buffer.range(of: Self.crlf, in: start..<buffer.endIndex) else {
                    // Keep one byte of overlap for CRLF split across network reads.
                    guard buffer.count <= Self.maximumLineBytes
                        || (buffer.count == Self.maximumLineBytes + 1 && buffer.last == 13) else {
                        throw IMAPResponseDecoderError.lineTooLong
                    }
                    scanOffset = max(0, buffer.count - 1)
                    break
                }
                let lineLength = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
                guard lineLength <= Self.maximumLineBytes else {
                    throw IMAPResponseDecoderError.lineTooLong
                }
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let length = try Self.literalLength(in: line, continuing: !response.isEmpty)
                response.append(line)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                scanOffset = 0
                if let length {
                    guard length <= Self.maximumResponseBytes - response.count else {
                        throw IMAPResponseDecoderError.responseTooLarge
                    }
                    pendingLiteralLength = length
                    continue
                }

                guard output.count < Self.maximumResponsesPerAppend else {
                    throw IMAPResponseDecoderError.tooManyResponses
                }
                guard response.count <= Self.maximumResponseBytes - outputBytes else {
                    throw IMAPResponseDecoderError.responseTooLarge
                }
                // Lossy replacement would change literal byte counts and make the
                // service's byte-indexed literal extraction ambiguous. Fail closed.
                guard let text = String(data: response, encoding: .utf8) else {
                    throw IMAPResponseDecoderError.invalidUTF8
                }
                outputBytes += response.count
                output.append(text)
                response.removeAll(keepingCapacity: false)
            }
            return output
        } catch let error as IMAPResponseDecoderError {
            fail(error)
            throw error
        }
    }

    private mutating func fail(_ error: IMAPResponseDecoderError) {
        failure = error
        buffer.removeAll(keepingCapacity: false)
        response.removeAll(keepingCapacity: false)
        pendingLiteralLength = nil
        scanOffset = 0
    }

    private static func literalLength(in data: Data, continuing: Bool) throws -> Int? {
        if !continuing {
            // Status response text may legitimately end in braces. Only untagged
            // data responses (and their continuations) can carry server literals.
            let tokens = data.split(separator: 32, maxSplits: 2)
            guard tokens.count >= 2, tokens[0].elementsEqual([42]) else { return nil }
            let kind = String(decoding: tokens[1], as: UTF8.self).uppercased()
            if ["OK", "NO", "BAD", "BYE", "PREAUTH"].contains(kind) { return nil }
        }
        var quoted = false
        var escaped = false
        var open: Data.Index?
        for index in data.indices {
            let byte = data[index]
            if escaped {
                escaped = false
            } else if quoted && byte == 92 {
                escaped = true
            } else if byte == 34 {
                quoted.toggle()
            } else if !quoted && byte == 123 {
                guard open == nil else { throw IMAPResponseDecoderError.invalidLiteralLength }
                open = index
            }
        }
        guard let open else { return nil }
        guard !quoted, data.last == 125,
              open == data.startIndex || data[data.index(before: open)] == 32
                || data[data.index(before: open)] == 40 else {
            throw IMAPResponseDecoderError.invalidLiteralLength
        }
        let digits = data[data.index(after: open)..<data.index(before: data.endIndex)]
        guard !digits.isEmpty else { throw IMAPResponseDecoderError.invalidLiteralLength }
        var length = 0
        for digit in digits {
            guard (48...57).contains(digit) else {
                throw IMAPResponseDecoderError.invalidLiteralLength
            }
            let (multiplied, multiplyOverflow) = length.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = multiplied.addingReportingOverflow(Int(digit - 48))
            guard !multiplyOverflow, !addOverflow else {
                throw IMAPResponseDecoderError.literalLengthOverflow
            }
            length = next
        }
        guard length <= maximumLiteralBytes else {
            throw IMAPResponseDecoderError.literalTooLarge(length)
        }
        return length
    }
}

/// Content-policy outcomes, not transport failures or successful hydration.
nonisolated enum IMAPTextBodyError: Error, Equatable {
    case tooLarge
    case noReadableText
    case invalidResponse
}

/// Selects complete readable MIME representations without downloading attachments.
nonisolated enum IMAPTextBody {
    struct Part: Sendable, Equatable {
        let section: String
        let subtype: String
        let octets: Int
        let encoding: String
        let charset: String?
        let isRootSinglePart: Bool
        let contributesText: Bool
        let representation: String

        init(
            section: String,
            subtype: String,
            octets: Int,
            encoding: String = "7BIT",
            charset: String? = nil,
            isRootSinglePart: Bool = false,
            contributesText: Bool = true,
            representation: String? = nil
        ) {
            self.section = section
            self.subtype = subtype
            self.octets = octets
            self.encoding = encoding.uppercased()
            self.charset = charset
            self.isRootSinglePart = isRootSinglePart
            self.contributesText = contributesText
            self.representation = representation ?? section
        }
    }

    static func ownedResponses(_ lines: [String], uid: UInt32) -> [String] {
        lines.filter {
            IMAPWireSyntax.isFetch(IMAPWireSyntax.protocolText($0))
                && IMAPWireSyntax.token("UID", in: $0)
                    .flatMap { IMAPWireSyntax.positiveDecimal($0, as: UInt32.self) } == uid
        }
    }

    static func select(from lines: [String], uid: UInt32) throws -> [Part] {
        let owned = ownedResponses(lines, uid: uid)
        guard let structure = extractBodyStructureString(from: owned),
              let expr = parseSExpr(structure) else { throw IMAPTextBodyError.invalidResponse }
        let parts = try select(expr, prefix: "", depth: 0)
        guard !parts.isEmpty else { throw IMAPTextBodyError.noReadableText }
        var octets = 0
        for part in parts where part.contributesText {
            guard part.octets <= MIMETextDecoder.maximumMessageBytes - octets else {
                throw IMAPTextBodyError.tooLarge
            }
            octets += part.octets
        }
        // Keep display alternatives only when they fit the existing shared
        // budget. A large duplicate HTML representation must not block plain.
        for part in parts where !part.contributesText {
            guard part.octets <= MIMETextDecoder.maximumMessageBytes - octets else {
                return parts.filter(\.contributesText)
            }
            octets += part.octets
        }
        return parts
    }

    static func fetchAttributes(_ parts: [Part]) -> String {
        parts.map { "BODY.PEEK[\($0.section).MIME] BODY.PEEK[\($0.section)]" }.joined(separator: " ")
    }

    /// Required text is decoded before optional display copies so display budget
    /// or content failures cannot make a complete plain body unconfirmed.
    static func decode(_ parts: [Part], from lines: [String]) throws -> MIMETextDecoder.Result {
        var text: [String] = []
        var html = [String?](repeating: nil, count: parts.count)
        var textRepresentations = Set<String>()
        var htmlRepresentations = Set<String>()
        var bytes = 0
        var displayFailed = false
        for contributesText in [true, false] {
            for (index, part) in parts.enumerated() where part.contributesText == contributesText {
                if !contributesText && displayFailed { break }
                do {
                    let decoded = try decodePart(part, from: lines, remainingBytes: MIMETextDecoder.maximumMessageBytes - bytes)
                    bytes += decoded.bytes
                    if part.contributesText {
                        text.append(decoded.content.text)
                        textRepresentations.insert(part.representation)
                    }
                    if !decoded.content.html.isEmpty {
                        html[index] = decoded.content.html
                        htmlRepresentations.insert(part.representation)
                    }
                } catch let error as IMAPTextBodyError {
                    guard !part.contributesText else { throw error }
                    // No transport calls happen here. Only optional HTML's
                    // local content/framing/budget validation is discarded.
                    displayFailed = true
                }
            }
        }
        let body = text.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IMAPTextBodyError.noReadableText }
        return MIMETextDecoder.Result(
            text: body,
            html: !displayFailed && textRepresentations.isSubset(of: htmlRepresentations)
                ? html.compactMap { $0 }.joined(separator: "\n") : ""
        )
    }

    private static func decodePart(
        _ part: Part,
        from lines: [String],
        remainingBytes: Int
    ) throws -> (content: MIMETextDecoder.Result, bytes: Int) {
        let bodyAttribute = "BODY[\(part.section)]"
        let mimeAttribute = "BODY[\(part.section).MIME]"
        if lines.contains(where: { line in
            let syntax = IMAPWireSyntax.protocolText(line)
            return [bodyAttribute, mimeAttribute].contains { attribute in
                syntax.range(
                    of: NSRegularExpression.escapedPattern(for: attribute) + #"<[0-9]+>"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
        }) {
            throw IMAPTextBodyError.noReadableText
        }
        guard let body = lines.compactMap({ IMAPWireSyntax.literal($0, attribute: bodyAttribute) }).first,
              body.text.utf8.count == body.length
        else { throw IMAPTextBodyError.invalidResponse }
        // BODYSTRUCTURE octets are estimates; the complete section response's
        // literal declaration, not that estimate, frames the actual bytes.
        var mime: String
        if let header = lines.compactMap({ IMAPWireSyntax.literal($0, attribute: mimeAttribute)?.text }).first {
            mime = header
        } else if lines.contains(where: {
            IMAPWireSyntax.protocolText($0).range(
                of: NSRegularExpression.escapedPattern(for: mimeAttribute) + #"\s+NIL(?=[ )]|$)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }) {
            guard part.isRootSinglePart else { throw IMAPTextBodyError.noReadableText }
            mime = ""
        } else {
            throw IMAPTextBodyError.invalidResponse
        }
        // Only a proven single-part root shares the message header's MIME
        // fields. A multipart root header cannot describe a selected leaf.
        if mime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard part.isRootSinglePart else { throw IMAPTextBodyError.noReadableText }
            if let rootHeader = lines.compactMap({ IMAPWireSyntax.literal($0, attribute: "BODY[HEADER]")?.text }).first {
                mime = rootHeader
            }
        }
        let separator = mime.hasSuffix("\r\n\r\n") || mime.hasSuffix("\n\n") ? "" : "\r\n\r\n"
        let size = mime.utf8.count + separator.utf8.count + body.length
        guard size <= remainingBytes else { throw IMAPTextBodyError.tooLarge }
        guard let content = MIMETextDecoder.decodeTextPart(
            mime + separator + body.text,
            subtype: part.subtype,
            expectedEncoding: part.encoding,
            expectedCharset: part.charset
        ) else {
            throw IMAPTextBodyError.noReadableText
        }
        return (content, size)
    }

    enum SExpr: Sendable, Equatable {
        case atom(String)
        case list([SExpr])
    }

    private nonisolated static func parseSExpr(_ text: String) -> SExpr? {
        var index = text.startIndex
        guard let expr = parseExpr(text, index: &index, depth: 0) else { return nil }
        skipWhitespace(text, index: &index)
        return index == text.endIndex ? expr : nil
    }

    private nonisolated static func parseExpr(_ text: String, index: inout String.Index, depth: Int) -> SExpr? {
        guard depth < 64 else { return nil }
        skipWhitespace(text, index: &index)
        guard index < text.endIndex else { return nil }

        if text[index] == "(" {
            text.formIndex(after: &index)
            var elements: [SExpr] = []
            while index < text.endIndex {
                skipWhitespace(text, index: &index)
                if index < text.endIndex, text[index] == ")" {
                    text.formIndex(after: &index)
                    return .list(elements)
                }
                guard let element = parseExpr(text, index: &index, depth: depth + 1) else { return nil }
                elements.append(element)
            }
            return nil
        } else if text[index] == "\"" {
            text.formIndex(after: &index)
            var str = ""
            var escaped = false
            while index < text.endIndex {
                let char = text[index]
                text.formIndex(after: &index)
                if escaped {
                    str.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    return .atom(str)
                } else {
                    str.append(char)
                }
            }
            return nil
        } else {
            let start = index
            while index < text.endIndex {
                let char = text[index]
                if char.isWhitespace || char == "(" || char == ")" || char == "\"" {
                    break
                }
                text.formIndex(after: &index)
            }
            guard start < index else { return nil }
            return .atom(String(text[start..<index]))
        }
    }

    private nonisolated static func skipWhitespace(_ text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            text.formIndex(after: &index)
        }
    }

    private static func select(_ expr: SExpr, prefix: String, depth: Int) throws -> [Part] {
        guard depth <= MIMETextDecoder.maximumDepth,
              case .list(let elements) = expr, !elements.isEmpty else {
            throw IMAPTextBodyError.noReadableText
        }
        if case .list = elements[0] {
            let children = elements.prefix { if case .list = $0 { return true }; return false }
            guard children.count <= MIMETextDecoder.maximumParts,
                  elements.count > children.count,
                  let subtype = extractAtomString(elements[children.count])?.uppercased()
            else { throw IMAPTextBodyError.noReadableText }
            // Multipart extension order is subtype, parameters, disposition.
            if hasAttachmentParameters(elements.count > children.count + 1 ? elements[children.count + 1] : nil)
                || isAttached(elements.count > children.count + 2 ? elements[children.count + 2] : nil) {
                return []
            }
            guard ["ALTERNATIVE", "MIXED", "RELATED", "SIGNED"].contains(subtype) else {
                throw IMAPTextBodyError.noReadableText
            }
            if subtype == "ALTERNATIVE" {
                // A plain alternative represents the whole message, unlike
                // the first HTML leaf inside a composed related/mixed branch.
                var choices: [[Part]] = []
                for (offset, child) in children.enumerated() {
                    do {
                        choices.append(try select(child, prefix: section(prefix, offset + 1), depth: depth + 1))
                    } catch IMAPTextBodyError.noReadableText {
                        // Unsupported alternatives (e.g. text/calendar) do not
                        // invalidate a complete supported representation.
                        continue
                    }
                }
                guard let plain = choices.first(where: { isRepresentation($0, subtype: "PLAIN") }) else {
                    return choices.last(where: { !$0.isEmpty }) ?? []
                }
                guard let display = choices.last(where: { isRepresentation($0, subtype: "HTML") }) else {
                    return plain
                }
                let representation = "alternative:" + prefix
                return plain.filter(\.contributesText).map {
                    Part(section: $0.section, subtype: $0.subtype, octets: $0.octets, encoding: $0.encoding, charset: $0.charset, representation: representation)
                } + display.filter(\.contributesText).map {
                    Part(section: $0.section, subtype: $0.subtype, octets: $0.octets, encoding: $0.encoding, charset: $0.charset, contributesText: false, representation: representation)
                }
            }
            var result: [Part] = []
            for (offset, child) in children.enumerated() {
                result += try select(child, prefix: section(prefix, offset + 1), depth: depth + 1)
                guard result.count <= MIMETextDecoder.maximumParts else { throw IMAPTextBodyError.noReadableText }
            }
            return result
        }
        guard let mediaType = extractAtomString(elements[0])?.uppercased() else {
            throw IMAPTextBodyError.noReadableText
        }
        let dispositionIndex = mediaType == "TEXT" ? 9 : (mediaType == "MESSAGE" ? 11 : 8)
        if hasAttachmentParameters(elements.count > 2 ? elements[2] : nil)
            || isAttached(elements.count > dispositionIndex ? elements[dispositionIndex] : nil) {
            return []
        }
        // An inline forwarded message can carry later instructions. It is not a
        // binary decoration: without decoding it we cannot confirm the whole body.
        if mediaType == "MESSAGE" { throw IMAPTextBodyError.noReadableText }
        guard mediaType == "TEXT" else { return [] }
        guard elements.count > 7,
              let subtype = extractAtomString(elements[1])?.uppercased(),
              ["PLAIN", "HTML"].contains(subtype),
              let encoding = extractAtomString(elements[5]),
              let size = extractAtomString(elements[6]),
              !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) }),
              let octets = Int(size)
        else { throw IMAPTextBodyError.noReadableText }
        return [Part(
            section: prefix.isEmpty ? "1" : prefix,
            subtype: subtype,
            octets: octets,
            encoding: encoding,
            charset: charset(in: elements[2]),
            isRootSinglePart: prefix.isEmpty
        )]
    }

    private static func isRepresentation(_ parts: [Part], subtype: String) -> Bool {
        var found = false
        for part in parts where part.contributesText {
            guard part.subtype == subtype else { return false }
            found = true
        }
        return found
    }

    private static func section(_ prefix: String, _ child: Int) -> String {
        prefix.isEmpty ? "\(child)" : "\(prefix).\(child)"
    }

    private nonisolated static func extractAtomString(_ expr: SExpr) -> String? {
        if case .atom(let str) = expr { return str }
        return nil
    }

    private static func charset(in expr: SExpr) -> String? {
        guard case .list(let params) = expr, params.count >= 2 else { return nil }
        for index in stride(from: 0, to: params.count - 1, by: 2) {
            if extractAtomString(params[index])?.uppercased() == "CHARSET" {
                return extractAtomString(params[index + 1])
            }
        }
        return nil
    }

    private static func hasAttachmentParameters(_ expr: SExpr?) -> Bool {
        guard let expr, case .list(let params) = expr else { return false }
        for index in stride(from: 0, to: params.count, by: 2) {
            guard let name = extractAtomString(params[index])?.uppercased() else { continue }
            if name == "NAME" || name.hasPrefix("NAME*") || name == "FILENAME" || name.hasPrefix("FILENAME*") {
                return true
            }
        }
        return false
    }

    private static func isAttached(_ expr: SExpr?) -> Bool {
        guard let expr, case .list(let disposition) = expr else { return false }
        return disposition.first.flatMap(extractAtomString)?.uppercased() == "ATTACHMENT"
            || hasAttachmentParameters(disposition.count > 1 ? disposition[1] : nil)
    }

    private nonisolated static func extractBodyStructureString(from lines: [String]) -> String? {
        for line in lines {
            guard let range = line.range(of: "BODYSTRUCTURE", options: .caseInsensitive),
                  IMAPWireSyntax.protocolText(String(line[..<range.upperBound])).uppercased().hasSuffix("BODYSTRUCTURE")
            else { continue }
            let tail = line[range.upperBound...]
            guard let openParen = tail.firstIndex(of: "(") else { continue }
            var depth = 0
            var inQuote = false
            var isEscaped = false
            var endIdx = openParen
            for idx in line.indices[openParen...] {
                let char = line[idx]
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" && inQuote {
                    isEscaped = true
                    continue
                }
                if char == "\"" {
                    inQuote.toggle()
                    continue
                }
                if !inQuote {
                    if char == "(" {
                        depth += 1
                    } else if char == ")" {
                        depth -= 1
                        if depth == 0 {
                            endIdx = idx
                            return String(line[openParen...endIdx])
                        }
                    }
                }
            }
        }
        return nil
    }

}
