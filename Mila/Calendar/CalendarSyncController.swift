import AppKit
import Combine
import OSLog

private let calendarSyncLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                     category: "CalendarSync")

/// Owns the "sync this recording with a calendar event" flow: the button's
/// decision (ask for access? show the sheet? say there's nothing to sync?),
/// the sheet's draft state, and what a confirmed sync actually changes.
///
/// ## Why a controller and not view state
///
/// The entry point exists in three places — the live recording header, the
/// main window's toolbar, and the floating recording chip — and a `.sheet`
/// hung off each would mean three sheets that can each be opened on top of the
/// others. All three call `present()`; `ContentView` renders the one sheet
/// from `draft`, the same way it renders `RenameRecordingSheet` from
/// `PostRecordingCoordinator.pending`.
///
/// ## What a sync does, and does not, do
///
/// It fills in the one-shot `QuickActionsController.nextRecordingCalendarLink`
/// (the pattern `nextRecordingTitle` and `nextRecordingFolder` already use:
/// set now, applied when the recording is saved, cleared there so it never
/// leaks into the next meeting) and, if the name toggle is on, prefills the
/// meeting-name field. It never touches `speakerNames`, never renames a saved
/// recording behind the user's back, and never writes to the calendar — there
/// is no EventKit write call anywhere in this feature.
@MainActor
final class CalendarSyncController: ObservableObject, CalendarContextSource {

    /// The sheet's editable state. A value type so the toggles a user flips
    /// while deciding are discarded on Cancel without any undo, and so the
    /// persisted `CalendarSettings` only changes if the user says "apply"
    /// (which is what `confirm()` writes back).
    struct Draft: Identifiable {
        let id = UUID()
        /// Closest-to-now first, as `CalendarEvent.sortedForDisplay` ordered
        /// them at fetch time. The order is frozen with the draft on purpose:
        /// re-sorting against a later clock while the sheet is open would move
        /// the row the user is pointing at.
        let events: [CalendarEvent]
        var selectedEventIndex: Int
        var offersAttendees: Bool
        var usesEventName: Bool
        var usesEventBody: Bool

        /// The event the user picked. An INDEX, not an event id: EventKit can
        /// hand back an event with no `eventIdentifier`, and comparing optional
        /// ids would then treat two different unidentified events as the same
        /// selection (nil == nil) and link the wrong one. `events` is
        /// immutable inside a draft, so an index cannot go stale, and index 0
        /// is the closest-to-now event — which is the fallback the guard
        /// returns, by construction rather than by chance.
        var selectedEvent: CalendarEvent? {
            guard events.indices.contains(selectedEventIndex) else { return events.first }
            return events[selectedEventIndex]
        }

        /// The sheet's "All of the above" switch: on iff every behaviour is
        /// on, and setting it moves all three. Derived, not stored, so it
        /// cannot disagree with the three switches next to it.
        var allOn: Bool {
            get { offersAttendees && usesEventName && usesEventBody }
            set {
                offersAttendees = newValue
                usesEventName = newValue
                usesEventBody = newValue
            }
        }
    }

    /// Why the button didn't open a sheet. Shown as an alert with a route to
    /// the right System Settings pane where one exists.
    enum Notice: String, Identifiable {
        case noEventsRightNow
        case accessDenied
        case accessRestricted
        case accessWriteOnly

        var id: String { rawValue }

        var message: String {
            switch self {
            case .noEventsRightNow:
                return "Nothing in your calendar is happening right now — no event is running, and none starts within the next \(Int(CalendarEvent.upcomingGrace / 60)) minutes. All-day events are always ignored."
            case .accessDenied:
                return "macOS hasn't granted Mila access to your calendars. Turn it on under System Settings → Privacy & Security → Calendars."
            case .accessRestricted:
                return "A policy on this Mac blocks calendar access, so Mila can't read your events."
            case .accessWriteOnly:
                return "macOS granted Mila calendar access for creating events only, which doesn't let it read them. Re-grant full access under System Settings → Privacy & Security → Calendars."
            }
        }

        /// True when the fix is outside Mila, so the alert can offer the pane
        /// instead of a retry that returns the same "no".
        var opensSystemSettings: Bool {
            switch self {
            case .noEventsRightNow: return false
            case .accessDenied, .accessRestricted, .accessWriteOnly: return true
            }
        }
    }

    /// Non-nil while the sync sheet is showing.
    @Published private(set) var draft: Draft?
    @Published private(set) var notice: Notice?
    /// True while a TCC prompt or a calendar query is in flight, so the button
    /// can show a spinner and refuse a second press instead of stacking two
    /// permission prompts.
    @Published private(set) var isWorking = false

    /// The event title this controller last put into the meeting-name field.
    /// A sync may overwrite its OWN earlier fill (the user re-synced to a
    /// different event) but never something the user typed — hence remembering
    /// what was ours.
    private var lastAppliedEventTitle: String?

    private let settings: CalendarSettings
    private let reader: CalendarEventReader
    private let actions: QuickActionsController

    init(settings: CalendarSettings,
         reader: CalendarEventReader,
         actions: QuickActionsController) {
        self.settings = settings
        self.reader = reader
        self.actions = actions
    }

    // MARK: - Live AI context source

    /// The link currently on the live pipeline. `QuickActionsController`
    /// clears it at Stop, which is why `LiveAISession` cannot carry one
    /// recording's invite into the next recording's prompt.
    var liveCalendarLink: CalendarLink? { actions.nextRecordingCalendarLink }

