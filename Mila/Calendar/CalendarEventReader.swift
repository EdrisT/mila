import Foundation
import EventKit
import OSLog

private let calendarLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                 category: "Calendar")

/// TCC state for calendar access, in the shape the UI talks about.
///
/// `EKAuthorizationStatus` leaks EventKit's vocabulary (`.authorized` was
/// renamed `.fullAccess` in macOS 14, and iOS-only cases ride along), and the
/// Settings page needs to answer one question — can Mila read events? — so
/// the mapping happens once, here.
enum CalendarAccess: String {

    /// Never asked. No prompt has been shown, so nothing is granted yet.
    case notDetermined
    /// Reads and writes are granted. On macOS 14 this is the **only** grant
    /// EventKit offers for events — see `CalendarSettings` for why the
    /// Settings page says so out loud.
    case fullAccess
    /// Granted for writes only. Mila would be able to create events but not
    /// read them, which is the one half it does not want, so it is treated as
    /// "no access" rather than as a half-win.
    case writeOnly
    /// The user said no (or revoked it in System Settings).
    case denied
    /// Blocked above the user — MDM, or a Screen Time style restriction.
    case restricted

    /// True only when event *contents* can be read. `.writeOnly` is excluded
    /// on purpose: it is a real grant for a different feature.
    var canReadEvents: Bool { self == .fullAccess }

    /// Whether the state is terminal without going to System Settings.
    /// `.notDetermined` can be fixed by asking; `.denied` and `.restricted`
    /// cannot — re-asking is a no-op macOS performs silently and returns the
    /// same answer, which is why the Settings page shows a "Open Privacy
    /// Settings" route instead of an infinite "Grant access" button.
    var needsSystemSettings: Bool { self == .denied || self == .restricted }

    var userFacingMessage: String {
        switch self {
        case .notDetermined:
            return "Mila hasn't asked for calendar access yet."
        case .fullAccess:
            return "Mila can read your calendar."
        case .writeOnly:
            return "macOS granted Mila calendar access for creating events only, so Mila can't read them. Re-grant full access to fix this."
        case .denied:
            return "Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars."
        case .restricted:
            return "Calendar access is blocked by a policy on this Mac, so Mila can't read events."
        }
    }
}

/// Reads events out of the user's Calendar.app.
///
/// The whole EventKit surface of the feature lives in this file. Everything
/// that decides *what to do* with an event works on `CalendarEvent`, which
/// keeps the interesting logic off the TCC prompt, off the account list, and
/// inside a unit test.
///
/// ## Why macOS 14 can only ask for full access
///
/// `EKEventStore.requestAccess(to: .event)` — the read-only ask — is
/// deprecated and no longer grants anything that reads event contents: on
/// macOS 14 the working call is `requestFullAccessToEvents`, and TCC shows it
/// as one "Calendars" switch covering reads **and** writes. iOS 17's separate
/// read-only tier does not exist on macOS. Mila never writes to the store
/// (there is no `save(_:)` call anywhere in this feature), and the Settings
/// page says the prompt will offer more than Mila uses rather than let the
/// prompt speak for itself.
@MainActor
final class CalendarEventReader: ObservableObject {

    @Published private(set) var access: CalendarAccess

    /// One store, built on first use and kept for the app's lifetime.
    ///
    /// `lazy` on purpose: instantiating `EKEventStore` at launch is what makes
    /// the app appear in System Settings → Calendars before the user has done
    /// anything, and it is the pattern the app deliberately avoids for the
    /// microphone and for Voice Memos folder access. Nothing here touches
    /// EventKit until the user opens Settings → Calendar or presses the calendar
    /// button. `EKEventStore` is also not thread-safe, which is the main reason
    /// this class is `@MainActor` (and why a `lazy var` — mutated once, from the
    /// main actor — is safe here) and why the fetch below does not hop to a
    /// background queue.
    private lazy var store = EKEventStore()

    init() {
        self.access = CalendarEventReader.currentAccess()
    }

    /// Read TCC state without prompting. Called at launch so the Settings page
    /// and the sync button can tell "granted", "refused" and "never asked"
    /// apart before the user does anything.
    static func currentAccess() -> CalendarAccess {
        map(EKEventStore.authorizationStatus(for: .event))
    }

