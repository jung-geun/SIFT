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
    static let maximumLiteralBytes = 500_000
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
