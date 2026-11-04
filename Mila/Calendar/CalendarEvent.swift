import Foundation

/// One macOS Calendar event, flattened to what Mila can use.
///
/// Deliberately a plain value type with no EventKit in it: everything that
/// decides *which* events count, how they are ordered, and which attendees are
/// offered is pure logic over these fields, so it is unit-testable without a
/// Calendar.app, an account, or the TCC prompt. `CalendarEventReader` is the
/// only place `EKEvent` is touched, and its whole job is to build this.
struct CalendarEvent: Identifiable, Hashable {

    /// EventKit's stable per-event id (`EKEvent.eventIdentifier`). Stable
    /// across launches and across the recurrences of a repeating event's
    /// instances (each instance carries its own), so it identifies the row a
    /// user actually synced — not "an event with this title at this time".
    /// `nil` only for events EventKit refuses to identify, which the sync
    /// path treats as "cannot be re-checked later", never as "duplicate".
    let id: String?

    /// Event title as the user typed it. May be empty — Calendar allows
    /// untimed/untitled entries — which is what `displayTitle` is for.
    let title: String

    /// The event's notes ("body"). nil when empty.
    ///
    /// This is the field the user opts into for the summary prompt
    /// (`CalendarSettings.usesEventBody`): it is the most free-form text in a
    /// calendar record and routinely holds agendas, interview candidates,
    /// doctor's notes, or a client's name. It is never logged, and it is never
    /// sent anywhere the transcript itself isn't already going.
    let body: String?

    let start: Date
    let end: Date

    /// Attendee display names, de-duplicated and sorted. Built by
    /// `attendeeNames(from:)`, which is where the "what can we actually know
    /// about an invitee" rules live.
    let attendeeNames: [String]

    /// The name of the calendar the event lives on ("Work", "Personal", a
    /// Google account). Shown in the sync sheet so two same-titled events from
    /// different accounts are distinguishable.
    let calendarTitle: String?

    init(id: String?,
         title: String,
         body: String?,
         start: Date,
         end: Date,
         attendeeNames: [String] = [],
         calendarTitle: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.start = start
        self.end = end
        self.attendeeNames = attendeeNames
        self.calendarTitle = calendarTitle
    }

