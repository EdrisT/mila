import XCTest
@testable import Mila

/// Verifies how `RecordingSummarizer` and `ObsidianExporter` are sequenced.
///
/// Since #3934 the note is filed from the transcription-completion hook, straight
/// from the transcript — there is no automatic summary whose completion the write
/// could wait for, so the old `pending` gate is gone. What remains of the
/// sequencing contract, and what these tests pin:
///   * a summary written later (the user pressed Summarize / Regenerate)
///     RE-writes the same note, so the vault carries the overview rather than the
///     transcript fallback;
///   * a recording that left the store — deleted, trashed, or discarded — is
///     never filed by a completion hook that arrives afterwards.
@MainActor
final class ObsidianExportSequencingTests: XCTestCase {

    private var tempRoot: URL!
    private var vault: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var obsidianDefaults: UserDefaults!
    private var suiteNames: [String] = []
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var settings: ObsidianVaultSettings!
    private var exporter: ObsidianExporter!
    private var summarizer: RecordingSummarizer!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaObsidianSeqTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot.appendingPathComponent("AppSupport", isDirectory: true))

        let llmSuite = "ObsidianSeq.llm.\(UUID())"
        let liveSuite = "ObsidianSeq.live.\(UUID())"
        let obsSuite = "ObsidianSeq.obs.\(UUID())"
        suiteNames = [llmSuite, liveSuite, obsSuite]
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        obsidianDefaults = UserDefaults(suiteName: obsSuite)
        llm = LLMSettings(defaults: UserDefaults(suiteName: llmSuite)!)
        llm.tool = .claude
        liveAI = LiveAISettings(defaults: liveDefaults)
        liveAI.model = ""

        settings = ObsidianVaultSettings(defaults: obsidianDefaults)
        settings.enabled = true
        settings.subfolder = ""
        XCTAssertTrue(settings.setVault(vault))
        exporter = ObsidianExporter(settings: settings, defaults: obsidianDefaults)

        // Wire the hook exactly like MilaApp does: the summarizer's completion
        // re-files the note so it carries the summary.
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                         runLLM: { _, _, _, _, _, _, _, _, _, _, _ in "A tidy summary." })
        summarizer.onSummaryFinished = { [weak exporter] rec in
            exporter?.export(rec)
        }
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    /// Rebuild the summarizer with a stub that fails, keeping the same hook
    /// wiring MilaApp uses. Models "the LLM call blew up" and, combined with a
    /// delete, "the user cancelled/deleted while it was in flight".
    private func useFailingLLM() {
        struct StubFailure: Error {}
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                         runLLM: { _, _, _, _, _, _, _, _, _, _, _ in
                                             throw StubFailure()
                                         })
        summarizer.onSummaryFinished = { [weak exporter] rec in
            exporter?.export(rec)
        }
    }

    private func addRecording(fullText: String = "some transcript") -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: "Rec")
        try? Data("x".utf8).write(to: audioURL)
        let rec = Recording(title: "Rec", source: .microphone,
                            audioFileName: audioURL.lastPathComponent, fullText: fullText)
        store.add(rec)
        return rec
    }

    private func notePath(for rec: Recording) -> URL {
        vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
    }

    /// The summary path re-writes the note the completion hook already filed, so
    /// the vault ends up with the overview rather than the transcript fallback.
    func test_a_summary_landing_after_the_note_rewrites_it() async throws {
        let rec = addRecording(fullText: "the raw transcript body")
        // The completion hook's write: transcript only, no summary yet.
        XCTAssertNotNil(exporter.export(rec))
        var contents = try String(contentsOf: notePath(for: rec), encoding: .utf8)
        XCTAssertTrue(contents.contains("## Transcript"), "precondition: the fallback note")
        XCTAssertFalse(contents.contains("A tidy summary."))

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: notePath(for: rec).path))
        contents = try String(contentsOf: notePath(for: rec), encoding: .utf8)
        XCTAssertTrue(contents.contains("A tidy summary."),
                      "the note must carry the summary once one exists")
    }

    /// A note written before any summary exists is a transcript-fallback note —
    /// and with automatic summaries gone that is the state most recordings sit in
    /// until the user asks.
    func test_a_recording_is_filed_from_the_transcript_alone() throws {
        let rec = addRecording(fullText: "the raw transcript body")
        XCTAssertNotNil(exporter.export(rec))
        let contents = try String(contentsOf: notePath(for: rec), encoding: .utf8)
        XCTAssertTrue(contents.contains("## Transcript"))
        XCTAssertTrue(contents.contains("the raw transcript body"))
    }

    /// A failed summary must not damage the note that is already there.
    func test_a_failed_summary_leaves_the_filed_note_alone() async throws {
        useFailingLLM()
        let rec = addRecording(fullText: "the raw transcript body")
        XCTAssertNotNil(exporter.export(rec))
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                      "a failed summary must not take the note out")
        let contents = try String(contentsOf: notePath(for: rec), encoding: .utf8)
        XCTAssertTrue(contents.contains("the raw transcript body"))
    }

    /// Deleted mid-flight — the failure path. The hook must not fire with the
    /// caller's enqueue-time copy, or a recording the user just deleted lands in
    /// the vault anyway.
    func test_recording_deleted_mid_flight_is_not_exported() async throws {
        useFailingLLM()
        let rec = addRecording(fullText: "the raw transcript body")
        summarizer.summarizeIfNeeded(rec)
        store.permanentlyDelete(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "a recording deleted mid-flight must not be filed")
    }

    /// The same race on the SUCCESS path: `test_recording_deleted_mid_flight…`
    /// above forces a failure, so it only exercises the `catch` block's liveness
    /// check; this one lets the summary complete normally so the separate guard
    /// on the success path (`RecordingSummarizer`'s "is this recording still in
    /// the store?" lookup) is the thing under test.
    func test_recording_deleted_mid_flight_is_not_exported_on_the_success_path() async throws {
        let rec = addRecording(fullText: "the raw transcript body")
        summarizer.summarizeIfNeeded(rec)
        store.permanentlyDelete(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "a recording deleted mid-flight must not be filed, "
                       + "even when its summary succeeds")
    }

    /// Trashed mid-flight: the hook does fire (the row is still in the store),
    /// but the exporter refuses to file a trashed recording.
    func test_recording_trashed_mid_flight_is_not_exported() async throws {
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        store.softDelete(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "a recording trashed mid-flight must not be filed")
    }

    // MARK: - Discard un-exports

    /// The export already landed before the user hit Discard — the note has to
    /// come back out of the vault, or discarding is something the app visibly
    /// ignored.
    func test_discardNote_removes_an_already_exported_note() async throws {
        let rec = addRecording()
        XCTAssertNotNil(exporter.export(rec), "precondition")

        exporter.discardNote(for: rec)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "the note for a discarded recording is still in the vault")
    }

    /// The other ordering: Discard lands while the summary is still running, so
    /// the re-write it triggers must never happen.
    func test_discard_before_the_summary_lands_blocks_the_export() async throws {
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        exporter.discardNote(for: rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "a summary landing after Discard must not file the note")
    }

    /// Nothing was ever written for this recording — removal is a no-op rather
    /// than a delete of whatever happens to share the name.
    func test_discardNote_is_a_noop_when_nothing_was_exported() {
        let rec = addRecording()
        XCTAssertNil(exporter.discardNote(for: rec))
    }

    /// Discard has to be a TOMBSTONE, not "delete the note if there is one".
    /// `PostRecordingCoordinator.cancelAndDiscard` does not cancel
    /// `QuickActionsController.finalizeTail`, which is still running — on the
    /// VAD path it awaits the OFFLINE re-diarize — and ends by exporting the note
    /// itself. A *skipped* summary (no provider configured, empty transcript)
    /// also fires `onSummaryFinished` synchronously. So the tombstone, not the
    /// absence of a note, is what keeps a discarded recording out of the vault.
    func test_a_late_finalize_tail_cannot_re_export_a_discarded_recording() async throws {
        let rec = addRecording()
        // The reachable path: no summary will be generated, so the completion
        // hook fires synchronously rather than going through `runSummary`
        // (whose "is the row still in the store?" lookup already covers the
        // success path).
        llm.tool = .none

        exporter.discardNote(for: rec)
        store.permanentlyDelete(rec)   // as `cancelAndDiscard` does

        // `finalizeTail`, still in flight, drives the export for the same id.
        XCTAssertNil(exporter.export(rec),
                     "a discarded recording must not be exportable by a late hook")
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath(for: rec).path),
                       "a recording the user discarded must not be filed by a late completion hook")
    }

    /// A failed delete must not forget where the note is. The written-index
    /// entry is the ONLY record of the path, so dropping it before `removeItem`
    /// succeeds strands the transcript the user threw away in the vault with no
    /// way for any later discard to find it.
    func test_a_failed_removal_keeps_the_index_entry_for_a_retry() throws {
        let failingExporter = ObsidianExporter(settings: settings,
                                               defaults: obsidianDefaults,
                                               fileManager: RemoveFailingFileManager())
        let rec = addRecording()
        let note = try XCTUnwrap(failingExporter.export(rec), "precondition: the note was written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))

        XCTAssertNil(failingExporter.discardNote(for: rec),
                     "a removal that failed must not report a removed file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path),
                      "precondition: the stubbed delete really did fail")

        // A fresh exporter over the SAME index — this is the retry path, and it
        // only exists if the entry survived the failure above.
        let retry = ObsidianExporter(settings: settings, defaults: obsidianDefaults)
        XCTAssertNotNil(retry.discardNote(for: rec),
                        "the index entry must survive a failed removal so a retry can find the note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path),
                       "the retry must actually take the note out of the vault")
    }

    /// The hook fires exactly once per attempt: a second export for the same
    /// recording only happens on a second, deliberate summarize attempt.
    func test_hook_fires_once_per_attempt() async throws {
        final class Recorder { var ids: [UUID] = [] }
        let fired = Recorder()
        summarizer.onSummaryFinished = { fired.ids.append($0.id) }
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        // A duplicate call while the first is in flight is deduped and must
        // NOT produce a second signal.
        summarizer.summarizeIfNeeded(rec)
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(fired.ids, [rec.id], "one attempt in flight must yield exactly one signal")
    }
}

/// Every operation is the real `FileManager` except `removeItem`, which always
/// fails. Models a vault the app can read and write but not delete from — a
/// read-only volume, a permissions change, or an offline network mount.
private final class RemoveFailingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain,
                      code: NSFileWriteNoPermissionError,
                      userInfo: [NSFilePathErrorKey: url.path])
    }
}
