import XCTest
@testable import Mila

/// Calendar integration: the pure parts that decide what gets synced, what gets
/// stored, and what is allowed to reach an LLM prompt.
///
/// `CalendarEventReader` is deliberately not covered here — it is EventKit's
/// API surface (authorization states and `events(matching:)`), which this
/// target cannot drive. Everything that decision lives on top of is a pure
/// function, so the rules below are pinned without a calendar: eligibility,
/// the attendee ceiling, name sanitising, what the consent flags mean on the
/// stored row, and the two prompt blocks.
@MainActor
final class CalendarIntegrationTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// The same date strategy `RecordingStore` uses (RecordingStore.swift:1828,
    /// :1951) — a bare `JSONDecoder` decodes `Date` as a double and would make
    /// every ISO-8601 fixture below fail for a reason that has nothing to do
    /// with the link.
    private func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func event(title: String = "Weekly sync",
                       body: String? = "Agenda: roadmap",
                       start: Date? = nil,
                       end: Date? = nil,
                       attendees: [String] = [],
                       calendarTitle: String? = "Work",
                       id: String? = "EVT-1") -> CalendarEvent {
        CalendarEvent(id: id,
                      title: title,
                      body: body,
                      start: start ?? t0,
                      end: end ?? t0.addingTimeInterval(1_800),
                      attendeeNames: attendees,
                      calendarTitle: calendarTitle)
    }

    // MARK: - Eligibility (what the button is allowed to offer)

    /// All-day exclusion is a product rule the user asked for, not a
    /// limitation: a birthday or an OOO block spans every moment of its day, so
    /// it would answer "what's happening right now" with noise. Pinned here
    /// because the rule lives in `CalendarEvent`, not in the EventKit mapping.
    func test_isEligible_alwaysExcludesAllDayEvents() {
        let now = t0.addingTimeInterval(600)
        XCTAssertFalse(CalendarEvent.isEligible(start: t0, end: t0.addingTimeInterval(86_400),
                                                isAllDay: true, now: now),
                       "an all-day event overlapping now must never be offered")
        XCTAssertTrue(CalendarEvent.isEligible(start: t0, end: t0.addingTimeInterval(86_400),
                                               isAllDay: false, now: now),
                       "the same span, timed, IS eligible — the exclusion is about all-day, not length")
    }

    /// The two grace windows are exact values, so they are asserted at the
    /// boundary: one minute either side of each flips the answer.
    func test_isEligible_graceWindowsAreExact() {
        // An event that ran out 10 minutes ago still counts (the user hit
        // Record late); 11 minutes ago it does not.
        let justEnded = t0.addingTimeInterval(3_600)
        XCTAssertTrue(CalendarEvent.isEligible(start: t0, end: justEnded,
                                               isAllDay: false,
                                               now: justEnded.addingTimeInterval(CalendarEvent.endedGrace)))
        XCTAssertFalse(CalendarEvent.isEligible(start: t0, end: justEnded,
                                                isAllDay: false,
                                                now: justEnded.addingTimeInterval(CalendarEvent.endedGrace + 60)))
        // Starts in 15 minutes still counts (the user opened Mila early); in
        // 16 it does not.
        XCTAssertTrue(CalendarEvent.isEligible(start: t0.addingTimeInterval(CalendarEvent.upcomingGrace),
                                               end: t0.addingTimeInterval(7_200),
                                               isAllDay: false, now: t0))
        XCTAssertFalse(CalendarEvent.isEligible(start: t0.addingTimeInterval(CalendarEvent.upcomingGrace + 60),
                                                end: t0.addingTimeInterval(7_200),
                                                isAllDay: false, now: t0))
    }

    /// Calendar's zero-length "timed" rows have no span; treating them as
    /// ongoing lets them win the ordering for the whole minute they sit in.
    func test_isEligible_rejectsNonPositiveSpans() {
        XCTAssertFalse(CalendarEvent.isEligible(start: t0, end: t0, isAllDay: false, now: t0))
        XCTAssertFalse(CalendarEvent.isEligible(start: t0.addingTimeInterval(600),
                                                end: t0, isAllDay: false, now: t0))
    }

    /// Two events with no `eventIdentifier` must not be treated as the same
    /// event (`nil == nil` would pick the wrong row in a two-event sheet).
    func test_isSameEvent_survivesUnidentifiedEvents() {
        let a = event(title: "A", id: nil)
        let b = event(title: "B", id: nil)
        XCTAssertFalse(CalendarEvent.isSameEvent(a, b))
        XCTAssertTrue(CalendarEvent.isSameEvent(a, event(title: "A", id: nil)))
        XCTAssertTrue(CalendarEvent.isSameEvent(event(id: "X"), event(id: "X")))
        XCTAssertFalse(CalendarEvent.isSameEvent(event(id: "X"), event(id: "Y")))
    }

    // MARK: - Attendee ceiling and name sanitising

    func test_limitedAttendees_dedupesDropsBlanksCapsAndSorts() {
        let names = ["Yaron", "dana", "", "  Dana  ", "Noa", "Mika", "Or", "Rivka", "Shai",
                     "Tamar", "Udi", "Vera", "Wendy"]
        let capped = CalendarEvent.limitedAttendees(names)
        XCTAssertEqual(capped.count, CalendarEvent.attendeeCeiling,
                       "the safety ceiling must bound a company-wide invite")
        XCTAssertEqual(Set(capped.map(\.lowercased())).count, capped.count,
                       "case-insensitive duplicates must collapse")
        XCTAssertFalse(capped.contains { $0.isEmpty })
        XCTAssertEqual(capped, capped.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(CalendarEvent.limitedAttendees(names, ceiling: 0), [],
                       "a 0 ceiling means offer nothing, not everything")
    }

    /// `Recording.title` doubles as the transcript file name, and Calendar lets
    /// a title carry "/" and newlines — sanitised here, not downstream.
    func test_suggestedRecordingTitle_sanitisesAndCaps() {
        XCTAssertEqual(CalendarEvent.suggestedRecordingTitle(for: event(title: "A/B: Q3 review")),
                       "A-B- Q3 review",
                       "/ and : are replaced because the title is also the transcript file name")
        XCTAssertEqual(CalendarEvent.suggestedRecordingTitle(for: event(title: " line one\nline two ")),
                       "line one line two")
        let long = CalendarEvent.suggestedRecordingTitle(for: event(title: String(repeating: "ab ", count: 100)))
        XCTAssertLessThanOrEqual(long.count, 80)
        XCTAssertTrue(CalendarEvent.suggestedRecordingTitle(for: event(title: "///")).isEmpty,
                       "a title that is only punctuation collapses to \"\" — the caller keeps its own name")
    }

    // MARK: - The stored link: consent, caps, decoding

    /// The row records the CONSENT, not just the event: a later `regenerate`
    /// must not widen what an earlier sync agreed to send.
    func test_calendarLink_storesOnlyWhatWasConsentedTo() {
        let e = event(body: "Agenda: roadmap", attendees: ["Dana", "Yaron"])
        let noAttendees = CalendarLink(event: e, includeAttendees: false, includeBody: true,
                                       maxAttendees: 12, syncedAt: t0)
        XCTAssertEqual(noAttendees.attendees, [])
        XCTAssertEqual(noAttendees.summaryNotes, "Agenda: roadmap")

        let noBody = CalendarLink(event: e, includeAttendees: true, includeBody: false,
                                  maxAttendees: 12, syncedAt: t0)
        XCTAssertNil(noBody.eventBody)
        XCTAssertNil(noBody.summaryNotes)
        XCTAssertEqual(noBody.attendees, ["Dana", "Yaron"])

        let capped = CalendarLink(event: event(attendees: ["A", "B", "C", "D"]),
                                  includeAttendees: true, includeBody: false,
                                  maxAttendees: 2, syncedAt: t0)
        XCTAssertEqual(capped.attendees.count, 2)
    }

    /// An event body is free-form and can be a pasted contract. The cap is
    /// applied where the value is WRITTEN, so the stored row and the prompt can
    /// never disagree, and a hand-edited store can't smuggle a bigger one.
    func test_calendarLink_capsEventBody() {
        let huge = String(repeating: "x", count: CalendarLink.maxBodyCharacters + 500)
        let link = CalendarLink(event: event(body: huge), includeAttendees: false,
                                includeBody: true, maxAttendees: 12, syncedAt: t0)
        let stored = try? XCTUnwrap(link.eventBody)
        XCTAssertEqual(stored?.count, CalendarLink.maxBodyCharacters + 4)
        XCTAssertTrue(stored?.hasSuffix("[…]") ?? false)
    }

    func test_calendarLink_roundTripsThroughJSON() throws {
        let link = CalendarLink(event: event(body: "Agenda", attendees: ["Dana", "Yaron"]),
                                includeAttendees: true, includeBody: true,
                                maxAttendees: 12, syncedAt: t0)
        let data = try storeEncoder().encode(link)
        let decoded = try storeDecoder().decode(CalendarLink.self, from: data)
        XCTAssertEqual(decoded, link)
    }

    /// recordings.json is user-editable and half-written by older builds:
    /// missing optionals are tolerated, and anything that describes no event at
    /// all is rejected rather than guessed at. Caps are re-applied on the way
    /// in, not trusted from the writer.
    func test_calendarLink_decodesLenientlyAndValidates() throws {
        let decoder = storeDecoder()

        let minimal = try decoder.decode(CalendarLink.self, from: Data(
            """
            {"eventTitle":"Solo call","startsAt":"2023-11-14T22:13:20Z","endsAt":"2023-11-14T22:43:20Z"}
            """.utf8))
        XCTAssertEqual(minimal.eventTitle, "Solo call")
        XCTAssertNil(minimal.eventBody)
        XCTAssertEqual(minimal.attendees, [])
        XCTAssertEqual(minimal.syncedAt, minimal.startsAt,
                       "no syncedAt falls back to the start rather than a bogus now")

        let flooded = try decoder.decode(CalendarLink.self, from: Data(
            """
            {"eventTitle":"Town hall","startsAt":"2023-11-14T22:13:20Z","endsAt":"2023-11-14T23:13:20Z",
             "attendees":[\((0..<500).map { "\"Person \\($0)\"" }.joined(separator: ","))],
             "eventBody":"\(String(repeating: "y", count: 9_000))"}
            """.utf8))
        XCTAssertEqual(flooded.attendees.count, CalendarLink.maxStoredAttendees,
                       "a hand-edited invite list cannot size the popover")
        XCTAssertEqual(flooded.eventBody?.count, CalendarLink.maxBodyCharacters + 4)

        // No title, or no span, describes nothing.
        XCTAssertThrowsError(try decoder.decode(CalendarLink.self, from: Data(
            #"{"eventTitle":"   ","startsAt":"2023-11-14T22:13:20Z","endsAt":"2023-11-14T23:13:20Z"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(CalendarLink.self, from: Data(
            #"{"eventTitle":"No dates"}"#.utf8)))
    }

    /// The byte-identity claim for every row that was never synced: the key is
    /// absent, so an existing recordings.json is unchanged by this feature.
    func test_recording_withoutLink_encodesNoCalendarKey() throws {
        let recording = Recording(title: "Plain", source: .microphone, audioFileName: "a.wav")
        let object = try JSONSerialization.jsonObject(with: storeEncoder().encode(recording))
        let keys = Set((object as? [String: Any])?.keys ?? [:].keys)
        XCTAssertFalse(keys.contains("calendarLink"),
                       "an unsynced row must encode exactly as before the field existed")

        let synced = Recording(title: "Plain", source: .microphone, audioFileName: "a.wav",
                               calendarLink: CalendarLink(event: event(), includeAttendees: false,
                                                          includeBody: true, maxAttendees: 12,
                                                          syncedAt: t0))
        let syncedKeys = Set(((try JSONSerialization.jsonObject(with: storeEncoder().encode(synced)))
                              as? [String: Any])?.keys ?? [:].keys)
        XCTAssertTrue(syncedKeys.contains("calendarLink"))
    }

    /// A stored row survives the trip back into the summariser: `regenerate`
    /// months later reads the same notes the original summary saw.
    func test_recording_roundTripsCalendarLink() throws {
        let recording = Recording(title: "Plain", source: .meeting, audioFileName: "a.wav",
                                  calendarLink: CalendarLink(event: event(body: "Agenda: roadmap",
                                                                          attendees: ["Dana"]),
                                                             includeAttendees: true,
                                                             includeBody: true,
                                                             maxAttendees: 12,
                                                             syncedAt: t0))
        let decoded = try storeDecoder().decode(Recording.self,
                                               from: try storeEncoder().encode([recording]))
        XCTAssertEqual(decoded.first?.calendarLink?.summaryNotes, "Agenda: roadmap")
        XCTAssertEqual(decoded.first?.calendarLink?.attendees, ["Dana"])
    }

    // MARK: - Prompt blocks

    func test_contextBlock_labelsEachSourceAndOmitsEmptyOnes() {
        let link = CalendarLink(event: event(title: "Q3 review", body: "Agenda: roadmap"),
                                includeAttendees: false, includeBody: true,
                                maxAttendees: 12, syncedAt: t0)
        XCTAssertEqual(LiveAISession.contextBlock(userNotes: "  ", calendarLink: nil), "",
                       "no notes and no link must not add any block at all")

        let onlyUser = LiveAISession.contextBlock(userNotes: "Ask about the hire", calendarLink: nil)
        XCTAssertTrue(onlyUser.contains("NOTES THE USER TYPED IN MILA"))
        XCTAssertTrue(onlyUser.contains("Ask about the hire"))
        XCTAssertFalse(onlyUser.contains("CALENDAR INVITE"))

        // A link whose body was never consented to contributes nothing, even
        // though the link itself exists.
        let consentless = CalendarLink(event: event(body: "Agenda"), includeAttendees: true,
                                       includeBody: false, maxAttendees: 12, syncedAt: t0)
        XCTAssertEqual(LiveAISession.contextBlock(userNotes: "", calendarLink: consentless), "")

        let both = LiveAISession.contextBlock(userNotes: "Ask about the hire", calendarLink: link)
        XCTAssertTrue(both.contains("NOTES THE USER TYPED IN MILA"))
        XCTAssertTrue(both.contains("CALENDAR INVITE"))
        XCTAssertTrue(both.contains("Q3 review"), "the model is told which event the notes came from")
        XCTAssertTrue(both.contains("Agenda: roadmap"))
        XCTAssertLessThan(both.range(of: "NOTES THE USER")!, both.range(of: "CALENDAR INVITE")!,
                          "the user's own notes lead, the invite follows")
    }

    func test_summaryPrompt_appendsEventNotesOnlyWhenConsented() {
        let base = "Summarise this meeting."
        XCTAssertEqual(RecordingSummarizer.promptWithCalendarNotes(base, link: nil), base)

        let noBody = CalendarLink(event: event(body: ""), includeAttendees: true,
                                  includeBody: true, maxAttendees: 12, syncedAt: t0)
        XCTAssertEqual(RecordingSummarizer.promptWithCalendarNotes(base, link: noBody), base,
                       "an event with no notes adds nothing")

        let link = CalendarLink(event: event(body: "Agenda: roadmap"), includeAttendees: false,
                                includeBody: true, maxAttendees: 12, syncedAt: t0)
        let composed = RecordingSummarizer.promptWithCalendarNotes(base, link: link)
        XCTAssertTrue(composed.hasPrefix(base), "the user's own prompt stays intact and first")
        XCTAssertTrue(composed.contains("Agenda: roadmap"))
        XCTAssertTrue(composed.contains("written BEFORE the meeting"),
                      "the guard rail against summarising the agenda is the point of the block")
    }

    // MARK: - The one-shot name prefill

    /// A calendar title is a suggestion; a name the user typed is not ours to
    /// overwrite. Re-syncing to a different event must still follow the event.
    func test_shouldSetMeetingName_neverOverwritesATypedName() {
        XCTAssertTrue(CalendarSyncController.shouldSetMeetingName(currentTitle: "", lastApplied: nil))
        XCTAssertTrue(CalendarSyncController.shouldSetMeetingName(currentTitle: "   ", lastApplied: nil))
        XCTAssertTrue(CalendarSyncController.shouldSetMeetingName(currentTitle: "Weekly sync",
                                                                  lastApplied: "Weekly sync"),
                       "our own earlier fill is ours to replace on a re-sync")
        XCTAssertFalse(CalendarSyncController.shouldSetMeetingName(currentTitle: "Kickoff with Dana",
                                                                   lastApplied: "Weekly sync"),
                       "a name the user typed wins over the event title")
        XCTAssertFalse(CalendarSyncController.shouldSetMeetingName(currentTitle: "Kickoff with Dana",
                                                                   lastApplied: nil))
    }

    // MARK: - Settings

    /// An isolated suite per the project rule — never `.standard`.
    private func makeSettings(suiteName: String) -> (CalendarSettings, UserDefaults) {
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return (CalendarSettings(defaults: suite), suite)
    }

    func test_settings_defaultOffAndPersistAcrossLaunches() {
        let suiteName = "CalendarIntegrationTests.settings"
        let (first, suite) = makeSettings(suiteName: suiteName)
        XCTAssertFalse(first.isEnabled, "the feature reads another app's personal data — opt-in only")
        XCTAssertTrue(first.usesEventName && first.usesEventBody && first.offersAttendees,
                      "sub-switches default on WITHIN the feature, so the sheet offers the lot")
        XCTAssertEqual(first.maxAttendees, CalendarEvent.attendeeCeiling)
        XCTAssertFalse(first.hasWorkToDo, "master off means the button has nothing to do")

        first.isEnabled = true
        first.usesEventBody = false
        first.maxAttendees = 5
        let relaunched = CalendarSettings(defaults: suite)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertFalse(relaunched.usesEventBody, "a deliberate 'off' survives the seeding on next launch")
        XCTAssertTrue(relaunched.offersAttendees)
        XCTAssertEqual(relaunched.maxAttendees, 5)
        XCTAssertTrue(relaunched.hasWorkToDo)

        first.isEnabled = false
        XCTAssertFalse(CalendarSettings(defaults: suite).hasWorkToDo)
        suite.removePersistentDomain(forName: suiteName)
    }

    /// A hand-edited `calendar.maxAttendees` must not reach the popover, on
    /// either side of the range, and must not be re-persisted as written
    /// (bugbot-rules/untrusted-persisted-data.md).
    func test_settings_clampsHandEditedAttendeeCeiling() {
        let suiteName = "CalendarIntegrationTests.clamp"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(5_000, forKey: "calendar.maxAttendees")
        XCTAssertEqual(CalendarSettings(defaults: suite).maxAttendees, CalendarSettings.maxMaxAttendees)
        suite.set(0, forKey: "calendar.maxAttendees")
        XCTAssertEqual(CalendarSettings(defaults: suite).maxAttendees, CalendarSettings.minMaxAttendees)
        suite.removePersistentDomain(forName: suiteName)
    }
}
