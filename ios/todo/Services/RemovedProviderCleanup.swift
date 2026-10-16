import Foundation

/// Clean cutover only: never transfer a removed provider's consent or key into OpenAI.
@MainActor enum RemovedProviderCleanup {
    static let failureKey = "pieroot.todo.removedProviderCleanupFailed"

    static func run() throws {
        let defaults = UserDefaults.standard
        // Remove both synchronizable and device-local variants without reading the old secret.
        do {
            try KeychainStore.deleteChecked(service: "pieroot.todo.gemini", account: "api_key")
        } catch {
            defaults.set(true, forKey: failureKey)
            throw error
        }
        let obsoleteKeys = ["pieroot.todo.geminiModelID", "pieroot.todo.beta.geminiEnabled"]
        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "\(key).isLocal")
        }
        for key in ["selectedAIProvider", SettingsStore.betaSelectedProviderKey] where defaults.string(forKey: key) == "gemini" {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: "\(key).isLocal")
        }
        if SettingsStore.supportsICloud,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let cloud = NSUbiquitousKeyValueStore.default
            obsoleteKeys.forEach(cloud.removeObject(forKey:))
            if cloud.string(forKey: "selectedAIProvider") == "gemini" {
                cloud.removeObject(forKey: "selectedAIProvider")
            }
        }
        defaults.removeObject(forKey: failureKey)
    }
}
