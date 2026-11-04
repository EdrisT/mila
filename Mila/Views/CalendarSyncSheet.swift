import SwiftUI

/// The sheet behind the calendar button: pick which event to link (when more
/// than one is happening) and what the link should be used for.
///
/// Presentation is owned by `ContentView` off `CalendarSyncController.draft`,
/// so the live recording header, the toolbar and the floating recording chip
/// all open the same one sheet.
///
/// Every value on screen is read straight from the controller's published
/// `draft`, and every edit goes back through a controller method. That is
/// deliberate: a copy of the draft held in `@State` would drift the moment the
/// user toggles something, and a copy passed in as an `init` argument depends on
/// SwiftUI re-invoking the content closure for a value change inside the same
/// presented item — which is exactly the kind of behaviour a layout change
/// silently breaks. The controller owns it; the view renders it.
struct CalendarSyncSheet: View {
    @EnvironmentObject private var sync: CalendarSyncController

    var body: some View {
        if let draft = sync.draft {
            VStack(alignment: .leading, spacing: 16) {
                header(inFlight: sync.isRecordingInFlight, draft: draft)

                eventSection(draft)

                Divider().opacity(0.5)

                behaviourSection(draft)

                footer(inFlight: sync.isRecordingInFlight, draft: draft)
            }
            .padding(20)
            .frame(width: 480)
        }
    }

    // MARK: - Header

    private func header(inFlight: Bool, draft: CalendarSyncController.Draft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(inFlight
                 ? "Link this recording to a calendar event"
                 : "Link your next recording to a calendar event")
                .font(.title3.weight(.semibold))
            Text(inFlight
                 ? "Mila found \(eventCountPhrase(draft)) while you're recording. Choose the one this recording belongs to."
                 : "Mila found \(eventCountPhrase(draft)). Choose the one you're about to record — it applies to the recording you start next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func eventCountPhrase(_ draft: CalendarSyncController.Draft) -> String {
        let count = draft.events.count
        return count == 1 ? "1 event" : "\(count) events"
    }

    // MARK: - Event choice

    /// One row per event, shown even when there is only one: the row is where
    /// the time, the calendar it lives on and the attendee count become
    /// visible, and a user sitting in two overlapping meetings has to see both
    /// to choose. Closest-to-now first, which is the controller's order.
    private func eventSection(_ draft: CalendarSyncController.Draft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(draft.events.enumerated()), id: \.element) { index, event in
                eventRow(event, isSelected: index == draft.selectedEventIndex)
            }
        }
    }

    private func eventRow(_ event: CalendarEvent, isSelected: Bool) -> some View {
        Button {
            sync.select(event)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(event.timeRangeString())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let calendarTitle = event.calendarTitle, !calendarTitle.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(calendarTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    // A preview only — the invite list can be long, and the
                    // full (capped) set is what the rename popover offers.
                    if !event.attendeeNames.isEmpty {
                        Text(attendeePreview(event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar.event.row")
    }

    private func attendeePreview(_ event: CalendarEvent) -> String {
        let shown = CalendarEvent.limitedAttendees(event.attendeeNames, ceiling: 3)
        let names = shown.joined(separator: ", ")
        let remaining = event.attendeeNames.count - shown.count
        guard remaining > 0 else { return names }
        return names.isEmpty ? "\(event.attendeeNames.count) attendees" : "\(names) +\(remaining) more"
    }

    // MARK: - What to use the event for

    private func behaviourSection(_ draft: CalendarSyncController.Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { draft.allOn }, set: { sync.setAllOn($0) })) {
                Text("All of the below").font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("calendar.sync.all")

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { draft.usesEventName },
                                     set: { sync.setUsesEventName($0) })) {
                    behaviourCaption("Name the meeting “\(namePreview(draft))”",
                                     sync.isRecordingInFlight
                                         ? "Fills in the name field in the header. A name you typed yourself stays."
                                         : "Fills in the meeting-name field on the Home screen.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("calendar.sync.name")

                Toggle(isOn: Binding(get: { draft.offersAttendees },
                                     set: { sync.setOffersAttendees($0) })) {
                    behaviourCaption("Offer \(attendeeCountPhrase(draft)) when naming speakers",
                                     "They appear in each speaker's rename popover under “From the meeting invite”. You decide which voice is which person.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("calendar.sync.attendees")

                Toggle(isOn: Binding(get: { draft.usesEventBody },
                                     set: { sync.setUsesEventBody($0) })) {
                    behaviourCaption("Use the event's notes in the summary",
                                     "Gives Live AI and the summary the agenda as background. They are never summarised as if they were said aloud.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("calendar.sync.body")
            }
            .padding(.leading, 12)

            if draft.usesEventBody, draft.selectedEvent?.trimmedBody == nil {
                Text("This event has no notes, so there's nothing to add to the summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func behaviourCaption(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The event title as it will land in the name field — sanitised and capped
    /// exactly the way the applied value is, so the sheet never promises a name
    /// the recording won't get.
    private func namePreview(_ draft: CalendarSyncController.Draft) -> String {
        guard let event = draft.selectedEvent else { return "" }
        let suggested = CalendarEvent.suggestedRecordingTitle(for: event)
        return suggested.isEmpty ? event.displayTitle : suggested
    }

    private func attendeeCountPhrase(_ draft: CalendarSyncController.Draft) -> String {
        let names = draft.selectedEvent?.attendeeNames ?? []
        guard !names.isEmpty else { return "no attendees" }
        let ceiling = CalendarEvent.limitedAttendees(names).count
        if names.count > ceiling {
            return "\(ceiling) of \(names.count) attendees"
        }
        return "\(names.count) attendee\(names.count == 1 ? "" : "s")"
    }

    // MARK: - Buttons

    private func footer(inFlight: Bool, draft: CalendarSyncController.Draft) -> some View {
        HStack {
            Text(inFlight ? "Applies to this recording" : "Applies to your next recording")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                sync.cancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("Link") {
                sync.confirm()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(draft.selectedEvent == nil)
            .accessibilityIdentifier("calendar.sync.confirm")
        }
        .padding(.top, 6)
    }
}
