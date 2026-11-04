import AppKit
import SwiftUI

/// Fork addition: a menu bar item — start/stop a recording and get back to the
/// main window without ever touching the Dock. The icon turns red while a
/// capture is running.
///
/// Why this file is thin:
///
/// **Recording is not re-implemented here.** Start and stop route through
/// `QuickActionsController.toggleRecord(microphone:appAudio:)` and
/// `.stopRecording()` — the exact entry point Home's Record button uses — so the
/// guards that live in the controller keep protecting the menu path too: the
/// `isStoppingRecording` gate, and the `.starting` window (#293) where a second
/// press must not bring up a SECOND capture. A menu item that called
/// `session.start(...)` directly would bypass both.
///
/// **No new app-level state.** `actions` is already a `@StateObject` on `MilaApp`
/// and `activeJob` flips once per recording, so the item observes recording
/// state for free and `AppSceneChurnProbe` needs no new registration.
///
/// **Nothing here may read `session.meters`.** The elapsed clock and the two
/// level meters publish at audio-buffer cadence (up to ~50 Hz); they live on
/// `RecordingMeters` precisely so they never re-publish an object the App scene
/// builds (#280 — that bug pinned the main thread at 60–75% CPU for whole
/// recordings). A live timer in this menu would be cheap to add and expensive
/// to run, so it is deliberately absent.
enum MilaWindow {
    /// Scene id of the main window, shared by the `WindowGroup` and the menu so
    /// `openWindow(id:)` cannot drift from the scene declaration.
    static let mainID = "main"
}

/// The status item's glyph. Idle stays a template image (so macOS tints it for
/// light/dark/high-contrast menu bars); recording is drawn in red and flagged
/// non-template, because the system re-tints template images and would erase
/// exactly the signal we want.
enum MenuBarIcon {
    /// SF Symbol point size that reads well inside the menu bar's ~22 pt height.
    private static let symbolPointSize: CGFloat = 13

    static func image(isRecording: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        let symbol = NSImage(systemSymbolName: isRecording ? "mic.fill" : "mic",
                             accessibilityDescription: isRecording ? "Mila recording" : "Mila")?
            .withSymbolConfiguration(configuration)
        guard let symbol else { return placeholder(isRecording: isRecording) }

        guard isRecording else {
            symbol.isTemplate = true
            return symbol
        }

        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.systemRed.set()
            // `sourceAtop` repaints only the pixels the glyph already covers,
            // so the symbol's shape (and its anti-aliasing) survives.
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// Fallback glyph if the SF Symbol cannot be resolved. Should not happen on
    /// macOS 14, but a status item with no image is invisible, so draw
    /// something rather than return nothing.
    private static func placeholder(isRecording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { rect in
            (isRecording ? NSColor.systemRed : NSColor.labelColor).set()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = !isRecording
        return image
    }
}

/// The menu behind the status item.
struct MenuBarItemContent: View {
    @EnvironmentObject private var actions: QuickActionsController
    @Environment(\.openWindow) private var openWindow

    /// Home's OWN `@AppStorage` keys (`HomeView`), so the menu records whatever
    /// the main window's Microphone / App-audio toggles currently say instead
    /// of inventing a second, contradicting preference.
    @AppStorage("home.record.microphone") private var recordMicrophone = true
    @AppStorage("home.record.withSystemAudio") private var withSystemAudio = true

    /// A start is already in flight (#293 — on Bluetooth inputs capture bring-up
    /// takes seconds). The controller drops a second press; say so rather than
    /// look unresponsive.
    private var isStartingRecording: Bool {
        if case .starting = actions.activeJob { return true }
        return false
    }

    var body: some View {
        Button(action: toggleRecording) {
            Label(actions.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: actions.isRecording ? "stop.fill" : "mic.fill")
        }
        .disabled(actions.isStoppingRecording
                  || actions.isFinalizingRecording
                  || isStartingRecording)

        // Status lines, and the reasons a menu-bar start can silently do nothing
        // — the main window shows these inline, the menu has to spell them out.
        if isStartingRecording { Text("Starting…") }
        if actions.isRecording { Text("Recording…") }
        if actions.isFinalizingRecording { Text("Finalizing…") }
        if actions.microphonePermissionMissing {
            Text("Microphone permission missing")
        }
        if withSystemAudio && actions.screenRecordingPermissionMissing {
            Text("Screen Recording permission missing")
        }

        Divider()

        Button("Show Main Window", action: showMainWindow)

        Divider()

        // Routes through `MilaAppDelegate.applicationShouldTerminate`, which is
        // where an in-flight capture gets stopped before the process exits.
        Button("Quit Mila") { NSApplication.shared.terminate(nil) }
    }

    @MainActor
    private func toggleRecording() {
        Task { @MainActor in
            if actions.isRecording {
                await actions.stopRecording()
                return
            }
            var microphone = recordMicrophone
            var appAudio = withSystemAudio
            // Both Home toggles off ⇒ Home disables its own Record button, but a
            // menu-bar press is an explicit intent. Record the microphone.
            if !microphone && !appAudio { microphone = true }
            await actions.toggleRecord(microphone: microphone, appAudio: appAudio)
        }
    }

    /// Raise the existing window rather than stack a second one: `WindowGroup`
    /// allows multiple windows, so `openWindow(id:)` alone would open a fresh
    /// one on every click once the first is already on screen. SwiftUI gives the
    /// `NSWindow` the scene id as its identifier, and `WindowGroup("Mila")`
    /// titles it "Mila" (nothing in the content sets a `navigationTitle`), so
    /// match either.
    @MainActor
    private func showMainWindow() {
        let existing = NSApp.windows.first { window in
            window.canBecomeMain
                && (window.identifier?.rawValue.contains(MilaWindow.mainID) ?? false
                    || window.title == "Mila")
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MilaWindow.mainID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
