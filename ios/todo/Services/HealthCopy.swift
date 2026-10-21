import Foundation

nonisolated enum HealthCopy {
    static func text(_ key: String, _ english: String, _ korean: String) -> String {
        let language = AppLanguage.current
        return AppLanguage.localized(
            key,
            defaultValue: language == .korean ? korean : english,
            language: language,
            table: "Localizable",
            comment: "Health history connections, local evidence, and explicitly confirmed routines."
        )
    }
}