    /// What the UI shows for the event itself.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    /// Notes trimmed, and nil when there is nothing to add. Callers append a
    /// block only when this is non-nil, so an empty event body never puts a
    /// blank "Meeting notes:" section in front of an LLM prompt.
    var trimmedBody: String? {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Which events count as "happening now"

    /// How far past its end an event still counts. A meeting that just
    /// finished is still the meeting the user is thinking about — they hit
    /// Record late, or recorded the call and want its context afterwards.
    static let endedGrace: TimeInterval = 10 * 60

    /// How far before its start an event already counts. Users open Mila a few
    /// minutes early to prepare; excluding those would make the button read as
    /// broken exactly when it is most useful.
    static let upcomingGrace: TimeInterval = 15 * 60

    /// Eligibility for one event, as a pure function of the clock.
    ///
    /// **All-day events are excluded, always** (`isAllDay`): a whole-day
    /// entry — a birthday, a "OOO" block, a conference day — overlaps every
    /// moment of that day, so it would swallow the "what's happening right
    /// now" question the button asks. That exclusion is a product rule, not a
    /// limitation, so it lives here rather than in the EventKit mapping where
    /// a test could not see it.
    static func isEligible(start: Date,
                           end: Date,
                           isAllDay: Bool,
                           now: Date) -> Bool {
        if isAllDay { return false }
        // Zero- and negative-length entries are Calendar's own "timed" rows
        // with no meaningful span; treating them as ongoing makes them win the
        // ordering below for the whole minute they sit in. Reject them.
        guard end > start else { return false }
        return end >= now.addingTimeInterval(-endedGrace)
            && start <= now.addingTimeInterval(upcomingGrace)
    }

    /// Same-event test that survives the rare event with no
    /// `eventIdentifier`: fall back to the exact span + title, which is the
    /// best description available. Comparing `id == id` alone would call two
    /// unidentified events "the same" (nil == nil), i.e. pick the wrong one in
    /// a two-event sheet.
    static func isSameEvent(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if let l = lhs.id, let r = rhs.id { return l == r }
        return lhs.start == rhs.start && lhs.end == rhs.end && lhs.title == rhs.title
    }

    /// Distance from "now", for ordering: 0 while ongoing, positive either way
    /// otherwise. Smallest first, so the event the user is most likely
    /// reaching for is the top row of the sheet.
    static func relevance(of event: CalendarEvent, now: Date) -> TimeInterval {
        if event.start > now {
            return event.start.timeIntervalSince(now)
        }
        if event.end >= now {
            return 0
        }
        return now.timeIntervalSince(event.end)
    }

    /// The eligible events, closest-to-now first. Title breaks a tie so the
    /// order is stable across two calls with the same clock.
    static func sortedForDisplay(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.sorted { lhs, rhs in
            let l = relevance(of: lhs, now: now)
            let r = relevance(of: rhs, now: now)
            if l != r { return l < r }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    // MARK: - Attendees

    /// The ceiling on how many invitees are offered as speaker candidates.
    ///
    /// A company-wide invite can carry hundreds of attendees, and every one of
    /// them would land in a rename popover as a plausible human in the room.
    /// The cap is a safety bound on that, not a performance one. Applied last,
    /// after de-duplication, so the 12 offered are 12 distinct people rather
    /// than 12 rows that happen to be the same person twice.
    static let attendeeCeiling = 12

    /// De-duplicate (case-insensitively, like `SpeakerDirectory.add`), drop
    /// blanks, sort for a stable list, then cut to `ceiling`.
    ///
    /// **No group/resource filtering.** EventKit does not expose the CalDAV
    /// `CUTYPE` that marks an invitee as a GROUP or a ROOM, so a distribution
    /// list is indistinguishable from a person at this layer. Rather than
    /// guess from the shape of a name — a wrong guess silently removes a real
    /// attendee from the popover — everything the invite lists is offered, and
    /// the ceiling plus the user's own eyes do the filtering. See
    /// `docs`-level reasoning in `CalendarSettings.offersAttendees`.
    static func limitedAttendees(_ names: [String], ceiling: Int = attendeeCeiling) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if seen.insert(name.lowercased()).inserted {
                unique.append(name)
            }
        }
        unique.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard ceiling > 0 else { return [] }
        return Array(unique.prefix(ceiling))
    }

    // MARK: - Naming

    /// The recording name this event suggests, capped to something a sidebar
    /// row can show.
    ///
    /// The cap is not cosmetic: `Recording.title` is also the transcript
    /// **file name**, and Calendar lets a title run to several hundred
    /// characters (and carry "/"). Sanitising here is cheaper than reasoning
    /// about what the exporter does with a slash later. A whole title that is
    /// only slashes/punctuation still collapses to "" — the caller keeps its
    /// own default name in that case.
    static func suggestedRecordingTitle(for event: CalendarEvent, limit: Int = 80) -> String {
        var cleaned = event.displayTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        // A title that survives sanitising as only punctuation — "///", "---",
        // an emoji-only invite — is not a name. Returning "" is what lets the
        // caller keep its own default (the field is a suggestion, and a
        // recording called "---" is worse than one called "Recording"), so the
        // test for "is this even a word" is `contains(alphanumeric)`, not a
        // punctuation list that has to be guessed complete.
        if !cleaned.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        guard limit > 0, cleaned.count > limit else { return cleaned }
        let cut = String(cleaned.prefix(limit))
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
    }

    // MARK: - Formatting

    /// "14:00–14:30" (locale-aware) for the sheet row.
    func timeRangeString(date: Date = Date()) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: start, to: end)
    }
}
