import Foundation
import UniformTypeIdentifiers

/// Retains the user-granted read scope from selection through conversion.
/// No source copies, bookmarks, path-string grants, or clipboard monitoring.
nonisolated final class MeetingAudioImportSelection: Sendable {
    enum Failure: LocalizedError, Equatable {
        case singleFileRequired, noCopiedFile

        var errorDescription: String? {
            switch self {
            case .singleFileRequired:
                return AppLanguage.localized("meeting.audioImport.singleFile", defaultValue: "한 번에 오디오 파일 하나만 넣어주세요.", language: .current)
            case .noCopiedFile:
                return AppLanguage.localized("meeting.audioImport.noCopiedFile", defaultValue: "Finder에서 오디오 파일을 복사한 뒤 붙여넣어 주세요. 텍스트 경로나 웹 주소는 가져오지 않습니다.", language: .current)
            }
        }
    }

    let url: URL
    private let scoped: Bool

    init(urls: [URL]) throws {
        guard urls.count == 1 else { throw Failure.singleFileRequired }
        let url = urls[0]
        guard url.isFileURL else { throw MeetingAudioImportService.Failure.unavailableInput }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw MeetingAudioImportService.Failure.unavailableInput }
            guard values.contentType?.conforms(to: .audio) == true
                    || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else {
                throw MeetingAudioImportService.Failure.unsupportedAudio
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw (error as? MeetingAudioImportService.Failure) ?? MeetingAudioImportService.Failure.unavailableInput
        }
        self.url = url
        self.scoped = scoped
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
