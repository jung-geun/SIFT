import Foundation

nonisolated enum IMAPResponseDecoderError: Error, Equatable {
    case literalTooLarge(Int)
}
nonisolated struct IMAPResponseDecoder: Sendable {
    private var buffer = Data()
    private var pendingPrefix: Data?
    private var pendingLiteralLength: Int?

    mutating func append(_ chunk: Data) throws -> [String] {
        buffer.append(chunk)
        var output: [String] = []
        while true {
            if let prefix = pendingPrefix, let length = pendingLiteralLength {
                guard length <= 500_000 else { throw IMAPResponseDecoderError.literalTooLarge(length) }
                guard buffer.count >= length else { break }
                let literal = buffer.prefix(length)
                buffer.removeFirst(length)
                if buffer.starts(with: Data([13, 10])) { buffer.removeFirst(2) }
                output.append(String(decoding: prefix + literal, as: UTF8.self))
                pendingPrefix = nil
                continue
            }

            guard let range = buffer.range(of: Data([13, 10])) else { break }
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let length = Self.literalLength(in: line) {
                pendingPrefix = line
                pendingLiteralLength = length
                continue
            }
            output.append(String(decoding: line, as: UTF8.self))
        }
        return output
    }

    private static func literalLength(in data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              let open = text.lastIndex(of: "{"),
              text.hasSuffix("}") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }
}
