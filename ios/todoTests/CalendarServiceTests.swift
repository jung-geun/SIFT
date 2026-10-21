import EventKit
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Calendar service", .serialized)
struct CalendarServiceTests {
    @Test("an explicit writable destination never follows the system default")
    @MainActor
    func explicitDestinationRemainsSelected() throws {
        let systemDefaults: [String?] = ["other-calendar", nil]
        for systemDefaultID in systemDefaults {
            let resolved = try CalendarService.resolveDestinationID(
                selection: "chosen-calendar",
                writableIDs: ["chosen-calendar", "other-calendar"],
                systemDefaultID: systemDefaultID
            )
            #expect(resolved == "chosen-calendar")
        }
    }

    @Test("missing and read-only explicit destinations throw instead of falling back")
    @MainActor
    func unavailableExplicitDestinationThrows() {
        // Missing and read-only calendars are both absent from the writable ID set.
        for selection in ["missing-calendar", "read-only-calendar"] {
            #expect(throws: CalendarError.destinationUnavailable) {
                try CalendarService.resolveDestinationID(
                    selection: selection,
                    writableIDs: ["writable-system-calendar"],
                    systemDefaultID: "writable-system-calendar"
                )
            }
        }
    }

    @Test("no destination selection throws even when the system default is writable")
    @MainActor
    func unselectedDestinationThrows() {
        #expect(throws: CalendarError.destinationNotSelected) {
            try CalendarService.resolveDestinationID(
                selection: "",
                writableIDs: ["writable-system-calendar"],
                systemDefaultID: "writable-system-calendar"
            )
        }
    }

    @Test("explicit system selection follows the current writable system default")
    @MainActor
    func explicitSystemDestinationFollowsCurrentDefault() throws {
        for currentDefault in ["first-account-calendar", "second-account-calendar"] {
            let resolved = try CalendarService.resolveDestinationID(
                selection: CalendarService.systemDefaultCalendarID,
                writableIDs: ["first-account-calendar", "second-account-calendar"],
                systemDefaultID: currentDefault
            )
            #expect(resolved == currentDefault)
        }
    }

    @Test("explicit system selection requires an available writable system default")
    @MainActor
    func unavailableSystemDestinationThrows() {
        let unavailableDefaults: [String?] = [nil, "missing-calendar", "read-only-calendar"]
        for systemDefaultID in unavailableDefaults {
            #expect(throws: CalendarError.destinationUnavailable) {
                try CalendarService.resolveDestinationID(
                    selection: CalendarService.systemDefaultCalendarID,
                    writableIDs: ["other-writable-calendar"],
                    systemDefaultID: systemDefaultID
                )
            }
        }
    }

    @Test("completion keeps external or unmarked events despite local links and inferred ownership")
    @MainActor
    func completionPreservesEventsWithoutOwnershipProof() throws {
        let externalURL = try #require(URL(string: "https://example.com/event"))
        for source in [TodoSource.manual, .email, .calendar, .meeting] {
            let todo = Todo(title: "Linked", source: source, sourceRef: "message-42")
            todo.calendarEventID = "local-event"
            todo.calendarEventExternalID = "cross-device-event"
            todo.aiRecommendedTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let eventURLs: [URL?] = [nil, externalURL]
            for eventURL in eventURLs {
                for requested in CalendarCompletionAction.allCases {
                    #expect(CalendarService.completionAction(
                        for: todo, eventURL: eventURL, requested: requested
                    ) == .keep)
                }
            }
        }
    }

    @Test("completion keeps events with mismatched identity, entity, or external origin markers")
    @MainActor
    func completionPreservesMismatchedMarkers() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let otherIdentifier = try #require(UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1"))
        let todo = Todo(id: identifier, title: "Owned", source: .email, sourceRef: "message-42")
        todo.calendarEventOrigin = CalendarEventOrigin.siftEmail.rawValue
        todo.calendarEventID = "local-event"
        todo.calendarEventExternalID = "cross-device-event"
        let wrongIdentifier = try #require(CalendarEventMarker.url(
            entity: .todo, identifier: otherIdentifier, origin: .siftEmail
        ))
        let wrongEntity = try #require(CalendarEventMarker.url(
            entity: .standaloneEvent, identifier: identifier, origin: .siftEmail
        ))
        let externalOrigin = try #require(CalendarEventMarker.url(
            entity: .todo, identifier: identifier, origin: .externalCalendar
        ))
        for eventURL in [wrongIdentifier, wrongEntity, externalOrigin] {
            for requested in CalendarCompletionAction.allCases {
                #expect(CalendarService.completionAction(
                    for: todo, eventURL: eventURL, requested: requested
                ) == .keep)
            }
        }
    }

    @Test("matching SIFT markers permit completion actions and honor keep without a local link")
    @MainActor
    func matchingSiftMarkersHonorRequestedCompletionAction() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let todo = Todo(id: identifier, title: "Recovered")
        let origins: [CalendarEventOrigin] = [.siftManual, .siftEmail, .siftMeeting, .siftRecommendation, .siftHealth]
        for origin in origins {
            let eventURL = try #require(CalendarEventMarker.url(
                entity: .todo, identifier: identifier, origin: origin
            ))
            for requested in CalendarCompletionAction.allCases {
                #expect(CalendarService.completionAction(
                    for: todo, eventURL: eventURL, requested: requested
                ) == requested)
            }
        }
        let legacyURL = try #require(URL(string: "sift-todo://todo/\(identifier.uuidString)"))
        for requested in CalendarCompletionAction.allCases {
            #expect(CalendarService.completionAction(
                for: todo, eventURL: legacyURL, requested: requested
            ) == requested)
        }
    }

    @Test("legacy email ownership requires an email todo with the exact nonempty source reference")
    @MainActor
    func legacyEmailOwnershipIsScopedToExactEmailReference() throws {
        let eventURL = try #require(URL(string: "x-todoapp-email://message%2B42"))
        for source in [TodoSource.manual, .email, .calendar, .meeting] {
            let todo = Todo(title: "Legacy", source: source, sourceRef: "message+42")
            for requested in CalendarCompletionAction.allCases {
                let expected = source == .email ? requested : .keep
                #expect(CalendarService.completionAction(
                    for: todo, eventURL: eventURL, requested: requested
                ) == expected)
            }
        }
        for sourceRef in ["", "message+420", "other-message"] {
            let todo = Todo(title: "Unrelated email", source: .email, sourceRef: sourceRef)
            for requested in CalendarCompletionAction.allCases {
                #expect(CalendarService.completionAction(
                    for: todo, eventURL: eventURL, requested: requested
                ) == .keep)
            }
        }
    }

    @Test("saving an imported Todo with a cleared deadline only detaches the local link")
    @MainActor
    func importedDraftEditsNeverAuthorizeOriginalMutation() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let originalRef = "external-event#2026-10-16"
        for clearsDeadline in [false, true] {
            for linked in [false, true] {
                let todo = Todo(id: identifier, title: "Local rename", notes: "Local notes",
                                dueDate: clearsDeadline ? nil : due,
                                source: .calendar, sourceRef: originalRef)
                todo.calendarEventID = "external-original"
                todo.calendarEventExternalID = "external-account-id"
                // Even old or incorrectly inferred SIFT provenance cannot authorize import edits.
                todo.calendarEventOrigin = CalendarEventOrigin.siftManual.rawValue
                try CalendarService.shared.applyTodoCalendarEdit(for: todo, linked: linked)

                let detached = clearsDeadline || !linked
                #expect(todo.calendarEventID == (detached ? nil : "external-original"))
                #expect(todo.calendarEventExternalID == (detached ? "" : "external-account-id"))
                #expect(todo.title == "Local rename" && todo.notes == "Local notes")
                #expect(todo.dueDate == (clearsDeadline ? nil : due))
                #expect(todo.sourceRef == originalRef)
                let matchingURL = CalendarEventMarker.url(entity: .todo, identifier: identifier, origin: .siftManual)
                for action in CalendarCompletionAction.allCases {
                    #expect(CalendarService.completionAction(for: todo, eventURL: matchingURL, requested: action) == .keep)
                }
            }
        }
    }

    private func ownershipCandidate(in store: EKEventStore, url: URL?, title: String = "Original") -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3_600)
        event.notes = "Original notes"
        event.url = url
        return event
    }

    @Test("Todo writes refuse unmarked and identity-mismatched local links without acquiring ownership")
    @MainActor
    func linkedEventRequiresPreexistingOwnership() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let otherID = try #require(UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1"))
        let store = EKEventStore()
        let todo = Todo(id: identifier, title: "Edited", source: .email, sourceRef: "message-42")
        todo.calendarEventID = "local-link-is-not-proof"
        todo.calendarEventOrigin = CalendarEventOrigin.siftEmail.rawValue
        let unownedURLs: [URL?] = [
            nil,
            URL(string: "https://example.com/original"),
            CalendarEventMarker.url(entity: .todo, identifier: otherID, origin: .siftEmail),
            CalendarEventMarker.url(entity: .standaloneEvent, identifier: identifier, origin: .siftEmail),
            CalendarEventMarker.url(entity: .todo, identifier: identifier, origin: .externalCalendar),
            URL(string: "x-todoapp-email://message-420")
        ]
        for url in unownedURLs {
            let original = ownershipCandidate(in: store, url: url)
            #expect(throws: CalendarError.ownershipNotVerified) {
                try CalendarService.selectOwnedEvent(for: todo, candidates: [original])
            }
            #expect(original.url == url)
            #expect(original.title == "Original" && original.notes == "Original notes")
            #expect(todo.calendarEventID == "local-link-is-not-proof")
        }
    }

    @Test("external-ID collisions recover the unique matching ownership rather than the first event")
    @MainActor
    func collidingExternalRecoveryUsesOwnershipNotResultOrder() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let otherID = try #require(UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1"))
        let todo = Todo(id: identifier, title: "Recovered")
        todo.calendarEventID = "stale-device-id"
        todo.calendarEventExternalID = "colliding-caldav-id"
        let store = EKEventStore()
        let externalOriginal = ownershipCandidate(in: store, url: nil, title: "Other account original")
        let otherTodoEvent = ownershipCandidate(in: store, url: CalendarEventMarker.url(
            entity: .todo, identifier: otherID, origin: .siftManual))
        let owned = ownershipCandidate(in: store, url: CalendarEventMarker.url(
            entity: .todo, identifier: identifier, origin: .siftManual))
        // These are the competing candidates returned by one external-ID lookup.
        for candidates in [[externalOriginal, otherTodoEvent, owned], [owned, otherTodoEvent, externalOriginal]] {
            let selected = try #require(try CalendarService.selectOwnedEvent(for: todo, candidates: candidates))
            #expect(selected === owned)
            #expect(externalOriginal.url == nil && externalOriginal.title == "Other account original")
        }
        #expect(throws: CalendarError.ownershipNotVerified) {
            try CalendarService.selectOwnedEvent(for: todo, candidates: [externalOriginal, otherTodoEvent])
        }
        #expect(todo.calendarEventID == "stale-device-id")
        #expect(todo.calendarEventExternalID == "colliding-caldav-id")
    }

    @Test("copied SIFT and exact legacy email proofs cannot authorize multiple-account completion or recovery")
    @MainActor
    func copiedOwnershipProofIsAmbiguous() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let todo = Todo(id: identifier, source: .email, sourceRef: "message+42")
        todo.calendarEventExternalID = "copied-external-id"
        let store = EKEventStore()
        let proofs = [
            try #require(CalendarEventMarker.url(entity: .todo, identifier: identifier, origin: .siftEmail)),
            try #require(URL(string: "sift-todo://todo/\(identifier.uuidString)")),
            try #require(URL(string: "x-todoapp-email://message%2B42"))
        ]
        for proof in proofs {
            let original = ownershipCandidate(in: store, url: proof)
            let copied = ownershipCandidate(in: store, url: proof, title: "Other account copy")
            for candidates in [[original, copied], [copied, original]] {
                #expect(throws: CalendarError.ownershipNotVerified) {
                    try CalendarService.selectOwnedEvent(for: todo, candidates: candidates)
                }
            }
            // The same EventKit event found via local ID, external ID and email
            // mapping is not ambiguous; genuinely distinct copies are.
            let selected = try #require(try CalendarService.selectOwnedEvent(for: todo, candidates: [original, original]))
            #expect(selected === original)
            #expect(original.url == proof && copied.url == proof)
            #expect(copied.title == "Other account copy")
        }
    }

    @Test("unavailable external references refuse duplicate creation while a new Todo can be exported")
    @MainActor
    func missingExternalAccountDoesNotBecomeANewExport() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let todo = Todo(id: identifier, title: "Existing export")
        todo.calendarEventExternalID = "temporarily-unavailable-account-id"
        #expect(throws: CalendarError.ownershipNotVerified) {
            try CalendarService.selectOwnedEvent(for: todo, candidates: [])
        }
        #expect(todo.calendarEventExternalID == "temporarily-unavailable-account-id")
        todo.calendarEventExternalID = ""
        #expect(try CalendarService.selectOwnedEvent(for: todo, candidates: []) == nil)
    }

    @Test("normal, health and legacy ownership resolve without changing source protection")
    @MainActor
    func matchingOwnershipRetainsLegitimateLinks() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let todo = Todo(id: identifier, source: .email, sourceRef: "message+42")
        let store = EKEventStore()
        for origin in [CalendarEventOrigin.siftManual, .siftEmail, .siftMeeting, .siftRecommendation, .siftHealth] {
            let owned = ownershipCandidate(in: store, url: CalendarEventMarker.url(
                entity: .todo, identifier: identifier, origin: origin))
            let selected = try #require(try CalendarService.selectOwnedEvent(for: todo, candidates: [owned]))
            #expect(selected === owned)
            #expect(CalendarService.completionAction(for: todo, eventURL: owned.url, requested: .remove) == .remove)
            #expect(todo.sourceRef == "message+42")
        }
        let legacy = ownershipCandidate(in: store, url: URL(string: "x-todoapp-email://message%2B42"))
        #expect(try CalendarService.selectOwnedEvent(for: todo, candidates: [legacy]) === legacy)
        #expect(todo.sourceRef == "message+42")
    }

    @Test("unresolvable email artifacts preserve the cross-device identifier")
    @MainActor
    func unresolvableEmailArtifactsPreserveExternalIdentifier() {
        let todo = Todo(
            title: "CalendarServiceTests",
            source: .email,
            sourceRef: "CalendarServiceTests.\(UUID().uuidString)"
        )
        todo.calendarEventExternalID = "external.\(UUID().uuidString)"

        #expect(!CalendarService.shared.removeEmailCalendarArtifacts(for: todo))
        #expect(todo.calendarEventID == nil)
        #expect(todo.calendarEventExternalID.hasPrefix("external."))
    }

    @Test("stale local email identifiers preserve all calendar references")
    @MainActor
    func staleLocalEmailIdentifiersDoNotClearReferences() {
        let todo = Todo(
            title: "CalendarServiceTests",
            source: .email,
            sourceRef: "CalendarServiceTests.\(UUID().uuidString)"
        )
        let staleEventID = UUID().uuidString
        let externalID = "external.\(UUID().uuidString)"
        todo.calendarEventID = staleEventID
        todo.calendarEventExternalID = externalID

        #expect(!CalendarService.shared.removeEmailCalendarArtifacts(for: todo))
        #expect(todo.calendarEventID == staleEventID)
        #expect(todo.calendarEventExternalID == externalID)
    }

    @Test("email mapping reconciliation removes stale identifiers and stores replacements")
    func emailMappingReconciliationUpdatesOnlyTargetReference() {
        let mapping = ["message-1": "stale-event", "message-2": "active-event"]

        let removed = CalendarService.reconciledEmailEventMapping(
            mapping,
            for: "message-1",
            resolvedIdentifier: nil
        )
        let replaced = CalendarService.reconciledEmailEventMapping(
            removed,
            for: "message-1",
            resolvedIdentifier: "current-event"
        )

        #expect(removed["message-1"] == nil)
        #expect(removed["message-2"] == "active-event")
        #expect(replaced["message-1"] == "current-event")
        #expect(replaced["message-2"] == "active-event")
    }

    @Test("versioned SIFT event marker preserves ownership across installations")
    func versionedMarkerRoundTripsOwnership() {
        let identifier = UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A")!
        let url = CalendarEventMarker.url(
            entity: .todo,
            identifier: identifier,
            origin: .siftRecommendation
        )
        let marker = CalendarEventMarker.parse(url)

        #expect(marker?.entity == .todo)
        #expect(marker?.identifier == identifier)
        #expect(marker?.origin == .siftRecommendation)
    }

    @Test("legacy SIFT marker is restored as SIFT-owned rather than external")
    func legacyMarkerRetainsOwnership() {
        let identifier = UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1")!
        let url = URL(string: "sift-todo://todo/\(identifier.uuidString)")

        let marker = CalendarEventMarker.parse(url)

        #expect(marker?.entity == .todo)
        #expect(marker?.identifier == identifier)
        #expect(marker?.origin == .siftManual)
    }

    private func recoveryEvent(
        marker: CalendarEventMarker?,
        identifier: String = "device-event",
        calendarID: String = "chosen-calendar"
    ) -> CalendarService.CalendarEventSummary {
        CalendarService.CalendarEventSummary(
            title: "Exported routine",
            notes: "Explicitly exported details",
            startDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
            endDate: Date(timeIntervalSinceReferenceDate: 800_003_600),
            isRecurring: false,
            isAllDay: false,
            identifier: identifier,
            externalIdentifier: "cross-device-event",
            marker: marker,
            calendarTitle: "Chosen calendar",
            calendarID: calendarID
        )
    }

    @Test("marker-based sync refuses copied Todo identity but accepts repeated occurrences of one event")
    func markerRecoveryDoesNotRebindAcrossAccounts() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let marker = CalendarEventMarker(entity: .todo, identifier: identifier, origin: .siftHealth)
        let original = recoveryEvent(marker: marker)
        let copied = recoveryEvent(marker: marker, identifier: "other-account-event", calendarID: "other-account-calendar")
        #expect(CalendarService.ambiguousTodoMarkerIDs(in: [original, original]).isEmpty)
        #expect(CalendarService.ambiguousTodoMarkerIDs(in: [original, copied]) == Set([identifier]))
        #expect(CalendarService.ambiguousTodoMarkerIDs(in: [copied, original]) == Set([identifier]))
    }

    @Test("explicit health export survives marker parsing and missing-Todo recovery")
    @MainActor
    func exportedHealthMarkerRestoresPrivacy() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let store = EKEventStore()
        // Old stored origins must not mask health provenance on the next explicit export.
        for storedOrigin in ["", "siftManual", "siftRecommendation", "siftEmail", "siftMeeting", "siftHealth"] {
            for sourceRef in ["health:workout:occurrence", "HeAlTh:sleep:occurrence"] {
                let original = Todo(id: identifier, title: "Private routine", sourceRef: sourceRef)
                original.calendarEventOrigin = storedOrigin
                original.aiRecommendedTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
                let exportedEvent = EKEvent(eventStore: store)
                CalendarService.applySiftMarker(to: exportedEvent, for: original)
                let marker = try #require(CalendarEventMarker.parse(exportedEvent.url))
                #expect(marker.origin == .siftHealth)
                #expect(original.calendarEventOrigin == CalendarEventOrigin.siftHealth.rawValue)
                #expect(original.sourceRef == sourceRef)

                // No original Todo is supplied to the production recovery transformation.
                let summary = recoveryEvent(marker: marker)
                let restored = try #require(CalendarService.restoredTodo(from: summary))
                #expect(restored.id == identifier)
                #expect(restored.todoSource == .manual)
                #expect(restored.sourceRef == "health:calendar/\(identifier.uuidString)")
                #expect(restored.calendarOrigin == .siftHealth)
                #expect(restored.isHealthRelated)
                #expect(restored.hasLocalOnlySourceContent)
                #expect(restored.title == summary.title && restored.notes == summary.notes)
                #expect(restored.startDate == summary.startDate && restored.dueDate == summary.endDate)
                #expect(restored.calendarEventID == summary.identifier)
                #expect(restored.calendarEventExternalID == summary.externalIdentifier)
                #expect(restored.calendarSyncedTitle == summary.title)
                #expect(!CalendarService.isAutomaticRegistrationCandidate(
                    restored, autoEnabled: true, sourceFilter: "all"
                ))
                #expect(CalendarService.completionAction(
                    for: restored, eventURL: exportedEvent.url, requested: .remove
                ) == .remove)
            }
        }
    }

    @Test("relinking retains existing health references even with older generic markers")
    @MainActor
    func relinkingPreservesHealthSourceReference() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        for origin in [CalendarEventOrigin.siftHealth, .siftManual, .siftRecommendation] {
            let marker = CalendarEventMarker(entity: .todo, identifier: identifier, origin: origin)
            let originalRef = "HeAlTh:workout:approved-occurrence"
            let linked = Todo(id: identifier, sourceRef: originalRef)
            linked.isCompleted = true
            CalendarService.adoptRecoveredMarker(marker, for: linked)
            #expect(linked.sourceRef == originalRef)
            #expect(linked.calendarOrigin == .siftHealth)
            #expect(linked.isCompleted)
        }
        let stale = Todo(id: identifier, sourceRef: "sift-calendar://todo/\(identifier.uuidString)")
        stale.calendarEventOrigin = CalendarEventOrigin.siftHealth.rawValue
        let oldMarker = CalendarEventMarker(entity: .todo, identifier: identifier, origin: .siftManual)
        #expect(CalendarService.adoptRecoveredMarker(oldMarker, for: stale))
        #expect(stale.sourceRef.hasPrefix("health:"))
        #expect(stale.calendarOrigin == .siftHealth)
    }

    @Test("normal and legacy exports retain non-health recovery behavior")
    @MainActor
    func ordinaryMarkersRetainRecoveryBehavior() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let store = EKEventStore()
        for source in [TodoSource.manual, .email, .meeting] {
            let todo = Todo(id: identifier, source: source)
            let event = EKEvent(eventStore: store)
            CalendarService.applySiftMarker(to: event, for: todo)
            let marker = try #require(CalendarEventMarker.parse(event.url))
            #expect(marker.origin == CalendarEventOrigin.inferred(from: todo))
            let restored = try #require(CalendarService.restoredTodo(from: recoveryEvent(marker: marker)))
            #expect(restored.sourceRef == "sift-calendar://todo/\(identifier.uuidString)")
            #expect(!restored.isHealthRelated)
        }
        let legacy = try #require(CalendarEventMarker.parse(URL(string: "sift-todo://todo/\(identifier.uuidString)")))
        let restored = try #require(CalendarService.restoredTodo(from: recoveryEvent(marker: legacy)))
        #expect(restored.calendarOrigin == .siftManual)
        #expect(restored.sourceRef == "sift-calendar://todo/\(identifier.uuidString)")
        #expect(CalendarService.isAutomaticRegistrationCandidate(restored, autoEnabled: true, sourceFilter: "all"))
    }

    @Test("health provenance never grants ownership to external or standalone events")
    @MainActor
    func healthMarkersRespectOwnershipBoundaries() throws {
        let identifier = try #require(UUID(uuidString: "1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A"))
        let todo = Todo(id: identifier, source: .calendar, sourceRef: "health:imported")
        let event = EKEvent(eventStore: EKEventStore())
        let externalURL = try #require(URL(string: "https://example.com/event"))
        event.url = externalURL
        CalendarService.applySiftMarker(to: event, for: todo)
        #expect(event.url == externalURL)
        for marker in [
            CalendarEventMarker(entity: .standaloneEvent, identifier: identifier, origin: .siftHealth),
            CalendarEventMarker(entity: .todo, identifier: identifier, origin: .externalCalendar)
        ] {
            #expect(CalendarService.restoredTodo(from: recoveryEvent(marker: marker)) == nil)
            #expect(!CalendarService.adoptRecoveredMarker(marker, for: todo))
            let url = CalendarEventMarker.url(entity: marker.entity, identifier: marker.identifier, origin: marker.origin)
            #expect(CalendarService.completionAction(for: todo, eventURL: url, requested: .remove) == .keep)
        }
        #expect(CalendarService.restoredTodo(from: recoveryEvent(marker: nil)) == nil)
        let otherID = try #require(UUID(uuidString: "B31BE1ED-BC94-49B0-BD8F-B389D16457E1"))
        let unrelated = CalendarEventMarker(entity: .todo, identifier: otherID, origin: .siftHealth)
        #expect(!CalendarService.adoptRecoveredMarker(unrelated, for: todo))
        let unrelatedURL = CalendarEventMarker.url(entity: .todo, identifier: otherID, origin: .siftHealth)
        #expect(CalendarService.completionAction(for: todo, eventURL: unrelatedURL, requested: .remove) == .keep)
    }

    @Test("recovered health completions never train ordinary routines")
    @MainActor
    func recoveredHealthTodosStayOutOfOrdinaryLearning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var healthRows: [Todo] = []
        var ordinaryRows: [Todo] = []
        let identifiers = ["1A5E7D6C-7D98-4DDE-B9DE-42AD58D2FC1A", "B31BE1ED-BC94-49B0-BD8F-B389D16457E1", "92566BD1-394E-4978-89E8-FB81D44C6794"]
        for (day, rawID) in identifiers.enumerated() {
            let identifier = try #require(UUID(uuidString: rawID))
            let completed = base.addingTimeInterval(Double(day) * 86_400)
            for origin in [CalendarEventOrigin.siftHealth, .siftManual] {
                let marker = CalendarEventMarker(entity: .todo, identifier: identifier, origin: origin)
                let recovered = try #require(CalendarService.restoredTodo(from: recoveryEvent(marker: marker)))
                recovered.createdAt = completed.addingTimeInterval(-3600)
                recovered.isCompleted = true
                recovered.completedAt = completed
                if origin == .siftHealth { healthRows.append(recovered) }
                else { ordinaryRows.append(recovered) }
            }
        }
        let now = base.addingTimeInterval(3 * 86_400)
        #expect(RoutineLearningService.learn(todos: healthRows, now: now, calendar: calendar).isEmpty)
        #expect(RoutineLearningService.learn(todos: ordinaryRows, now: now, calendar: calendar).count == 1)
    }

    @Test("calendar origin preserves external import and explicit SIFT recommendation")
    @MainActor
    func calendarOriginUsesStoredOrSafeInferredValue() {
        let imported = Todo(title: "Imported", source: .calendar)
        imported.aiRecommendedTime = Date()
        let recommended = Todo(title: "Recommended")
        recommended.aiRecommendedTime = Date()
        let recovered = Todo(title: "Recovered")
        recovered.calendarEventOrigin = CalendarEventOrigin.siftMeeting.rawValue

        #expect(imported.calendarOrigin == .externalCalendar)
        #expect(recommended.calendarOrigin == .siftRecommendation)
        #expect(recovered.calendarOrigin == .siftMeeting)
    }

    @Test("Firebase snapshot keeps calendar event provenance")
    @MainActor
    func firebaseSnapshotRoundTripsCalendarProvenance() throws {
        let sourceConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [sourceConfiguration]
        )
        let sourceContext = ModelContext(sourceContainer)
        let todo = Todo(title: "Recommendation")
        todo.calendarEventOrigin = CalendarEventOrigin.siftRecommendation.rawValue
        todo.calendarSyncedTitle = "Synced calendar title"
        sourceContext.insert(todo)
        try sourceContext.save()

        let json = try FirebaseSnapshotStore.exportJSON(context: sourceContext)

        let targetConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [targetConfiguration]
        )
        let targetContext = ModelContext(targetContainer)
        try FirebaseSnapshotStore.importJSON(json, context: targetContext)

        let restored = try #require(
            targetContext.fetch(FetchDescriptor<Todo>()).first
        )
        #expect(restored.calendarOrigin == .siftRecommendation)
        #expect(restored.calendarSyncedTitle == "Synced calendar title")
    }

    @Test("Calendar title adoption respects the local rename baseline")
    func calendarTitleAdoptionRespectsBaseline() {
        // 사용자가 로컬에서 이름을 바꿨고 이벤트는 그대로 → 덮어쓰지 않는다
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅") == false)
        // 캘린더 쪽이 실제로 바뀜 → 채택
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅(변경)") == true)
        // 이미 같은 값 → 변경 없음
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "정기 미팅", syncedBaseline: "정기 미팅", eventTitle: "정기 미팅") == false)
        // 기준선 없는 이전 버전 데이터 → 1회 채택
        #expect(CalendarService.shouldAdoptCalendarTitle(todoTitle: "내 이름", syncedBaseline: "", eventTitle: "정기 미팅") == true)
    }

    @Test("deleted imported occurrences remove active tasks but preserve completed and out-of-window items")
    @MainActor
    func missingImportedOccurrenceReconciliationIsScoped() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let kept = Todo(
            title: "Kept",
            dueDate: now.addingTimeInterval(3_600),
            source: .calendar,
            sourceRef: "calendar-id#kept"
        )
        let missing = Todo(
            title: "Missing",
            dueDate: now.addingTimeInterval(7_200),
            source: .calendar,
            sourceRef: "calendar-id#missing"
        )
        kept.triageStatus = TodoTriage.review.rawValue
        missing.triageStatus = TodoTriage.review.rawValue
        let active = Todo(title: "Active", dueDate: now.addingTimeInterval(7_200), source: .calendar, sourceRef: "calendar-id#active")
        let approved = Todo(title: "Approved", dueDate: now.addingTimeInterval(7_200), source: .calendar, sourceRef: "calendar-id#approved")
        approved.manualPriority = TodoPriority.high.rawValue
        active.calendarSourceID = "available-source"
        approved.calendarSourceID = "available-source"
        let completed = Todo(
            title: "Completed",
            dueDate: now.addingTimeInterval(10_800),
            source: .calendar,
            sourceRef: "calendar-id#completed"
        )
        completed.isCompleted = true
        completed.triageStatus = TodoTriage.review.rawValue
        let outsideWindow = Todo(
            title: "Later",
            dueDate: now.addingTimeInterval(31 * 86_400),
            source: .calendar,
            sourceRef: "calendar-id#later"
        )
        outsideWindow.triageStatus = TodoTriage.review.rawValue
        let pastOccurrence = Todo(
            title: "Still Active in Calendar",
            dueDate: now.addingTimeInterval(-3_600),
            source: .calendar,
            sourceRef: "calendar-id#past"
        )
        pastOccurrence.triageStatus = TodoTriage.review.rawValue
        let manual = Todo(
            title: "Manual",
            dueDate: now.addingTimeInterval(7_200),
            source: .manual,
            sourceRef: "calendar-id#manual"
        )
        manual.triageStatus = TodoTriage.review.rawValue

        let missingIDs = CalendarService.missingImportedTodoIDs(
            from: [kept, missing, active, approved, completed, outsideWindow, pastOccurrence, manual],
            observedOccurrenceRefs: [kept.sourceRef],
            availableCalendarIDs: ["available-source"],
            now: now
        )

        #expect(missingIDs == Set([missing.id, active.id, approved.id]))
    }

    @Test("deleted imported occurrence preserves items whose external ID is still observed on other devices")
    @MainActor
    func missingImportedOccurrencePreservesCrossDeviceExternalIDs() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let crossDeviceTodo = Todo(
            title: "Created on macOS",
            dueDate: now.addingTimeInterval(3_600),
            source: .calendar,
            sourceRef: "macos-device-local-id#2026-09-18"
        )
        crossDeviceTodo.calendarEventExternalID = "shared-caldav-guid-123"
        crossDeviceTodo.triageStatus = TodoTriage.review.rawValue

        // On iOS, the local occurrence ref is "ios-device-local-id#2026-09-18", but the CalDAV external ID matches
        let missingIDs = CalendarService.missingImportedTodoIDs(
            from: [crossDeviceTodo],
            observedOccurrenceRefs: ["ios-device-local-id#2026-09-18"],
            observedExternalIDs: ["shared-caldav-guid-123"],
            now: now
        )

        #expect(missingIDs.isEmpty)
    }

    @Test("todoWindow maps timed events to a start/deadline pair and collapses all-day or zero-length events")
    func todoWindowMapsEventTimeInformation() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let end = start.addingTimeInterval(3_600)

        let timed = CalendarService.todoWindow(eventStart: start, eventEnd: end, isAllDay: false)
        #expect(timed.startDate == start)
        #expect(timed.dueDate == end)

        let allDay = CalendarService.todoWindow(eventStart: start, eventEnd: end, isAllDay: true)
        #expect(allDay.startDate == nil)
        #expect(allDay.dueDate == start)

        let zeroLength = CalendarService.todoWindow(eventStart: start, eventEnd: start, isAllDay: false)
        #expect(zeroLength.startDate == nil)
        #expect(zeroLength.dueDate == start)
    }

    @Test("eventWindow projects a Todo's start/deadline onto a calendar range")
    func eventWindowProjectsTodoSchedule() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(7_200)

        let ranged = CalendarService.eventWindow(todoStart: start, todoDue: due)
        #expect(ranged?.start == start)
        #expect(ranged?.end == due)

        let legacy = CalendarService.eventWindow(todoStart: nil, todoDue: start)
        #expect(legacy?.start == start)
        #expect(legacy?.end == start.addingTimeInterval(CalendarService.defaultTodoEventDuration))

        let invalidPair = CalendarService.eventWindow(todoStart: due, todoDue: start)
        #expect(invalidPair?.start == start)
        #expect(invalidPair?.end == start.addingTimeInterval(CalendarService.defaultTodoEventDuration))

        #expect(CalendarService.eventWindow(todoStart: start, todoDue: nil) == nil)
    }

    @Test("adoptedTodoWindow only adopts upstream calendar changes that move a Todo's projected range")
    func adoptedTodoWindowSkipsUnchangedProjectionsAndAdoptsRealMoves() {
        let due = Date(timeIntervalSinceReferenceDate: 900_000_000)

        // 마감만 있는 기존 to-do의 1시간 투영과 이벤트가 일치 → 채택하지 않는다
        let unchanged = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: due,
            eventEnd: due.addingTimeInterval(3_600),
            isAllDay: false
        )
        #expect(unchanged == nil)

        // 이벤트 종료가 실제로 옮겨짐 → 채택
        let changedEnd = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: due,
            eventEnd: due.addingTimeInterval(5_400),
            isAllDay: false
        )
        #expect(changedEnd?.startDate == due)
        #expect(changedEnd?.dueDate == due.addingTimeInterval(5_400))

        // 이벤트 시작이 실제로 옮겨짐 → 채택
        let movedStart = due.addingTimeInterval(7_200)
        let changedStart = CalendarService.adoptedTodoWindow(
            todoStart: nil,
            todoDue: due,
            eventStart: movedStart,
            eventEnd: movedStart.addingTimeInterval(3_600),
            isAllDay: false
        )
        #expect(changedStart?.startDate == movedStart)
        #expect(changedStart?.dueDate == movedStart.addingTimeInterval(3_600))

        // 구간이 있는 to-do 대비 0.4초 왕복 오차만 있는 이벤트 → 허용 오차 내이므로 채택하지 않는다
        let rangedStart = due
        let rangedDue = due.addingTimeInterval(7_200)
        let withinTolerance = CalendarService.adoptedTodoWindow(
            todoStart: rangedStart,
            todoDue: rangedDue,
            eventStart: rangedStart.addingTimeInterval(0.4),
            eventEnd: rangedDue.addingTimeInterval(0.4),
            isAllDay: false
        )
        #expect(withinTolerance == nil)

        // 구간이 있는 to-do 대비 종일 이벤트로 바뀜 → 종료 시각 의도가 사라지므로 채택
        let becameAllDay = CalendarService.adoptedTodoWindow(
            todoStart: rangedStart,
            todoDue: rangedDue,
            eventStart: rangedStart,
            eventEnd: rangedDue,
            isAllDay: true
        )
        #expect(becameAllDay?.startDate == nil)
        #expect(becameAllDay?.dueDate == rangedStart)
    }

    @Test("Firebase snapshot keeps a Todo's start time alongside its deadline")
    @MainActor
    func firebaseSnapshotRoundTripsStartDate() throws {
        let sourceConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [sourceConfiguration]
        )
        let sourceContext = ModelContext(sourceContainer)
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(3_600)
        let todo = Todo(title: "Ranged", startDate: start, dueDate: due)
        sourceContext.insert(todo)
        try sourceContext.save()

        let json = try FirebaseSnapshotStore.exportJSON(context: sourceContext)

        let targetConfiguration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(
            for: AppDataContainer.appSchema,
            configurations: [targetConfiguration]
        )
        let targetContext = ModelContext(targetContainer)
        try FirebaseSnapshotStore.importJSON(json, context: targetContext)

        let restored = try #require(
            targetContext.fetch(FetchDescriptor<Todo>()).first
        )
        #expect(restored.startDate == start)
        #expect(restored.dueDate == due)
    }

    @Test("Todo.scheduleAnchor and scheduledRange derive from start/deadline pairing")
    @MainActor
    func scheduleAnchorAndScheduledRangeReflectStartDeadlinePairing() {
        let start = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let due = start.addingTimeInterval(3_600)

        let ranged = Todo(title: "Ranged", startDate: start, dueDate: due)
        #expect(ranged.scheduleAnchor == start)
        #expect(ranged.scheduledRange?.start == start)
        #expect(ranged.scheduledRange?.end == due)

        let deadlineOnly = Todo(title: "Deadline only", dueDate: due)
        #expect(deadlineOnly.scheduleAnchor == due)
        #expect(deadlineOnly.scheduledRange == nil)

        let invalidPairing = Todo(title: "Invalid pairing", startDate: due, dueDate: start)
        #expect(invalidPairing.scheduleAnchor == due)
        #expect(invalidPairing.scheduledRange == nil)
    }

    @MainActor
    private func importContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            schema: AppDataContainer.appSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.appSchema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func importEvent(
        identifier: String,
        calendarID: String,
        externalIdentifier: String? = nil,
        calendarTitle: String = "Work",
        title: String,
        start: Date,
        isRecurring: Bool = false,
        marker: CalendarEventMarker? = nil
    ) -> CalendarService.CalendarEventSummary {
        CalendarService.CalendarEventSummary(
            title: title,
            notes: "Notes for \(title)",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            isRecurring: isRecurring,
            isAllDay: false,
            identifier: identifier,
            externalIdentifier: externalIdentifier ?? "external-\(identifier)",
            marker: marker,
            calendarTitle: calendarTitle,
            calendarID: calendarID
        )
    }

    @Test("real import uses explicit calendar IDs, not RTX6000 or holiday title heuristics")
    @MainActor
    func reconciliationImportsOnlySelectedSourcesRegardlessOfTitle() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let events = [
            importEvent(identifier: "selected-rtx", calendarID: "rtx", calendarTitle: "RTX6000", title: "GPU reservation", start: now.addingTimeInterval(3_600)),
            importEvent(identifier: "selected-holiday", calendarID: "holidays", calendarTitle: "Holidays", title: "Holiday planning", start: now.addingTimeInterval(7_200)),
            importEvent(identifier: "excluded-work", calendarID: "work", title: "Visible work event", start: now.addingTimeInterval(10_800)),
            importEvent(identifier: "excluded-rtx", calendarID: "other-rtx", calendarTitle: "RTX6000", title: "Other GPU reservation", start: now.addingTimeInterval(14_400)),
            importEvent(identifier: "excluded-holiday", calendarID: "other-holidays", calendarTitle: "Holidays", title: "Other holiday", start: now.addingTimeInterval(18_000))
        ]

        let changed = await CalendarService.shared.syncCalendarTodos(
            context: context, events: events, recoveryEvents: [], now: now,
            selectedCalendarIDs: ["rtx", "holidays"]
        )
        #expect(changed)
        let imported = try context.fetch(FetchDescriptor<Todo>())
        #expect(imported.count == 2)
        #expect(Set(imported.map(\.calendarSourceID)) == ["rtx", "holidays"])
        for event in events.prefix(2) {
            let todo = try #require(imported.first { $0.calendarEventID == event.identifier })
            #expect(todo.title == event.title)
            #expect(todo.todoSource == .calendar && todo.triage == .review && !todo.isCompleted)
            #expect(todo.startDate == event.startDate && todo.dueDate == event.endDate)
            #expect(todo.calendarEventExternalID == event.externalIdentifier)
            #expect(todo.calendarOrigin == .externalCalendar)
            #expect(todo.calendarSyncedTitle == event.title)
        }
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: events, recoveryEvents: [], now: now,
            selectedCalendarIDs: ["rtx", "holidays"]
        )
        #expect(try context.fetch(FetchDescriptor<Todo>()).count == 2)
    }

    @Test("empty or unavailable selections never substitute another same-title calendar")
    @MainActor
    func reconciliationDoesNotInferReplacementConsent() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let replacement = importEvent(
            identifier: "replacement-event", calendarID: "new-calendar-id", calendarTitle: "Work",
            title: "Same account title is not consent", start: now.addingTimeInterval(3_600)
        )
        let selections: [Set<String>] = [[], ["deleted-calendar-id"], ["unavailable-calendar-id"]]
        for selection in selections {
            let context = try importContext()
            let changed = await CalendarService.shared.syncCalendarTodos(
                context: context, events: [replacement], recoveryEvents: [], now: now,
                selectedCalendarIDs: selection
            )
            #expect(!changed)
            #expect(try context.fetch(FetchDescriptor<Todo>()).isEmpty)
        }
    }

    @Test("deselection retains pending suggestions but stops upstream updates and deletion")
    @MainActor
    func deselectionRetainsReviewWithoutUpstreamChanges() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = importEvent(identifier: "event", calendarID: "source", title: "Original", start: now.addingTimeInterval(3_600))
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [original], recoveryEvents: [], now: now, selectedCalendarIDs: ["source"]
        )
        let suggestion = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        let originalID = suggestion.id
        let originalRef = suggestion.sourceRef
        let originalNotes = suggestion.notes
        let changedEvent = importEvent(
            identifier: "event", calendarID: "source", title: "Upstream rename",
            start: now.addingTimeInterval(14_400), isRecurring: true
        )
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [changedEvent], recoveryEvents: [], now: now, selectedCalendarIDs: []
        )
        // Even a later unavailable/excluded scan must not erase the retained suggestion.
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [], recoveryEvents: [], now: now, selectedCalendarIDs: ["different-source"]
        )
        let retained = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        #expect(retained.id == originalID && retained.triage == .review && !retained.isCompleted)
        #expect(retained.notes == originalNotes)
        #expect(retained.title == original.title && retained.calendarSyncedTitle == original.title)
        #expect(retained.startDate == original.startDate && retained.dueDate == original.endDate)
        #expect(!retained.isFixedSchedule)
        #expect(retained.sourceRef == originalRef)
        #expect(retained.calendarEventID == original.identifier)
        #expect(retained.calendarEventExternalID == original.externalIdentifier)
        #expect(retained.calendarSourceID == "source")

        // Selecting it again resumes normal upstream reconciliation, without duplication.
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [changedEvent], recoveryEvents: [], now: now, selectedCalendarIDs: ["source"]
        )
        #expect(try context.fetch(FetchDescriptor<Todo>()).count == 1)
        #expect(retained.id == originalID && retained.triage == .review)
        #expect(retained.title == changedEvent.title && retained.isFixedSchedule)
        #expect(retained.startDate == changedEvent.startDate && retained.dueDate == changedEvent.endDate)
    }

    @Test("a newly selected copied UID cannot delete a task whose original calendar is unavailable", arguments: [false, true])
    @MainActor
    func copiedUIDImportsAfterExcludedSourceDisappears(isRecurring: Bool) async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = importEvent(identifier: "original", calendarID: "excluded", externalIdentifier: "copied-uid",
            title: "Original task", start: now.addingTimeInterval(3_600), isRecurring: isRecurring)
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [original], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["excluded"])
        let originalTask = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        let originalID = originalTask.id
        if isRecurring { originalTask.triageStatus = TodoTriage.todo.rawValue }
        try context.save()
        let copy = importEvent(identifier: "new-copy", calendarID: "selected", externalIdentifier: "copied-uid",
            title: original.title, start: original.startDate, isRecurring: isRecurring)
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [copy], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["selected"])
        await TodoEligibilityReconciler().promoteUpcomingRecurringReviews(
            in: try context.fetch(FetchDescriptor<Todo>()), now: now, selectedCalendarIDs: ["selected"]
        )
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [copy], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["selected"], availableCalendarIDs: ["excluded", "selected"])
        let tasks = try context.fetch(FetchDescriptor<Todo>())
        let imported = try #require(tasks.first { $0.calendarEventID == copy.identifier })
        #expect(imported.id != originalID && imported.calendarSourceID == copy.calendarID)
        #expect(imported.triage == .review && imported.title == copy.title)
        #expect(Set(tasks.map(\.id)) == [originalID, imported.id])
        #expect(originalTask.calendarSourceID == original.calendarID && originalTask.title == original.title)
        #expect(originalTask.triage == (isRecurring ? .todo : .review))
    }

    @Test("copied external IDs cannot replace an excluded calendar suggestion", arguments: [false, true])
    @MainActor
    func copiedCalendarUIDsKeepSeparateSuggestions(sameStart: Bool) async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = importEvent(identifier: "local-a", calendarID: "source-a", externalIdentifier: "shared-uid",
            title: "Excluded original", start: now.addingTimeInterval(3_600))
        let copy = importEvent(identifier: "local-b", calendarID: "source-b", externalIdentifier: "shared-uid",
            title: "Selected copy", start: original.startDate.addingTimeInterval(sameStart ? 0 : 3_600))
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [original], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a"])
        let retained = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        let originalID = retained.id
        for selection: Set<String> in [["source-b"], ["source-a", "source-b"]] {
            _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [original, copy], recoveryEvents: [],
                now: now, selectedCalendarIDs: selection)
            let todos = try context.fetch(FetchDescriptor<Todo>())
            #expect(Set(todos.compactMap(\.calendarEventID)) == ["local-a", "local-b"])
            #expect(todos.count == 2)
            #expect(retained.id == originalID && retained.title == original.title && retained.triage == .review)
            #expect(retained.calendarSourceID == original.calendarID && retained.startDate == original.startDate)
            let importedCopy = try #require(todos.first { $0.calendarEventID == copy.identifier })
            #expect(importedCopy.title == copy.title && importedCopy.startDate == copy.startDate)
            #expect(importedCopy.calendarSourceID == copy.calendarID)
        }

        let beforeRestart = try context.fetch(FetchDescriptor<Todo>())
        let expectedIDs = Set(beforeRestart.map(\.id))
        let idsBySource = Dictionary(uniqueKeysWithValues: beforeRestart.map { ($0.calendarSourceID, $0.id) })
        let approvedCopy = try #require(beforeRestart.first { $0.calendarSourceID == copy.calendarID })
        approvedCopy.triageStatus = TodoTriage.todo.rawValue
        approvedCopy.manualPriority = TodoPriority.high.rawValue
        try context.save()
        todoApp.deduplicateCalendarTodos(context: context)
        #expect(Set(try context.fetch(FetchDescriptor<Todo>()).map(\.id)) == expectedIDs)

        let rotated = [original, copy].map { event in
            importEvent(identifier: "rotated-\(event.calendarID)", calendarID: event.calendarID,
                externalIdentifier: event.externalIdentifier, title: event.title, start: event.startDate)
        }
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: rotated, recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a", "source-b"])
        todoApp.deduplicateCalendarTodos(context: context)
        let afterRotation = try context.fetch(FetchDescriptor<Todo>())
        #expect(Set(afterRotation.map(\.id)) == expectedIDs)
        for event in rotated {
            let task = try #require(afterRotation.first { $0.calendarEventID == event.identifier })
            #expect(task.id == idsBySource[event.calendarID])
            #expect(task.title == event.title && task.startDate == event.startDate)
        }

        let survivingCopy = try #require(rotated.first { $0.calendarID == copy.calendarID })
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [survivingCopy], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-b"])
        todoApp.deduplicateCalendarTodos(context: context)
        #expect(Set(try context.fetch(FetchDescriptor<Todo>()).map(\.id)) == expectedIDs)
        #expect(retained.calendarSourceID == original.calendarID && retained.title == original.title)

        // An unapproved peer cannot authorize deletion of an approved task.
        let remainingOriginal = try #require(rotated.first { $0.calendarID == original.calendarID })
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [remainingOriginal], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a", "source-b"], availableCalendarIDs: ["source-a", "source-b"])
        todoApp.deduplicateCalendarTodos(context: context)
        #expect(Set(try context.fetch(FetchDescriptor<Todo>()).map(\.id)) == expectedIDs)
        retained.triageStatus = TodoTriage.todo.rawValue
        try context.save()
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [remainingOriginal], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a", "source-b"], availableCalendarIDs: ["source-a", "source-b"])
        todoApp.deduplicateCalendarTodos(context: context)
        let afterDeletion = try context.fetch(FetchDescriptor<Todo>())
        #expect(afterDeletion.map(\.id) == [originalID])
        #expect(retained.calendarSourceID == original.calendarID && retained.title == original.title)
    }

    @Test("missing upstream events remove active imported tasks independently of source selection", arguments: [false, true])
    @MainActor
    func realReconciliationCleanupRemovesActiveUserTasks(sourcesSelected: Bool) async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let events = ["review", "active", "approved", "completed"].enumerated().map { index, title in
            importEvent(identifier: title, calendarID: "source", title: title, start: now.addingTimeInterval(Double(index + 1) * 3_600))
        }
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: events, recoveryEvents: [], now: now, selectedCalendarIDs: ["source"]
        )
        let todos = try context.fetch(FetchDescriptor<Todo>())
        #expect(todos.count == 4)
        let reviewID = try #require(todos.first { $0.title == "review" }).id
        let active = try #require(todos.first { $0.title == "active" })
        active.triageStatus = TodoTriage.todo.rawValue
        let approved = try #require(todos.first { $0.title == "approved" })
        approved.triageStatus = TodoTriage.todo.rawValue
        approved.manualPriority = TodoPriority.high.rawValue
        let completed = try #require(todos.first { $0.title == "completed" })
        completed.isCompleted = true
        completed.completedAt = now
        try context.save()

        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [], recoveryEvents: [], now: now,
            selectedCalendarIDs: sourcesSelected ? ["source"] : [], availableCalendarIDs: ["source"]
        )
        let retained = try context.fetch(FetchDescriptor<Todo>())
        var expectedIDs: Set<UUID> = [completed.id]
        if !sourcesSelected { expectedIDs.insert(reviewID) }
        #expect(Set(retained.map(\.id)) == expectedIDs)
        #expect(completed.isCompleted && completed.completedAt == now)
    }

    @Test("restored and unavailable-source approved tasks survive empty and foreign calendar observations")
    @MainActor
    func missingApprovedTasksRequireLocalCalendarAvailability() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let restored = Todo(title: "Restored task", dueDate: now.addingTimeInterval(3_600),
            source: .calendar, sourceRef: "restored#occurrence")
        restored.calendarEventExternalID = "shared-copy"
        let foreign = Todo(title: "Unavailable task", dueDate: now.addingTimeInterval(3_600),
            source: .calendar, sourceRef: "foreign#occurrence")
        foreign.calendarSourceID = "unavailable-account"
        foreign.calendarEventExternalID = "shared-copy"
        foreign.manualPriority = TodoPriority.high.rawValue
        context.insert(restored)
        context.insert(foreign)
        try context.save()
        let ids: Set<UUID> = [restored.id, foreign.id]
        let peer = importEvent(identifier: "peer", calendarID: "available-account", externalIdentifier: "shared-copy",
            title: "Other calendar copy", start: now.addingTimeInterval(7_200))
        for events in [[], [peer]] {
            _ = await CalendarService.shared.syncCalendarTodos(context: context, events: events, recoveryEvents: [],
                now: now, selectedCalendarIDs: [], availableCalendarIDs: ["available-account"])
            let tasks = try context.fetch(FetchDescriptor<Todo>())
            #expect(Set(tasks.map(\.id)) == ids)
            #expect(foreign.title == "Unavailable task" && foreign.calendarSourceID == "unavailable-account")
            #expect(foreign.triage == .todo && foreign.manualPriority == TodoPriority.high.rawValue)
        }
    }

    @Test("a unique upstream calendar move preserves the approved task UUID and priority")
    @MainActor
    func approvedCalendarMoveReconcilesWithoutAnalysisSelection() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = importEvent(identifier: "before-move", calendarID: "source-a", externalIdentifier: "moved-uid",
            title: "Original title", start: now.addingTimeInterval(3_600))
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [original], recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a"], availableCalendarIDs: ["source-a", "source-b"])
        let task = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        let id = task.id
        task.triageStatus = TodoTriage.todo.rawValue
        task.manualPriority = TodoPriority.high.rawValue
        try context.save()
        let moved = importEvent(identifier: "after-move", calendarID: "source-b", externalIdentifier: "moved-uid",
            title: "Moved title", start: now.addingTimeInterval(7_200))
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [moved], recoveryEvents: [],
            now: now, selectedCalendarIDs: [], availableCalendarIDs: ["source-a", "source-b"])
        let tasks = try context.fetch(FetchDescriptor<Todo>())
        #expect(tasks.map(\.id) == [id])
        #expect(task.title == moved.title && task.startDate == moved.startDate && task.dueDate == moved.endDate)
        #expect(task.triage == .todo && task.manualPriority == TodoPriority.high.rawValue)
        #expect(task.calendarSourceID == moved.calendarID && task.calendarEventID == moved.identifier)
    }

    @Test("a third-calendar copied UID cannot merge two previously approved tasks", arguments: [false, true])
    @MainActor
    func ambiguousCalendarMovePreservesApprovedTasks(selectNewSource: Bool) async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let originals = ["source-a", "source-b"].map { source in
            importEvent(identifier: "local-\(source)", calendarID: source, externalIdentifier: "shared-uid",
                title: "Task \(source)", start: now.addingTimeInterval(3_600))
        }
        _ = await CalendarService.shared.syncCalendarTodos(context: context, events: originals, recoveryEvents: [],
            now: now, selectedCalendarIDs: ["source-a", "source-b"], availableCalendarIDs: ["source-a", "source-b"])
        let approved = try context.fetch(FetchDescriptor<Todo>())
        #expect(approved.count == 2)
        let idsBySource = Dictionary(uniqueKeysWithValues: approved.map { ($0.calendarSourceID, $0.id) })
        for task in approved {
            task.triageStatus = TodoTriage.todo.rawValue
            task.manualPriority = TodoPriority.high.rawValue
        }
        try context.save()
        let newCopy = importEvent(identifier: "local-c", calendarID: "source-c", externalIdentifier: "shared-uid",
            title: "New copied event", start: now.addingTimeInterval(3_600), isRecurring: true)
        for _ in 0..<2 {
            _ = await CalendarService.shared.syncCalendarTodos(context: context, events: [newCopy], recoveryEvents: [],
                now: now, selectedCalendarIDs: selectNewSource ? ["source-c"] : [],
                availableCalendarIDs: ["source-a", "source-b", "source-c"])
            await TodoEligibilityReconciler().promoteUpcomingRecurringReviews(
                in: try context.fetch(FetchDescriptor<Todo>()), now: now,
                selectedCalendarIDs: selectNewSource ? ["source-c"] : []
            )
            todoApp.deduplicateCalendarTodos(context: context)
        }
        let tasks = try context.fetch(FetchDescriptor<Todo>())
        #expect(tasks.count == (selectNewSource ? 3 : 2))
        for event in originals {
            let task = try #require(tasks.first { $0.id == idsBySource[event.calendarID] })
            #expect(task.calendarSourceID == event.calendarID && task.calendarEventID == event.identifier)
            #expect(task.title == event.title && task.startDate == event.startDate && task.dueDate == event.endDate)
            #expect(task.triage == .todo && task.manualPriority == TodoPriority.high.rawValue)
        }
        if selectNewSource {
            let suggestion = try #require(tasks.first { $0.calendarSourceID == "source-c" })
            #expect(suggestion.triage == .review && !Set(idsBySource.values).contains(suggestion.id))
        }
    }

    @Test("external manual links are neither overwritten nor reverse-imported by source selection")
    @MainActor
    func reconciliationKeepsManualLinksIndependent() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = importEvent(identifier: "manual-link", calendarID: "source", title: "External title", start: now.addingTimeInterval(7_200))
        let manual = Todo(title: "My task", notes: "My notes", dueDate: now.addingTimeInterval(3_600))
        manual.calendarEventID = event.identifier
        manual.calendarEventExternalID = event.externalIdentifier
        context.insert(manual)
        try context.save()

        let selections: [Set<String>] = [[], ["source"], ["other-source"]]
        for selection in selections {
            _ = await CalendarService.shared.syncCalendarTodos(
                context: context, events: [event], recoveryEvents: [], now: now, selectedCalendarIDs: selection
            )
            #expect(try context.fetch(FetchDescriptor<Todo>()).count == 1)
            #expect(manual.todoSource == .manual && manual.triage == .todo)
            #expect(manual.title == "My task" && manual.notes == "My notes")
            #expect(manual.dueDate == now.addingTimeInterval(3_600))
            #expect(manual.calendarEventID == event.identifier)
            #expect(manual.calendarEventExternalID == event.externalIdentifier)
        }
    }

    @Test("SIFT-owned marker recovery restores beyond 30 days even with no analysis sources")
    @MainActor
    func recoveryRemainsIndependentOfAnalysisConsent() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let identifier = UUID()
        let marker = CalendarEventMarker(entity: .todo, identifier: identifier, origin: .siftManual)
        let owned = importEvent(
            identifier: "owned-event", calendarID: "unselected", title: "Recovered task",
            start: now.addingTimeInterval(90 * 86_400), marker: marker
        )
        let external = importEvent(identifier: "external", calendarID: "unselected", title: "Do not import", start: now.addingTimeInterval(3_600))
        let standalone = importEvent(
            identifier: "standalone", calendarID: "unselected", title: "Calendar-only event",
            start: now.addingTimeInterval(90 * 86_400),
            marker: CalendarEventMarker(entity: .standaloneEvent, identifier: UUID(), origin: .siftManual)
        )
        let changed = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [external], recoveryEvents: [owned, standalone], now: now, selectedCalendarIDs: []
        )
        #expect(changed)
        let restored = try #require(context.fetch(FetchDescriptor<Todo>()).first)
        #expect(try context.fetch(FetchDescriptor<Todo>()).count == 1)
        #expect(restored.id == identifier && restored.todoSource == .manual)
        #expect(restored.title == owned.title && restored.notes == owned.notes)
        #expect(restored.startDate == owned.startDate && restored.dueDate == owned.endDate)
        #expect(restored.calendarEventID == owned.identifier)
        #expect(restored.calendarEventExternalID == owned.externalIdentifier)
        #expect(restored.calendarOrigin == .siftManual)
        #expect(!CalendarService.isTaskAnalysisEvent(owned, selectedCalendarIDs: []))
    }

    @Test("missing review cleanup is scoped to known currently selected calendar source IDs")
    @MainActor
    func missingReviewCleanupDoesNotTreatDeselectionAsDeletion() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let selected = Todo(title: "Selected", dueDate: now.addingTimeInterval(3_600), source: .calendar, sourceRef: "selected#occurrence")
        let excluded = Todo(title: "Excluded", dueDate: now.addingTimeInterval(3_600), source: .calendar, sourceRef: "excluded#occurrence")
        let legacy = Todo(title: "Unknown source", dueDate: now.addingTimeInterval(3_600), source: .calendar, sourceRef: "legacy#occurrence")
        selected.calendarSourceID = "selected-source"
        excluded.calendarSourceID = "excluded-source"
        for todo in [selected, excluded, legacy] { todo.triageStatus = TodoTriage.review.rawValue }
        let todos = [selected, excluded, legacy]
        #expect(CalendarService.missingImportedTodoIDs(
            from: todos, observedOccurrenceRefs: [], selectedCalendarIDs: ["selected-source"], now: now
        ) == [selected.id])
        #expect(CalendarService.missingImportedTodoIDs(
            from: todos, observedOccurrenceRefs: [], selectedCalendarIDs: [], now: now
        ).isEmpty)
    }

    @Test("approved and completed imports reconcile upstream changes independently of analysis source selection")
    @MainActor
    func approvedUserTasksAdoptUpstreamChangesWithoutAnalysisConsent() async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let events = ["active", "approved", "completed"].enumerated().map { index, title in
            importEvent(identifier: title, calendarID: "source", title: title, start: now.addingTimeInterval(Double(index + 1) * 3_600))
        }
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: events, recoveryEvents: [], now: now, selectedCalendarIDs: ["source"]
        )
        let todos = try context.fetch(FetchDescriptor<Todo>())
        #expect(todos.count == 3)
        for todo in todos {
            if todo.title == "completed" { todo.isCompleted = true }
            else { todo.triageStatus = TodoTriage.todo.rawValue }
            if todo.title == "approved" { todo.manualPriority = TodoPriority.high.rawValue }
        }
        try context.save()
        let movedEvents = events.map { event in
            importEvent(
                identifier: event.identifier, calendarID: event.calendarID, title: "Changed \(event.title)",
                start: event.startDate.addingTimeInterval(86_400), isRecurring: true
            )
        }
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: movedEvents, recoveryEvents: [], now: now, selectedCalendarIDs: []
        )
        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: movedEvents, recoveryEvents: [], now: now, selectedCalendarIDs: ["other-source"]
        )
        let retained = try context.fetch(FetchDescriptor<Todo>())
        #expect(Set(retained.map(\.id)) == Set(todos.map(\.id)))
        for event in movedEvents {
            let todo = try #require(retained.first { $0.calendarEventID == event.identifier })
            #expect(todo.title == event.title && todo.calendarSyncedTitle == event.title)
            #expect(todo.startDate == event.startDate && todo.dueDate == event.endDate)
            #expect(todo.isFixedSchedule)
            #expect(todo.calendarEventExternalID == event.externalIdentifier)
            #expect(todo.calendarSourceID == "source")
            #expect(todo.isCompleted == (event.identifier == "completed"))
            if event.identifier != "completed" { #expect(todo.triage == .todo) }
            if event.identifier == "approved" { #expect(todo.manualPriority == TodoPriority.high.rawValue) }
        }
    }

    @Test("legacy imports gain a local source ID only when observed in an explicitly selected calendar", arguments: [false, true])
    @MainActor
    func legacySourceIDBackfillsOnlyFromConsentedObservation(hasLinkIdentifiers: Bool) async throws {
        let context = try importContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = importEvent(identifier: "legacy", calendarID: "source", title: "Legacy", start: now.addingTimeInterval(3_600))
        let legacy = Todo(
            title: event.title, startDate: event.startDate, dueDate: event.endDate, source: .calendar,
            sourceRef: "\(event.externalIdentifier)#\(ISO8601DateFormatter().string(from: event.startDate))"
        )
        legacy.triageStatus = TodoTriage.review.rawValue
        legacy.calendarEventID = hasLinkIdentifiers ? event.identifier : nil
        legacy.calendarEventExternalID = hasLinkIdentifiers ? event.externalIdentifier : ""
        legacy.calendarSyncedTitle = event.title
        context.insert(legacy)
        try context.save()

        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [event], recoveryEvents: [], now: now, selectedCalendarIDs: ["unavailable-source"]
        )
        #expect(try context.fetch(FetchDescriptor<Todo>()).count == 1)
        #expect(legacy.calendarSourceID.isEmpty)
        #expect(!CalendarService.isTaskAnalysisTodo(legacy, selectedCalendarIDs: ["source"]))

        _ = await CalendarService.shared.syncCalendarTodos(
            context: context, events: [event], recoveryEvents: [], now: now, selectedCalendarIDs: ["source"]
        )
        #expect(try context.fetch(FetchDescriptor<Todo>()).count == 1)
        #expect(legacy.calendarSourceID == "source")
        #expect(CalendarService.isTaskAnalysisTodo(legacy, selectedCalendarIDs: ["source"]))
    }
}