    static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default:
            // Fail closed: an EventKit status this build doesn't know is not a
            // grant.
            calendarLog.log("unknown calendar authorization status — treated as denied")
            return .restricted
        }
    }

    /// Ask TCC for the access the feature needs. Returns the resulting state,
    /// which the caller surfaces — a "no" is a legitimate outcome and the UI
    /// must not pretend the feature is on.
    func requestAccess() async -> CalendarAccess {
        await withCheckedContinuation { (continuation: CheckedContinuation<CalendarAccess, Never>) in
            store.requestFullAccessToEvents { granted, error in
                let resolved: CalendarAccess
                if granted {
                    resolved = CalendarEventReader.currentAccess()
                } else {
                    // `granted == false` alone cannot tell "the user clicked
                    // Don't Allow" from "the prompt could not be shown", and
                    // the Settings copy differs. Trust the authoritative
                    // status, and log the error code (never its description —
                    // EventKit's errors embed account names).
                    resolved = CalendarEventReader.currentAccess()
                    if let error {
                        // `any Error` has no domain/code — the NSError bridge
                        // does, and that pair is what identifies the failure
                        // without quoting a description EventKit fills with
                        // account names.
                        let ns = error as NSError
                        calendarLog.error("requestFullAccessToEvents failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
                    }
                }
                continuation.resume(returning: resolved)
            }
        }
    }

    // MARK: - Fetching

    /// How far outside "now" EventKit is asked for events.
    ///
    /// The eligibility window in `CalendarEvent.isEligible` is minutes wide,
    /// but the query has to cover any event that *overlaps* it, and EventKit
    /// only returns events whose span intersects the predicate window. A
    /// 24 h margin keeps a long-running event that started yesterday (a
    /// multi-day conference block) reachable while staying bounded, so a user
    /// with years of history never pays for years of history.
    static let queryMargin: TimeInterval = 24 * 3600

    /// The events that count as happening around `now`, ready for display.
    ///
    /// Returns [] — never an error — when access is missing, so a call from a
    /// button can't fail in a way the user has to interpret; the caller checks
    /// `access` first and offers to fix it. `events(matching:)` is itself
    /// non-throwing in this SDK: a query the calendar agent refuses comes back
    /// empty, which is the same shape the missing-access path returns, so there
    /// is no failure left to report and no retry to offer mid-recording.
    func events(near now: Date = Date()) -> [CalendarEvent] {
        guard access.canReadEvents else { return [] }
        let window = DateInterval(start: now.addingTimeInterval(-Self.queryMargin),
                                  end: now.addingTimeInterval(Self.queryMargin))
        let predicate = store.predicateForEvents(withStart: window.start,
                                                 end: window.end,
                                                 calendars: nil)
        let found = store.events(matching: predicate)
        let mapped = found.compactMap { Self.calendarEvent(from: $0) }
        let eligible = mapped.filter {
            CalendarEvent.isEligible(start: $0.start, end: $0.end, isAllDay: false, now: now)
        }
        // Counts only — no titles, no attendee names. See
        // bugbot-rules/no-user-content-in-logs.md.
        calendarLog.log("calendar query: matched=\(found.count, privacy: .public) eligible=\(eligible.count, privacy: .public)")
        return CalendarEvent.sortedForDisplay(eligible, now: now)
    }

    /// `EKEvent` → `CalendarEvent`, and the one place `isAllDay` is honoured.
    ///
    /// All-day events are dropped here rather than carried in and filtered by
    /// `isEligible`, so nothing downstream can accidentally offer one: the
    /// struct itself never describes an all-day event, which is why
    /// `events(near:)` can pass `isAllDay: false` to the eligibility check
    /// without lying.
    static func calendarEvent(from event: EKEvent) -> CalendarEvent? {
        if event.isAllDay { return nil }
        return CalendarEvent(
            id: event.eventIdentifier,
            title: event.title ?? "",
            body: event.notes,
            start: event.startDate,
            end: event.endDate,
            attendeeNames: attendeeNames(from: event.attendees ?? []),
            calendarTitle: event.calendar.title
        )
    }

    /// Display names for an invite's attendee list.
    ///
    /// EventKit hands back `EKParticipant`, whose `name` is frequently nil for
    /// Google and Exchange invites — the person exists only as an address.
    /// Falling back to the raw address is deliberate: deriving "Yossi Cohen"
    /// from `yossi.cohen@corp.com` invents a spelling for a human being, and
    /// the result of a wrong guess is a name the user then has to undo in
    /// every future recording of that voice (naming a speaker learns a voice
    /// profile). An address looks like what it is.
    ///
    /// Participants with neither a name nor an address are dropped, and the
    /// de-duplication/sort/ceiling rules live in
    /// `CalendarEvent.limitedAttendees` where a test can reach them.
    static func attendeeNames(from participants: [EKParticipant]) -> [String] {
        participants.compactMap { participant in
            if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            // `EKParticipant.url` is NON-optional in this SDK — a participant
            // with no address carries an empty URL, whose `scheme` is nil, so
            // the mailto test is the whole check.
            if participant.url.scheme == "mailto" {
                // `path(percentEncoded:)` is non-optional too — there is no
                // "no path" case for a URL to fall into here.
                let address = participant.url.path(percentEncoded: false)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { return address }
            }
            return nil
        }
    }
}