    /// Whether a recording is in flight right now — the sheet says "this
    /// recording" when it is and "your next recording" when it isn't.
    var isRecordingInFlight: Bool { actions.isRecording }

    /// Current TCC state, for the Settings page and the button's tooltip.
    var access: CalendarAccess { reader.access }

    // MARK: - Entry point

    /// The calendar button. One method because all three entry points must
    /// behave identically, and because the access ladder below is the part a
    /// view would get subtly wrong: re-asking TCC after a denial is a silent
    /// no-op, so a "Grant access" button that stays up is a lie.
    func present(now: Date = Date()) {
        guard !isWorking, draft == nil else { return }
        guard settings.hasWorkToDo else { return }
        switch reader.access {
        case .fullAccess:
            openDraft(around: now)
        case .notDetermined:
            isWorking = true
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.reader.requestAccess()
                self.isWorking = false
                if granted.canReadEvents {
                    self.openDraft(around: Date())
                } else {
                    self.notice = Self.notice(for: granted)
                }
            }
        case .denied, .restricted, .writeOnly:
            notice = Self.notice(for: reader.access)
        }
    }

    static func notice(for access: CalendarAccess) -> Notice {
        switch access {
        case .fullAccess: return .noEventsRightNow
        case .denied: return .accessDenied
        case .restricted: return .accessRestricted
        case .writeOnly: return .accessWriteOnly
        case .notDetermined: return .accessDenied
        }
    }

    /// Fetch and decide. Kept separate from the access ladder so the
    /// post-prompt path and the already-granted path run exactly the same
    /// code — including the "nothing is happening" answer.
    private func openDraft(around now: Date) {
        let events = reader.events(near: now)
        guard !events.isEmpty else {
            notice = .noEventsRightNow
            return
        }
        draft = Draft(events: events,
                      selectedEventIndex: 0,
                      offersAttendees: settings.offersAttendees,
                      usesEventName: settings.usesEventName,
                      usesEventBody: settings.usesEventBody)
    }

    // MARK: - Sheet edits

    func select(_ event: CalendarEvent) {
        guard var draft else { return }
        // Index-based for the same reason `selectedEventIndex` exists, and
        // `isSameEvent` for the same reason: an unidentified event cannot be
        // found by id.
        if let index = draft.events.firstIndex(where: { CalendarEvent.isSameEvent($0, event) }) {
            draft.selectedEventIndex = index
            self.draft = draft
        }
    }

    func setOffersAttendees(_ on: Bool) { draft?.offersAttendees = on }
    func setUsesEventName(_ on: Bool) { draft?.usesEventName = on }
    func setUsesEventBody(_ on: Bool) { draft?.usesEventBody = on }
    func setAllOn(_ on: Bool) { draft?.allOn = on }

    func clearNotice() { notice = nil }
    func cancel() { draft = nil }

    /// Open the Calendars pane of System Settings. Mirrors
    /// `QuickActionsController.openMicrophoneSettings` — the pane name is
    /// "Calendars" on macOS 14+.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Confirm

    /// Apply the sheet. The three behaviours are independent: a user can sync
    /// an event for its name only, or for its notes only.
    ///
    /// The chosen toggles are also written back to `CalendarSettings`, so the
    /// next sheet opens with what the user last chose — the same argument as
    /// for a per-recording Live AI prompt: defaults follow behaviour, and the
    /// sheet is where the behaviour is chosen.
    func confirm(now: Date = Date()) {
        guard let draft else { return }
        guard let event = draft.selectedEvent else {
            self.draft = nil
            return
        }
        let link = CalendarLink(event: event,
                                includeAttendees: draft.offersAttendees,
                                includeBody: draft.usesEventBody,
                                maxAttendees: settings.maxAttendees,
                                syncedAt: now)
        actions.nextRecordingCalendarLink = link

        if draft.usesEventName,
           Self.shouldSetMeetingName(currentTitle: actions.nextRecordingTitle,
                                     lastApplied: lastAppliedEventTitle) {
            let suggested = CalendarEvent.suggestedRecordingTitle(for: event)
            if !suggested.isEmpty {
                actions.nextRecordingTitle = suggested
                lastAppliedEventTitle = suggested
            }
        }

        settings.offersAttendees = draft.offersAttendees
        settings.usesEventName = draft.usesEventName
        settings.usesEventBody = draft.usesEventBody

        self.draft = nil
        // Counts and booleans only — no event title, no attendee names
        // (bugbot-rules/no-user-content-in-logs.md).
        calendarSyncLog.log("calendar sync applied: attendees=\(link.attendees.count, privacy: .public) body=\(link.summaryNotes != nil, privacy: .public) name=\(draft.usesEventName, privacy: .public) inFlight=\(self.isRecordingInFlight, privacy: .public)")
    }

    /// Never overwrite a name the user typed.
    ///
    /// A calendar title is a *suggestion*; if the field already holds words
    /// this controller did not put there, the user typed them and they win.
    /// Empty, or our own earlier fill, is fair game — re-syncing to a
    /// different event should follow the new event, or the sheet's name
    /// toggle does nothing the second time it is used.
    static func shouldSetMeetingName(currentTitle: String, lastApplied: String?) -> Bool {
        let current = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty { return true }
        guard let lastApplied else { return false }
        return current == lastApplied.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
