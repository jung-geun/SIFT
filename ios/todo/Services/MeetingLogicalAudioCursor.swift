@preconcurrency import AVFoundation
import Foundation

/// Independent overlap-trimmed reader for playback, waveform, and export.
/// Each consumer creates its own cursor, so file positions never race.
nonisolated final class MeetingLogicalAudioCursor {
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
        let ordered = manifest.parts.sorted { $0.partIndex < $1.partIndex }
        guard ordered.enumerated().allSatisfy({ $0.element.partIndex == $0.offset }),
              Set(ordered.map(\.partIndex)).count == ordered.count,
              ordered.allSatisfy({ $0.ownedStartSample >= 0 && $0.ownedEndSample > $0.ownedStartSample && $0.partStartSample >= 0 }),
              ordered.reduce(Int64(0), { total, part in total + (part.ownedEndSample - part.ownedStartSample) }) == manifest.totalSamples
        else {
            throw CursorError.invalidManifest(-1)
        }
        self.manifest = manifest
        self.parts = ordered
        var starts = [Int64]()
        var acc: Int64 = 0
        for part in ordered {
            starts.append(acc)
            acc += part.ownedEndSample - part.ownedStartSample
        }
        self.logicalStarts = starts
        self.directory = rootURL
            .appendingPathComponent(manifest.relativeDirectory, isDirectory: true)
    }

    /// Repositions the cursor to `logicalSample` in the concatenated owned
    /// timeline. Clamped to [0, totalSamples]; a value at/after the end leaves
    /// the cursor exhausted so `nextPCMBuffer` returns nil.
    func seek(toLogicalSample logicalSample: Int64) throws {
        let target = min(max(logicalSample, 0), manifest.totalSamples)
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
        let opened: AVAudioFile
        do {
            opened = try AVAudioFile(forReading: directory.appendingPathComponent(part.fileName))
        } catch {
            throw CursorError.invalidManifest(part.partIndex)
        }
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
            let frames = min(maxFrames, remainingInPart)
            guard let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                throw CursorError.bufferAllocation
            }
            try file.read(into: decoded, frameCount: AVAudioFrameCount(frames))
            guard Int64(decoded.frameLength) == frames else { throw CursorError.shortRead(partOffset) }
            remainingInPart -= frames
            if remainingInPart == 0 {
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
