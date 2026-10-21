import Foundation
import Testing
@testable import todo

@Suite("Full-cloud preference safety")
struct CloudPreferenceSafetyTests {
    @Test("A local model choice edited during an awaited sync is not overwritten")
    func changedChoiceSurvivesRestore() throws {
        let suite = "SIFTCloudPreferenceRace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "preference/selectedAIProvider"
        defaults.set("laya", forKey: "selectedAIProvider")
        let before = try #require(CloudPreferenceStore.capture(defaults: defaults)[key])
        defaults.set("onDevice", forKey: "selectedAIProvider")
        let remote = try JSONEncoder().encode(CloudPreferenceValue.string("foundationModels"))
        #expect(throws: CloudPreferenceError.self) {
            try CloudPreferenceStore.apply(key: key, payload: remote,
                expectedDigest: CloudFileStore.digest(before), defaults: defaults)
        }
        #expect(defaults.string(forKey: "selectedAIProvider") == "onDevice")
    }

    @Test("Credential deletion, retry and restore receipts never become another device's live state")
    func credentialSafetyMetadataIsNotPortable() throws {
        let suite = "SIFTCloudCredentialMetadata-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [
            "pieroot.todo.imap.explicitlyDeleted.a@example.invalid",
            "pieroot.todo.outlook.imap.explicitlyDeleted.a@example.invalid",
            "pieroot.todo.imap.portableReceipt.v1.a@example.invalid",
            "pieroot.todo.outlook.imap.portableReceipt.v1.a@example.invalid",
            "pieroot.todo.gmail.revoked.v1.oauth_tokens",
            "pieroot.todo.imap.pendingPublications.v1",
            "pieroot.todo.outlook.imap.pendingPublications.v1"
        ]
        for key in keys { defaults.set("device-private-state", forKey: key) }
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        let replacement = try JSONEncoder().encode(CloudPreferenceValue.string("foreign-state"))
        for key in keys {
            #expect(snapshot["preference/" + key] == nil)
            #expect(throws: CloudPreferenceError.self) {
                try CloudPreferenceStore.apply(key: "preference/" + key, payload: replacement,
                    expectedDigest: nil, defaults: defaults)
            }
            #expect(defaults.string(forKey: key) == "device-private-state")
        }
    }

    @Test("Meeting language and automatic-mode choices remain local during cloud capture and restore")
    func meetingLanguageMemoryIsNotPortable() throws {
        let suite = "SIFTCloudMeetingLanguages-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local: [String: CloudPreferenceValue] = [
            "pieroot.todo.meeting.sourceLanguageTag": .string("ko-KR"),
            "pieroot.todo.meeting.summaryLanguageTag": .string("ja"),
            "pieroot.todo.meeting.automaticLanguageDetection": .boolean(false)
        ]
        for (key, value) in local { defaults.set(value.value, forKey: key) }
        let snapshot = try CloudPreferenceStore.capture(defaults: defaults)
        for (key, value) in local {
            #expect(snapshot["preference/" + key] == nil)
            let foreign = try JSONEncoder().encode(CloudPreferenceValue.string("en-US"))
            #expect(throws: CloudPreferenceError.self) {
                try CloudPreferenceStore.apply(key: "preference/" + key, payload: foreign,
                    expectedDigest: nil, defaults: defaults)
            }
            #expect(try CloudPreferenceValue(try #require(defaults.object(forKey: key))) == value)
        }
    }
}
