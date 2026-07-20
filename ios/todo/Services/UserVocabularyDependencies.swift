import CryptoKit

import SwiftData
import SwiftUI

struct UserVocabularyObserver: Sendable {
    let observeDocument: @Sendable (VocabularySourceDocument, Bool) async -> Void
    let observeDocuments: @Sendable ([VocabularySourceDocument], Bool) async -> Void

    static let noop = UserVocabularyObserver(observeDocument: { _, _ in }, observeDocuments: { _, _ in })

    init(observeDocument: @escaping @Sendable (VocabularySourceDocument, Bool) async -> Void, observeDocuments: @escaping @Sendable ([VocabularySourceDocument], Bool) async -> Void) {
        self.observeDocument = observeDocument
        self.observeDocuments = observeDocuments
    }

    static func live(service: UserVocabularyService, enqueue: @escaping @Sendable (VocabularyEnrichmentRequest) async -> Void = { _ in }) -> UserVocabularyObserver {
        UserVocabularyObserver(
            observeDocument: { document, force in
                do {
                    if let request = try await service.observe(document, forceEnrichment: force) {
                        await enqueue(request)
                    }
                } catch {
                    // Observation is strictly best-effort; callers must keep their original result.
                    print("[Vocabulary] observation failed: \(document.source.rawValue)")
                }
            },
            observeDocuments: { documents, force in
                for document in documents {
                    do {
                        if let request = try await service.observe(document, forceEnrichment: force) {
                            await enqueue(request)
                        }
                    } catch {
                        print("[Vocabulary] observation failed: \(document.source.rawValue)")
                    }
                }
            }
        )
    }
}

struct UserVocabularyDependencies {
    let service: UserVocabularyService
    let observer: UserVocabularyObserver
}

private struct UserVocabularyDependenciesKey: EnvironmentKey {
    static let defaultValue: UserVocabularyDependencies? = nil
}

extension EnvironmentValues {
    var userVocabulary: UserVocabularyDependencies? {
        get { self[UserVocabularyDependenciesKey.self] }
        set { self[UserVocabularyDependenciesKey.self] = newValue }
    }
}

@MainActor
func makeVocabularyMeetingDependencies(_ service: UserVocabularyService?) -> MeetingPostProcessor.Dependencies {
    guard let service else { return .empty }
    return .init(
        snapshot: { await service.snapshot() },
        refine: { meetingID, result, snapshot, language, allowModelLoad in
            try await MeetingRefinementEngine().refine(
                meetingID: meetingID,
                result: result,
                vocabulary: snapshot,
                language: language,
                allowModelLoad: allowModelLoad
            )
        },
        analyze: { meetingID, result, hint, language in
            await MeetingAnalysisEngine().analyze(
                meetingID: meetingID,
                result: result,
                glossaryHint: hint,
                language: language
            )
        },
        save: { try $0.save() },
        learnCorrections: { meetingID, pairs in
            let fingerprint = SHA256.hash(data: Data(pairs.map { "\($0.from)\u{0}\($0.to)" }.joined(separator: "\u{0}").utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            try? await service.learnFromCorrection(meetingID: meetingID, correctionFingerprint: fingerprint, pairs: pairs)
        }
    )
}
