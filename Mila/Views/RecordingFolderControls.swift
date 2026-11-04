import SwiftUI

/// Isolated leaf views for the recording folder / meeting-name controls.
///
/// These deliberately observe ONLY `RecordingStore` (for the folder list) and
/// `QuickActionsController` (for the bindings) — never the high-frequency
/// `LiveTranscriber` / `TranscriptionService` / `LiveAISession`. That isolation
/// is the whole point: on the live recording screen, the detail view during an
/// active transcription, and the post-stop rename sheet, those objects
/// `@Publish` many times per second. When an interactive `Menu` (backed by a
/// native NSMenu that runs a nested modal event-tracking runloop while open)
/// lives in a body that re-renders at that cadence, the menu host gets
/// reconciled mid-tracking and the whole app beachballs.
///
/// By pulling the controls into leaves whose inputs are constant/stable, the
/// parent body can churn as much as it likes without ever re-invoking these
/// bodies — so the open menu stays untouched. Same rationale as
/// `RecordingElapsedLabel` isolating `RecordingSession`.

/// Folder picker for the NEXT recording (Home + live recording screen). Binds
/// to `QuickActionsController.nextRecordingFolder`, applied when the recording
/// is saved.
struct NextRecordingFolderPicker: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var actions: QuickActionsController
    let accessibilityID: String

    var body: some View {
        Menu {
            Button(actions.nextRecordingFolder == nil ? "✓ All Transcriptions" : "All Transcriptions") {
                actions.nextRecordingFolder = nil
            }
            if !store.folders.isEmpty {
                Divider()
                ForEach(store.folders, id: \.self) { folder in
                    Button(actions.nextRecordingFolder == folder ? "✓ \(folder)" : folder) {
                        actions.nextRecordingFolder = folder
                    }
                }
            }
        } label: {
            Text(actions.nextRecordingFolder ?? "All Transcriptions")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Optional meeting-name field for the NEXT recording (Home + live recording
/// screen). Isolated so typing stays responsive even while the surrounding
/// screen re-renders at transcript cadence. Callers apply `.textFieldStyle` /
/// `.font` via modifiers (both propagate into the inner `TextField` through the
/// environment).
struct NextRecordingMeetingNameField: View {
    @EnvironmentObject private var actions: QuickActionsController
    let placeholder: String
    let accessibilityID: String

    var body: some View {
        TextField(placeholder, text: $actions.nextRecordingTitle)
            .accessibilityIdentifier(accessibilityID)
    }
}

/// Calendar-sync button for the next/current recording (Home + live recording
/// screen). Same leaf rationale as the name field and folder picker above, and
/// the reason it must be one: the live header re-renders at transcript cadence,
/// and a native control inside a body that churns that fast is how the app
/// beachballs with an open menu (#248 family).
///
/// Renders nothing when the integration is off or every behaviour is switched
/// off. When something IS linked it shows the event title, because the whole
/// point of pressing it mid-meeting is to see whether the meeting got linked at
/// all — and to be able to change the choice.
struct NextRecordingCalendarButton: View {
    @EnvironmentObject private var calendarSettings: CalendarSettings
    @EnvironmentObject private var calendarSync: CalendarSyncController
    let accessibilityID: String

    var body: some View {
        if calendarSettings.isEnabled && calendarSettings.hasWorkToDo {
            Button {
                calendarSync.present()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: linked != nil ? "calendar.circle.fill" : "calendar")
                        .foregroundStyle(linked != nil ? Color.accentColor : Color.secondary)
                    if let title = linked?.eventTitle {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("Calendar")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(calendarSync.isWorking)
            .frame(maxWidth: 200)
            .help(helpText)
            .accessibilityIdentifier(accessibilityID)
        }
    }

    /// The link the recording on screen carries — for the live header that is
    /// the recording in flight, for Home the one about to be recorded. Both are
    /// the same one-shot, which is what makes the button honest in both places.
    private var linked: CalendarLink? {
        calendarSync.liveCalendarLink
    }

    private var helpText: String {
        if calendarSync.isWorking {
            return "Checking your calendar…"
        }
        if let linked {
            return "Linked to “\(linked.eventTitle)” — click to change what's synced"
        }
        return "Link this recording to a calendar event happening now"
    }
}

/// Inline folder picker for an EXISTING recording (recording detail view).
/// Files the recording via `store.assign` and offers a "New Folder…" flow. Takes
/// the recording id + its current folder as stable inputs (both only change when
/// the folder actually changes), so an active transcription's progress flood
/// never re-invokes this body.
struct RecordingFolderMenu: View {
    @EnvironmentObject private var store: RecordingStore
    let recordingID: UUID
    let currentFolder: String?

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""

    var body: some View {
        Menu {
            Button(currentFolder == nil ? "✓ None" : "None") {
                assign(nil)
            }
            if !store.folders.isEmpty {
                Divider()
                ForEach(store.folders, id: \.self) { folder in
                    Button(currentFolder == folder ? "✓ \(folder)" : folder) {
                        assign(folder)
                    }
                }
            }
            Divider()
            Button("New Folder…") {
                newFolderName = ""
                showingNewFolderAlert = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(currentFolder ?? "No folder")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the folder this recording is filed under")
        .accessibilityIdentifier("detail.folder.menu")
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { assign(name) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("File this recording into a new folder.")
        }
    }

    private func assign(_ folder: String?) {
        guard let rec = store.recordings.first(where: { $0.id == recordingID }) else { return }
        store.assign(rec, toFolder: folder)
    }
}
