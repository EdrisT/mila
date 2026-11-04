import Foundation

/// Supplies the calendar event the recording currently on the live pipeline is
/// synced with, if any (calendar integration).
///
/// The seam that keeps `LiveAISession` free of EventKit: the session asks a
/// conforming object "what is the current recording synced to" and gets a
/// plain `CalendarLink` from `Mila/Models`. `CalendarSyncController` is the
/// only conformer, and it answers from
/// `QuickActionsController.nextRecordingCalendarLink` — the one-shot that is
/// cleared at Stop — which is what makes "a previous recording's invite
/// bleeding into this recording's prompt" structurally impossible rather than
/// a matter of clearing state in the right order.
@MainActor
protocol CalendarContextSource: AnyObject {
    var liveCalendarLink: CalendarLink? { get }
}
