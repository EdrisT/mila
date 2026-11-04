import SwiftUI
import AppKit

/// Settings → Calendar. Preferences for the macOS Calendar integration plus
/// the one piece of its state that isn't a preference: whether macOS has
/// granted Mila calendar access.
///
/// Same shape as `MeetingsSettingsTab` (a sibling integration): header, master
/// switch with the per-section `DetailLayoutUITests` probe, then the detail
/// blocks that only matter while it's on.
struct CalendarSettingsTab: View {
    @EnvironmentObject private var settings: CalendarSettings
    @EnvironmentObject private var reader: CalendarEventReader
    @EnvironmentObject private var sync: CalendarSyncController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Toggle(isOn: $settings.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my Mac's calendar")
                            .font(.body)
                        Text("Mila looks for a calendar event happening when you record, and offers to link the recording to it. Nothing is read until you click the calendar button — Mila never pulls events on a timer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                // Calendar's per-section probe for `DetailLayoutUITests`.
                .accessibilityIdentifier("calendar.enable.toggle")

                accessCard

                if settings.isEnabled {
                    Divider()
                    behaviours
                    attendeeCeiling
                    howItWorks
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendar")
                .font(.title3.weight(.semibold))
            Text("Link a recording to the event it came from, so the meeting gets a name, the summary gets the agenda, and the invite's attendees are one click away when you name a speaker.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Access

    /// The TCC state, stated in the same terms the system uses.
    ///
    /// Two things this has to get right. It must not promise more than macOS
    /// actually grants — the only grant EventKit offers for events on macOS 14
    /// covers reads AND writes, so the card says that instead of letting the
    /// prompt's wording be a surprise. And it must not offer a "Grant access"
    /// button once the answer is in: after a denial, asking again is a silent
    /// no-op that returns the same denial, so the only honest affordance left
    /// is the System Settings pane.
    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: accessIcon)
                    .foregroundStyle(accessColor)
                Text(reader.access.userFacingMessage)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch reader.access {
                case .notDetermined:
                    Button("Grant Access") {
                        Task { _ = await reader.requestAccess() }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("calendar.grant.button")
                case .denied, .restricted, .writeOnly:
                    Button("Open Privacy Settings") {
                        sync.openPrivacySettings()
                    }
                    .controlSize(.small)
                case .fullAccess:
                    EmptyView()
                }
            }

            Text("macOS offers one Calendars switch, which covers reading and creating events together. Mila only ever reads — it never adds or changes an event.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var accessIcon: String {
        switch reader.access {
        case .fullAccess: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .writeOnly: return "exclamationmark.triangle.fill"
        case .denied, .restricted: return "xmark.circle.fill"
        }
    }

    private var accessColor: Color {
        switch reader.access {
        case .fullAccess: return .green
        case .notDetermined: return .secondary
        case .writeOnly, .denied, .restricted: return .orange
        }
    }

    // MARK: - Behaviours

    private var behaviours: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What a sync does")
                .font(.callout.weight(.semibold))

            Toggle(isOn: $settings.usesEventName) {
                behaviourLabel("Use the event's name as the meeting name",
                               "Fills in the meeting-name field. A name you typed yourself always wins.")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("calendar.eventName.toggle")

            Toggle(isOn: $settings.usesEventBody) {
                behaviourLabel("Add the event's notes to the summary",
                               "The invite's notes go into the summariser's prompt as background — never summarised themselves. If your AI provider is a remote service, these notes leave your Mac with the transcript.")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("calendar.eventBody.toggle")

            Toggle(isOn: $settings.offersAttendees) {
                behaviourLabel("Offer the invite's attendees when naming a speaker",
                               "The people invited to the event appear in the speaker rename popover, under “From the meeting invite”. Mila can't tell which voice is which person, so you choose — and nothing is named until you click.")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("calendar.attendees.toggle")

            if !settings.hasWorkToDo {
                Text("All three are off, so the calendar button has nothing to do. Turn one on, or turn the integration off.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func behaviourLabel(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Attendee ceiling

    private var attendeeCeiling: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("At most")
                    .font(.callout)
                Stepper(value: $settings.maxAttendees,
                        in: CalendarSettings.minMaxAttendees...CalendarSettings.maxMaxAttendees) {
                    Text("\(settings.maxAttendees) attendees")
                        .font(.callout)
                        .monospacedDigit()
                }
                .accessibilityIdentifier("calendar.maxAttendees.stepper")
            }
            Text("A safety bound, not a limit on your calendar: a company-wide invite can list hundreds of people, and every one of them would otherwise be offered as a person in the room. Invites are listed as the calendar stores them — Mila can't tell a distribution list from a person, because macOS doesn't say.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How Mila picks the event")
                .font(.callout.weight(.semibold))
            Text("Click the calendar button — while recording, or from the toolbar before you start. Mila looks for an event that is running now, started within the last \(Int(CalendarEvent.endedGrace / 60)) minutes, or starts within the next \(Int(CalendarEvent.upcomingGrace / 60)). All-day events (birthdays, OOO blocks, conference days) are always ignored, since they overlap every moment of their day. If more than one event matches, you choose which one to link.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
