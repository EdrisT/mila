import Foundation

/// The calendar event a recording was synced with, kept on the row.
///
/// Persisted on `Recording.calendarLink` (`encodeIfPresent`, so a recording
/// that was never synced encodes byte-identically to one from before this
/// feature) because all three consumers run *after* the button was pressed,
/// often long after:
///
///   * the summariser reads `eventBody` when it builds the prompt — which
///     happens at Stop, on a `regenerate` days later, and on the backfill pass
///     after a relaunch;
///   * the speaker rename popover reads `attendees` — a user renaming a voice
///     a week later still wants the invite list that came with that meeting;
///   * the live recording header and the Home controls show `eventTitle` so the
///     user can see a recording IS linked (a detail-view provenance line is not
///     part of this change — the field is ready for one).
///
/// ## What is *not* stored, and why
///
/// Only what the user consented to at sync time. `attendees` is empty when
/// they had "attendee suggestions" off, `eventBody` is nil when they had the
/// body toggle off — the row records the consent, not just the event, so a
/// later `regenerate` cannot quietly widen what an earlier sync agreed to.
///
/// The link is deliberately **not** mirrored in MilaKit's `StoredRecording`
/// and **not** carried in a `.milashare` (both tripwire tests carry it as a
/// deliberate exclusion): a share reveals who the user's calendar invited to a
/// meeting, which is other people's data, and the MCP surface exposes
/// confirmed facts about a recording — an invite list is a set of names that
/// were *invited*, not names that *spoke*. Same reasoning as
/// `speakerNameSuggestions`.
struct CalendarLink: Codable, Hashable {

    /// `EKEvent.eventIdentifier`. nil for the rare event EventKit won't
    /// identify; never used as a lookup key, only to explain where a
    /// recording came from.
    var eventIdentifier: String?
    /// The event's own title — **not** the recording's title. Kept because
    /// the user may rename the recording afterwards and still need to know
    /// which event it came from.
    var eventTitle: String
    /// The event's notes, as offered to the summariser. nil when the body
    /// toggle was off at sync time, or the event had none.
    var eventBody: String?
    var attendees: [String]
    var startsAt: Date
    var endsAt: Date
    var calendarTitle: String?
    var syncedAt: Date

    init(event: CalendarEvent,
         includeAttendees: Bool,
         includeBody: Bool,
         maxAttendees: Int,
         syncedAt: Date = Date()) {
        self.eventIdentifier = event.id
        self.eventTitle = event.displayTitle
        // Capped here, once, rather than at every prompt build: the stored
        // value and the value the model sees then cannot disagree, and a
        // hand-edited `recordings.json` cannot smuggle a bigger block into a
        // prompt than this feature ever agreed to send.
        self.eventBody = includeBody ? Self.cappedBody(event.trimmedBody) : nil
        self.attendees = includeAttendees
            ? CalendarEvent.limitedAttendees(event.attendeeNames, ceiling: maxAttendees)
            : []
        self.startsAt = event.start
        self.endsAt = event.end
        self.calendarTitle = event.calendarTitle
        self.syncedAt = syncedAt
    }

    // MARK: - Bounds

    /// Ceiling on how much of an event's notes the feature will store or send.
    ///
    /// Calendar lets the notes field run to arbitrary length — a pasted
    /// contract or a multi-page agenda is not exotic. Two things make a cap
    /// load-bearing rather than tidy: every Live AI tick re-ships the prompt,
    /// so an uncapped block is paid for on every tick of a 2-hour call; and a
    /// value this large in `recordings.json` would be re-decoded and
    /// re-validated on every launch. Past the cap the tail is dropped with an
    /// ellipsis, which keeps the part of an agenda that actually reads like an
    /// agenda.
    static let maxBodyCharacters = 4_000

    /// Ceiling on attendee names read back from disk. The write path already
    /// caps at `CalendarSettings.maxAttendees`; this is the decode boundary
    /// (bugbot-rules/untrusted-persisted-data.md): `recordings.json` is a
    /// user-editable file, and an array sized by hand must not be trusted to
    /// stay small on the way into a popover.
    static let maxStoredAttendees = 200

    static func cappedBody(_ body: String?) -> String? {
        guard let body else { return nil }
        guard body.count > maxBodyCharacters else { return body }
        return String(body.prefix(maxBodyCharacters)) + " […]"
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case eventIdentifier, eventTitle, eventBody, attendees
        case startsAt, endsAt, calendarTitle, syncedAt
    }

    /// Lenient, and validating. `Recording.init(from:)` decodes the whole
    /// library all-or-nothing, so a malformed link costs a recording, not a
    /// feature: unknown keys and missing optionals are tolerated, and anything
    /// structurally impossible (no title, no dates) drops the link rather
    /// than guessing at it. Caps are applied to what was *stored*, not to
    /// what the writer promised.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let title = try? c.decode(String.self, forKey: .eventTitle),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let startsAt = try? c.decode(Date.self, forKey: .startsAt),
              let endsAt = try? c.decode(Date.self, forKey: .endsAt) else {
            // A link with no title or no time span describes nothing. Throw so
            // `Recording`'s `try?` around the field drops just this value.
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: c.codingPath,
                                      debugDescription: "calendarLink missing a usable title or span"))
        }
        self.eventTitle = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.eventIdentifier = try? c.decodeIfPresent(String.self, forKey: .eventIdentifier) ?? nil
        self.eventBody = Self.cappedBody(try? c.decodeIfPresent(String.self, forKey: .eventBody) ?? nil)
        let stored = (try? c.decodeIfPresent([String].self, forKey: .attendees)) ?? nil ?? []
        self.attendees = CalendarEvent.limitedAttendees(stored, ceiling: Self.maxStoredAttendees)
        self.calendarTitle = try? c.decodeIfPresent(String.self, forKey: .calendarTitle) ?? nil
        self.syncedAt = (try? c.decodeIfPresent(Date.self, forKey: .syncedAt) ?? nil) ?? startsAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventTitle, forKey: .eventTitle)
        try c.encode(startsAt, forKey: .startsAt)
        try c.encode(endsAt, forKey: .endsAt)
        try c.encode(syncedAt, forKey: .syncedAt)
        try c.encodeIfPresent(eventIdentifier, forKey: .eventIdentifier)
        try c.encodeIfPresent(eventBody, forKey: .eventBody)
        try c.encodeIfPresent(calendarTitle, forKey: .calendarTitle)
        if !attendees.isEmpty {
            try c.encode(attendees, forKey: .attendees)
        }
    }

    // MARK: - Use

    /// The notes block for the summariser, or nil when there is nothing to
    /// add. Named for the *purpose* so a call site reads as a decision:
    /// `link.summaryNotes` is only ever non-nil if the user opted into the
    /// body at sync time.
    var summaryNotes: String? {
        let trimmed = eventBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
