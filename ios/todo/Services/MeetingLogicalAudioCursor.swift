@preconcurrency import AVFoundation
import Foundation

/// Queue-confined readers used by both playback scheduling and waveform generation.
nonisolated protocol MeetingPCMStreamCursor: AnyObject {
    func seek(toLogicalSample logicalSample: Int64) throws
    func nextPCMBuffer(maxFrames: Int64, outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer?
}

/// Independent overlap-trimmed reader for playback, waveform, and export.
/// Each consumer creates its own cursor, so file positions never race.
nonisolated final class MeetingLogicalAudioCursor: MeetingPCMStreamCursor {
    let manifest: MeetingAudioManifest
    private let directory: URL
    private var partOffset = 0
    private var file: AVAudioFile?
    private let parts: [MeetingAudioPartManifest]
    private var remainingInPart: Int64 = 0
    /// Prefix sums of each part's owned length; `logicalStarts[i]` is the logical
    /// sample offset at which part `i` begins in the concatenated timeline.
    private let logicalStarts: [Int64]

    init(manifest: MeetingAudioManifest, rootURL: URL = AppDataContainer.meetingDirectory()) throws {
        let ordered = try Self.validatedParts(for: manifest)
        self.manifest = manifest
        self.parts = ordered
        var starts = [Int64]()
        var acc: Int64 = 0
        for part in ordered {
            starts.append(acc)
            acc += part.ownedEndSample - part.ownedStartSample
        }
        self.logicalStarts = starts
        let directory = rootURL.appendingPathComponent(manifest.relativeDirectory, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(rootURL.resolvingSymlinksInPath().path + "/") else {
            throw CursorError.invalidManifest(-1)
        }
        self.directory = directory
    }

    deinit { file?.close() }

    /// Validate before doing arithmetic or opening files. Owned ranges are contiguous;
    /// physical parts may overlap, but each logical sample has exactly one owner.
    static func validatedParts(for manifest: MeetingAudioManifest) throws -> [MeetingAudioPartManifest] {
        let ordered = manifest.parts.sorted { $0.partIndex < $1.partIndex }
        let components = manifest.relativeDirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard manifest.sampleRate > 0, manifest.sampleRate <= 384_000,
              manifest.totalSamples >= 0,
              !components.isEmpty, components.allSatisfy({ safePathComponent(String($0)) }) else {
            throw CursorError.invalidManifest(-1)
        }
        var end: Int64 = 0
        for (index, part) in ordered.enumerated() {
            guard part.partIndex == index, safePathComponent(part.fileName),
                  part.partStartSample >= 0, part.partStartSample <= part.ownedStartSample,
                  part.ownedStartSample == end, part.ownedEndSample > end,
                  part.ownedEndSample <= manifest.totalSamples else {
                throw CursorError.invalidManifest(part.partIndex)
            }
            end = part.ownedEndSample
        }
        guard end == manifest.totalSamples else { throw CursorError.invalidManifest(-1) }
        return ordered
    }

    private static func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    /// Repositions the cursor to `logicalSample` in the concatenated owned
    /// timeline. Clamped to [0, totalSamples]; a value at/after the end leaves
    /// the cursor exhausted so `nextPCMBuffer` returns nil.
    func seek(toLogicalSample logicalSample: Int64) throws {
        let target = min(max(logicalSample, 0), manifest.totalSamples)
        file?.close()
        file = nil
        remainingInPart = 0
        if target >= manifest.totalSamples {
            partOffset = parts.count
            return
        }
        // Last part whose logical start is <= target.
        var index = 0
        for candidate in parts.indices where logicalStarts[candidate] <= target {
            index = candidate
        }
        partOffset = index
        try openPart(index, ownedFrameOffset: target - logicalStarts[index])
    }

    /// Opens `parts[index]`, validates its format, and positions the read head
    /// `ownedFrameOffset` frames into the part's owned range.
    private func openPart(_ index: Int, ownedFrameOffset: Int64) throws {
        let part = parts[index]
        let url = directory.appendingPathComponent(part.fileName)
        guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw CursorError.invalidManifest(part.partIndex)
        }
        // Metadata errors belong to the cursor; native parse/open errors retain
        // their original domain, code and userInfo for diagnosis and retry.
        let opened = try AVAudioFile(forReading: url)
        guard opened.processingFormat.channelCount == 1,
              opened.processingFormat.sampleRate == Double(manifest.sampleRate) else {
            throw CursorError.invalidManifest(part.partIndex)
        }
        let skip = part.ownedStartSample - part.partStartSample
        let owned = part.ownedEndSample - part.ownedStartSample
        guard skip >= 0, owned > 0, skip <= opened.length, owned <= opened.length - skip,
              ownedFrameOffset >= 0, ownedFrameOffset < owned else {
            throw CursorError.invalidManifest(part.partIndex)
        }
        opened.framePosition = AVAudioFramePosition(skip + ownedFrameOffset)
        file = opened
        remainingInPart = owned - ownedFrameOffset
    }

    func nextPCMBuffer(maxFrames: Int64, outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard maxFrames > 0 else { return nil }
        while true {
            if file == nil {
                guard partOffset < parts.count else { return nil }
                try openPart(partOffset, ownedFrameOffset: 0)
            }
            guard let file else { continue }
            let frames = min(maxFrames, remainingInPart, 65_536)
            guard let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                throw CursorError.bufferAllocation
            }
            try file.read(into: decoded, frameCount: AVAudioFrameCount(frames))
            guard Int64(decoded.frameLength) == frames else { throw CursorError.shortRead(partOffset) }
            remainingInPart -= frames
            if remainingInPart == 0 {
                file.close()
                self.file = nil
                partOffset += 1
            }
            return try convert(decoded, to: outputFormat)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format.sampleRate == outputFormat.sampleRate,
           input.format.channelCount == outputFormat.channelCount,
           input.format.commonFormat == outputFormat.commonFormat {
            return input
        }
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw CursorError.conversion
        }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate).rounded(.up)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw CursorError.bufferAllocation }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else { throw conversionError ?? CursorError.conversion }
        return output
    }

    enum CursorError: LocalizedError {
        case invalidManifest(Int)
        case shortRead(Int)
        case bufferAllocation
        case conversion

        var errorDescription: String? {
            errorDescription(language: .current)
        }

        func errorDescription(language: AppLanguage) -> String {
            switch self {
            case .invalidManifest(let part):
                let format = AppLanguage.localized(
                    "error.meeting.audioCursor.invalidManifest",
                    defaultValue: language == .english
                        ? "The original recording manifest is invalid. Part %d"
                        : "원본 녹음 manifest가 올바르지 않습니다. part %d",
                    language: language,
                    comment: "Meeting audio cursor error shown when a recording manifest part is invalid."
                )
                return String(format: format, locale: language.locale, part)
            case .shortRead(let part):
                let format = AppLanguage.localized(
                    "error.meeting.audioCursor.shortRead",
                    defaultValue: language == .english
                        ? "Decoding the original recording stopped unexpectedly. Part %d"
                        : "원본 녹음 decode가 중단되었습니다. part %d",
                    language: language,
                    comment: "Meeting audio cursor error shown when decoding a recording part stops early."
                )
                return String(format: format, locale: language.locale, part)
            case .bufferAllocation:
                return AppLanguage.localized(
                    "error.meeting.audioCursor.bufferAllocation",
                    defaultValue: language == .english
                        ? "The playback PCM buffer could not be created."
                        : "재생 PCM buffer를 만들 수 없습니다.",
                    language: language,
                    comment: "Meeting audio cursor error shown when a playback PCM buffer cannot be allocated."
                )
            case .conversion:
                return AppLanguage.localized(
                    "error.meeting.audioCursor.conversion",
                    defaultValue: language == .english
                        ? "Converting the original recording to PCM failed."
                        : "원본 녹음 PCM 변환에 실패했습니다.",
                    language: language,
                    comment: "Meeting audio cursor error shown when recording PCM conversion fails."
                )
            }
        }
    }
}
