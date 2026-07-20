import Speech

/// Applies one immutable vocabulary snapshot to a newly-created analyzer.
enum UserVocabularyBiasing {
    static func analysisContext(snapshot: UserVocabularySnapshot) -> AnalysisContext? {
        guard !snapshot.contextualStrings.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(snapshot.contextualStrings.prefix(100))
        return context
    }

    static func prepare(analyzer: SpeechAnalyzer, inputFormat: AVAudioFormat, snapshot: UserVocabularySnapshot) async throws {
        if let context = analysisContext(snapshot: snapshot) {
            do {
                try await analyzer.setContext(context)
            } catch {
                // Context phrases are optional; analyzer preparation remains valid.
            }
        }
        try await analyzer.prepareToAnalyze(in: inputFormat)
    }
}
