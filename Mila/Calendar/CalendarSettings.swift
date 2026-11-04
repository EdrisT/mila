import Foundation
import Combine
import OSLog

private let calendarSettingsLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                         category: "CalendarSettings")

/// User settings for the macOS Calendar integration.
///
/// Same shape as `VoiceMemosSettings` / `DiarizationSettings`: `@Published`
/// properties writing through to namespaced `calendar.*` `UserDefaults` keys,
/// with an injectable `defaults` suite so tests never touch the user's real
/// preferences.
///
/// ## What this object is, and is not
///
/// Preferences only. TCC state lives in `CalendarEventReader.access`, and the
/// "what just happened when I clicked the calendar button" state lives in
/// `CalendarSyncController`. The split is deliberate: nothing in here can be
/// stale, because there is nothing to re-verify — macOS persists the Calendars
/// grant itself, so unlike the diarizer's Python setup there is no `verified`
/// flag to persist alongside a value. If the user flips the switch in System
/// Settings, the next `CalendarEventReader.currentAccess()` sees it.
///
/// The master switch is **off by default**: this feature reads a second app's
/// personal data and (with `usesEventBody`) puts that data in front of an LLM.
/// Opt-in is the only defensible default, and it is the same rule the Voice
/// Memos import and the MCP surface follow.
///
/// These keys are deliberately **not** `.milaconfig` keys and have no
/// `ManagedField` case (docs/mdm.md): an MDM profile forcing calendar access
/// on would push event contents into LLM prompts on a machine the user has not
/// personally opted into. If that becomes wanted, each key needs a
/// `ManagedField` case, an enforcing setter and a `ManagedSettingNote` — the
/// `MilaConfigImporter` precedence test enumerates them, so the omission is
/// visible there too.
@MainActor
final class CalendarSettings: ObservableObject {

    /// Master switch. Off until the user turns it on.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Offer the event's attendees as candidates in the speaker rename
    /// popover.
    ///
    /// A *candidate list*, not an assignment: nothing in a calendar invite
    /// says which voice is which attendee, so the user does the mapping and
    /// each name goes through the normal rename path (`setSpeakerName`), which
    /// is also what learns a voice profile. That is why a wrong pick costs one
    /// click to undo rather than auto-naming that voice in every future
    /// recording — see `SpeakerNamePicker`'s "From the meeting invite" section.
    @Published var offersAttendees: Bool {
        didSet { defaults.set(offersAttendees, forKey: Keys.attendees) }
    }

    /// Use the event's title as the recording / meeting name.
    ///
    /// Applied as a *prefill*, never as an overwrite of a name the user typed
    /// themselves — see `CalendarSyncController.shouldSetMeetingName(currentTitle:lastApplied:)`.
    @Published var usesEventName: Bool {
        didSet { defaults.set(usesEventName, forKey: Keys.eventName) }
    }

    /// Add the event's notes ("body") to the summariser's prompt.
    ///
    /// The one toggle that moves data off the machine when the LLM is remote,
    /// so it is the one the Settings page labels explicitly. It is also the
    /// reason the whole feature is opt-in.
    @Published var usesEventBody: Bool {
        didSet { defaults.set(usesEventBody, forKey: Keys.eventBody) }
    }

    /// Ceiling on how many attendees are offered. Safety bound on a
    /// company-wide invite, not a performance one — see
    /// `CalendarEvent.attendeeCeiling`.
    ///
    /// Clamped on write: a stored 0 or a hand-edited 5,000 would otherwise
    /// reach the popover (0 hides the section entirely, which reads as a bug
    /// rather than as a choice).
    @Published var maxAttendees: Int {
        didSet {
            let clamped = Self.clamped(maxAttendees)
            if clamped != maxAttendees {
                maxAttendees = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.maxAttendees)
        }
    }

    static let defaultMaxAttendees = CalendarEvent.attendeeCeiling
    static let minMaxAttendees = 1
    static let maxMaxAttendees = 30

    static func clamped(_ value: Int) -> Int {
        min(max(value, minMaxAttendees), maxMaxAttendees)
    }

    /// True when there is anything for the sync sheet to offer. Drives the
    /// calendar button: a master switch on with every behaviour off would show
    /// a sheet whose toggles are all off, i.e. a button that does nothing.
    var hasWorkToDo: Bool {
        isEnabled && (offersAttendees || usesEventName || usesEventBody)
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "calendar.enabled"
        static let attendees = "calendar.offersAttendees"
        static let eventName = "calendar.usesEventName"
        static let eventBody = "calendar.usesEventBody"
        static let maxAttendees = "calendar.maxAttendees"
        /// One-shot marker: the sub-switches have been defaulted once.
        static let seededDefaults = "calendar.defaultsSeeded"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        // Sub-switches default ON *within* the feature, but only matter when
        // `isEnabled` is true — and the feature is off by default, so an
        // unconfigured user gets nothing. `UserDefaults.bool` reads a missing
        // key as false, which would silently turn a first-time user on to the
        // body-in-prompt path the moment they enabled the feature, without
        // the choice ever being presented. Seed the trio to true the first
        // time the object is created instead, and record that it happened so
        // a later deliberate "off" survives the next launch.
        let seeded = defaults.bool(forKey: Keys.seededDefaults)
        if seeded {
            self.offersAttendees = defaults.bool(forKey: Keys.attendees)
            self.usesEventName = defaults.bool(forKey: Keys.eventName)
            self.usesEventBody = defaults.bool(forKey: Keys.eventBody)
        } else {
            self.offersAttendees = true
            self.usesEventName = true
            self.usesEventBody = true
        }
        // Clamped on READ as well as on write: `didSet` does not run for an
        // initialisation assignment, so a hand-edited `calendar.maxAttendees`
        // of 0 or 5000 would otherwise reach the popover for the whole session
        // (bugbot-rules/untrusted-persisted-data.md — validate at the decode
        // boundary, not only at the setter).
        self.maxAttendees = Self.clamped(defaults.object(forKey: Keys.maxAttendees) as? Int
                                         ?? Self.defaultMaxAttendees)
        if !seeded {
            defaults.set(true, forKey: Keys.seededDefaults)
            defaults.set(self.offersAttendees, forKey: Keys.attendees)
            defaults.set(self.usesEventName, forKey: Keys.eventName)
            defaults.set(self.usesEventBody, forKey: Keys.eventBody)
            defaults.set(Self.defaultMaxAttendees, forKey: Keys.maxAttendees)
            calendarSettingsLog.log("calendar sub-switches seeded on (feature itself stays off)")
        }
    }
}
