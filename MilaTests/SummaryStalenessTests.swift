import XCTest
@testable import Mila
import MilaKit

/// The staleness marker a completed re-transcription leaves on a summary it
/// invalidated (#3934).
///
/// Summaries are only ever made when the user asks, so re-running a transcript in
/// a better model no longer rewrites the overview — the row keeps the one it has.
/// The marker is what stops that overview from being presented as current, in the
/// app and on every surface that reads the store from outside it, so these tests
/// cover the write, the persistence, the cross-process mirror, and the one place
/// the flag is cleared.
@MainActor
final class SummaryStalenessTests: XCTestCase {

    private var root: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryStaleness-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: root)

        let llmSuite = "SummaryStaleness.llm.\(UUID())"
        let liveSuite = "SummaryStaleness.live.\(UUID())"
        suiteNames = [llmSuite, liveSuite]
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    @discardableResult
    private func addRecording(_ title: String, summary: String?) -> Recording {
        let audio = store.freshAudioURL(suggestedName: title)
        try? Data("x".utf8).write(to: audio)
        var rec = Recording(title: title, source: .microphone,
                            audioFileName: audio.lastPathComponent,
                            fullText: "alpha beta gamma")
        rec.summary = summary
        rec.status = .completed
        store.add(rec)
        return rec
    }

    private func row(_ id: UUID) -> Recording? {
        store.recordings.first { $0.id == id }
    }

    // MARK: - The write

    func test_a_retranscription_flags_the_summary_it_leaves_behind() {
        let rec = addRecording("Standup", summary: "Overview of the first pass")

        XCTAssertTrue(store.markSummaryStale(recordingID: rec.id))

        let stored = row(rec.id)
        XCTAssertEqual(stored?.summary, "Overview of the first pass",
                       "the summary itself is KEPT — a re-run must not throw away an overview the user already has")
        XCTAssertNotNil(stored?.summaryStaleAt, "and the row says it no longer matches its transcript")
        XCTAssertTrue(stored?.summaryIsStale == true)
    }

    func test_marking_is_idempotent_and_keeps_the_first_timestamp() throws {
        let rec = addRecording("Standup", summary: "Overview")
        let first = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(store.markSummaryStale(recordingID: rec.id, at: first))
        XCTAssertFalse(store.markSummaryStale(recordingID: rec.id,
                                             at: first.addingTimeInterval(600)),
                       "a second re-transcription does not re-date the same stale summary")

        XCTAssertEqual(row(rec.id)?.summaryStaleAt, first)
    }

    /// The flag only means something next to a summary. Flagging a row with none
    /// would write a key that asserts nothing and — worse — change the bytes of
    /// every ordinary recording's row.
    func test_a_row_without_a_summary_is_never_flagged() {
        let none = addRecording("Fresh", summary: nil)
        let blank = addRecording("Blank", summary: "   \n ")

        XCTAssertFalse(store.markSummaryStale(recordingID: none.id))
        XCTAssertFalse(store.markSummaryStale(recordingID: blank.id))
        XCTAssertFalse(store.markSummaryStale(recordingID: UUID()),
                       "an unknown id is a no-op, not a crash")

        XCTAssertNil(row(none.id)?.summaryStaleAt)
        XCTAssertNil(row(blank.id)?.summaryStaleAt)
        XCTAssertFalse(row(blank.id)?.summaryIsStale == true,
                       "the whitespace summary has nothing to be stale about")
    }

    // MARK: - Persistence + the cross-process mirror

    func test_the_marker_survives_a_relaunch_and_reaches_the_mcp_mirror() throws {
        let kept = addRecording("Re-run", summary: "Overview of the earlier pass")
        let untouched = addRecording("Never re-run", summary: "Current overview")

        // Before the flag exists, the key is not in the JSON at all — an
        // unaffected row encodes exactly as it did before the field existed.
        let before = try Data(contentsOf: root.appendingPathComponent("recordings.json"))
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("summaryStaleAt"),
                       "no key for a row that was never re-transcribed")

        XCTAssertTrue(store.markSummaryStale(recordingID: kept.id,
                                            at: Date(timeIntervalSince1970: 1_700_000_000)))

        // Read the store the way an outside reader does: fresh decode of the
        // file on disk, through MilaKit's own mirror type.
        let data = try Data(contentsOf: root.appendingPathComponent("recordings.json"))
        // Same date strategy the app writes with (`RecordingStore`'s encoder and
        // MilaKit's own reader both use `.iso8601`).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mirrored = try decoder.decode([StoredRecording].self, from: data)
        let mirrorOfKept = try XCTUnwrap(mirrored.first { $0.id == kept.id })
        let mirrorOfUntouched = try XCTUnwrap(mirrored.first { $0.id == untouched.id })
        XCTAssertEqual(mirrorOfKept.summaryStaleAt, Date(timeIntervalSince1970: 1_700_000_000),
                       "MilaKit's mirror carries the marker, so mila-mcp can tell a client the overview is out of date")
        XCTAssertEqual(mirrorOfKept.summary, "Overview of the earlier pass")
        XCTAssertNil(mirrorOfUntouched.summaryStaleAt)

        // And the app's own reader agrees after a relaunch.
        let reloaded = RecordingStore(rootDirectory: root)
        XCTAssertEqual(reloaded.recordings.first { $0.id == kept.id }?.summaryStaleAt,
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(reloaded.recordings.first { $0.id == untouched.id }?.summaryStaleAt)
    }

    // MARK: - Clearing

    /// A summary generated now is current by definition, so the marker goes with
    /// the write that stores it — in one update, so no window opens where a
    //  fresh overview and an "out of date" badge sit on the same row.
    func test_generating_a_summary_clears_the_marker() async throws {
        let llm = LLMSettings(defaults: llmDefaults, apiKeyKeychainKey: "SummaryStalenessTests.key")
        llm.tool = .claude
        let liveAI = LiveAISettings(defaults: liveDefaults)
        liveAI.model = ""
        let summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                             runLLM: { _, _, _, _, _, _, _, _, _, _, _ in
            "A fresh overview."
        })

        let rec = addRecording("Re-run", summary: "Overview of the earlier pass")
        XCTAssertTrue(store.markSummaryStale(recordingID: rec.id))
        XCTAssertTrue(row(rec.id)?.summaryIsStale == true)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let stored = try XCTUnwrap(row(rec.id))
        XCTAssertEqual(stored.summary, "A fresh overview.")
        XCTAssertNil(stored.summaryStaleAt,
                     "the write that replaced the summary must clear the flag with it")
        XCTAssertFalse(stored.summaryIsStale)
    }
}
