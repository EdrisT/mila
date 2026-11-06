import XCTest
import TranscriptionCore
@testable import Mila

/// Tests for the post-record summarizer that runs whenever the LLM CLI
/// is configured (not just when Live AI mode was active).
///
/// End-to-end invocation goes through `RecordingSummarizer`'s injectable
/// `runLLM` seam (see `RecordingSummarizer.RunLLM`) rather than spawning a
/// real `claude`/`/bin/sh` subprocess. Earlier revisions wrote a temp shell
/// script and pointed `LLMSettings.executablePath` at it; under CI
/// contention the spawn / exec / pipe-drain could hiccup or time out, the
/// summarizer's `catch` would swallow the error, no summary got written, and
/// the assertion failed intermittently (e.g. CI run 28448415130). Injecting
/// a synchronous canned-output closure removes the subprocess-timing
/// dependency entirely, so these assertions are deterministic by
/// construction — no real CLI installed, no child process, no flake.
@MainActor
final class RecordingSummarizerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var summarizer: RecordingSummarizer!

    private let llmSuite = "RecordingSummarizerTests.llm"
    private let liveSuite = "RecordingSummarizerTests.liveAI"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecordingSummarizerTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        llm = LLMSettings(defaults: llmDefaults)
        liveAI = LiveAISettings(defaults: liveDefaults)
        // Default summarizer uses the production `runLLM` (real CLI). The
        // gate-only tests below never reach it; the end-to-end tests rebuild
        // `summarizer` via `useStubRunner` with a deterministic stub.
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        try await super.tearDown()
    }

    // MARK: - Gate

    func test_should_summarize_false_when_llm_not_configured() {
        llm.tool = .none
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_summary_already_present() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        rec.summary = "already have one"
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_transcript_is_empty() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_true_when_configured_and_no_summary() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        XCTAssertTrue(summarizer.shouldSummarize(rec))
    }



    func test_should_summarize_treats_whitespace_summary_as_empty() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        rec.summary = "   \n  "
        XCTAssertTrue(summarizer.shouldSummarize(rec),
                      "Whitespace-only summary should not block regeneration")
    }

    // MARK: - End-to-end via injected runner

    /// Verify the summarizer actually writes the LLM output to the
    /// recording's `summary` field, and that the sidecar lands too. The
    /// injected runner returns a canned summary synchronously — no real CLI.
    func test_summarize_stores_output_on_recording_and_writes_sidecar() async throws {
        llm.tool = .claude
        liveAI.model = ""
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            "A concise summary of the meeting."
        }

        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        // The audio file needs to exist for `RecordingStore.add` to be
        // happy, but the summarizer never reads it — only `fullText`.
        try Data("not-audio".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Meeting",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap and agreed to ship next week"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")
        let sidecar = store.summaryURL(for: updated)
        let onDisk = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(onDisk, "A concise summary of the meeting.")
    }

    /// The core "right call" assertion: when a transcript is ready, the
    /// summarizer must invoke the configured CLI ONCE, in claude's one-shot
    /// `-p` shape, with the transcript embedded in the prompt via
    /// `LLMRunner.composedPrompt`. The stub reconstructs the exact argv the
    /// app WOULD have launched — by feeding the prompt/model it was handed
    /// through `LLMTool.arguments`, the same call the production `runLLM`
    /// makes — and records it, so we still assert the wire shape without a
    /// real subprocess. This is what replaced the old real-Anthropic e2e:
    /// instead of asking a live model and judging its answer, we verify Mila
    /// issues the correct invocation off the back of a transcription.
    func test_summarize_invokes_cli_with_transcript_in_one_shot_prompt() async throws {
        llm.tool = .claude
        liveAI.model = ""   // keep argv minimal: no --model passthrough

        // Capture the argv the app would have launched. The production
        // runner (`LLMRunner.run`) composes the user prompt + transcript via
        // `composedPrompt` BEFORE handing the blob to `LLMTool.arguments`, so
        // the stub does the same here — that's what embeds the transcript and
        // the "Transcript:" label into the `-p` argument. Reconstructing the
        // argv this way proves the one-shot `-p` shape without a subprocess.
        var capturedArgs: [String] = []
        var callCount = 0
        useStubRunner { tool, prompt, transcript, _, model, extraArgs, _, _, _, _, _ in
            callCount += 1
            let composed = LLMRunner.composedPrompt(prompt, transcript: transcript)
            capturedArgs = tool.arguments(prompt: composed, model: model) + extraArgs
            return "A concise summary of the meeting."
        }

        let transcript = "we discussed the roadmap and agreed to ship next week"
        let audioURL = store.freshAudioURL(suggestedName: "Call")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Call",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: transcript
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        // The CLI ran exactly once and its output was stored.
        XCTAssertEqual(callCount, 1, "the summarizer must invoke the CLI exactly once")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")

        // Assert the SHAPE of the call the app made.
        XCTAssertTrue(capturedArgs.contains("-p"),
                      "claude must be invoked in one-shot `-p` mode; got argv=\(capturedArgs)")
        let prompt = try XCTUnwrap(capturedArgs.first { $0.contains(transcript) },
                                   "the transcript must be embedded in the prompt; argv=\(capturedArgs)")
        XCTAssertTrue(prompt.contains("Transcript:"),
                      "prompt should use LLMRunner.composedPrompt's labelled format")
    }

    /// Empty CLI output must NOT clobber a (currently nil) summary — we
    /// don't want a wedged CLI to mask the recording as "summarized".
    func test_summarize_drops_empty_output() async throws {
        llm.tool = .claude
        // Stub returns empty output — the production runner trims stdout, so
        // an empty return models a CLI that printed nothing useful.
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "" }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary)
    }

    /// If a live summary lands between enqueue and the CLI returning, the
    /// summarizer must NOT overwrite it. Deterministic: the stub blocks on a
    /// gate the test opens AFTER patching the store, so the "summary landed
    /// mid-flight" ordering is guaranteed without any `sleep`.
    func test_summarize_does_not_overwrite_summary_that_landed_mid_flight() async throws {
        llm.tool = .claude

        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            // Block until the test has patched the store, then return the
            // (now stale) CLI output.
            await gate.wait()
            return "OVERWRITE"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Race")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Race",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        // The runner is now parked in `gate.wait()`. Patch the store to
        // simulate a live summary landing while the one-shot CLI was still
        // running, then release the gate so the runner returns.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "runner should be in flight before we patch the store")
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.summary = "live_summary_from_recording"
            store.update(current)
        }
        gate.open()

        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "live_summary_from_recording",
                       "Late-arriving CLI output must not overwrite a summary that already exists")
    }



    // MARK: - Force / regenerate path

    /// `regenerate(_:)` must overwrite an existing summary — that's the
    /// whole point of the affordance. Without this the "Regenerate
    /// summary" context-menu item and the re-transcribe hook would both
    /// silently no-op.
    ///
    /// This is the test that was flaky on CI: previously it spawned a real
    /// `/bin/sh` script via the CLI runner and asserted on the result, so a
    /// subprocess hiccup made the summary fail to land. With the injected
    /// runner there's no subprocess — the canned "REGENERATED" is returned
    /// synchronously and the assertion is deterministic.
    func test_regenerate_overwrites_existing_summary() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "REGENERATED" }

        let audioURL = store.freshAudioURL(suggestedName: "Regen")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Regen",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the new transcript text"
        )
        rec.summary = "stale summary from a previous run"
        store.add(rec)

        // `summarizeIfNeeded` would bail because a summary already
        // exists; `regenerate` bypasses that gate.
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "REGENERATED")
    }

    /// `regenerate` still respects the two hard requirements:
    /// LLM configured + non-empty transcript.
    func test_regenerate_noops_when_llm_not_configured() async throws {
        llm.tool = .none
        var called = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "NoLLM")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "NoLLM",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        rec.summary = "old summary"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an unconfigured LLM means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task when the LLM is unconfigured")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked when the LLM is unconfigured")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old summary")
    }

    func test_regenerate_noops_when_transcript_empty() async throws {
        llm.tool = .claude
        var called = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: ""
        )
        rec.summary = "old"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an empty transcript means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task for an empty transcript")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked for an empty transcript")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old",
                       "Empty transcript must not trigger a CLI call")
    }

    /// `isSummarizing(_:)` flips true while a call is in flight and back
    /// to false when it lands. The detail view's spinner depends on this.
    /// Deterministic: the stub parks on a gate the test opens, so the
    /// in-flight window is observed without timing on a `sleep`.
    func test_is_summarizing_tracks_in_flight_state() async throws {
        llm.tool = .claude
        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            await gate.wait()
            return "done"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Spin")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Spin",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        summarizer.summarizeIfNeeded(rec)
        // `inFlightIDs.insert` runs synchronously inside `summarizeIfNeeded`
        // (before the Task is even created), so the flag is true the instant
        // the call returns — and the runner is parked on the gate.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "isSummarizing should be true while CLI is running")

        // Release the runner and await the real task completion.
        gate.open()
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "isSummarizing should clear after CLI returns")
    }

    // MARK: - OpenAI-compatible model threading (issue celarent7/mila#4)

    /// The OpenAI-compatible summarizer must send `openAIModelName` (the
    /// user's configured endpoint model), NOT `liveAISettings.model` (a Live
    /// AI CLI override such as "claude-sonnet-4-6"). The latter 404's at the
    /// endpoint as model-not-found. Mirrors `LiveAISession.kick`'s
    /// tool-conditional selection.
    func test_summarize_threadsOpenAIModelName_forOpenAICompatible() async throws {
        llm.tool = .openaiCompatible
        llm.openAIBaseURL = "https://api.openai.com/v1"
        llm.openAIModelName = "gpt-4o-mini"
        // Live AI's model is intentionally a *different* name — if the
        // summarizer used it (the bug), the stub would record it here.
        liveAI.model = "claude-sonnet-4-6"

        var capturedModel: String? = ""
        useStubRunner { _, _, _, _, model, _, _, _, _, _, _ in
            capturedModel = model
            return "A concise summary."
        }

        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        try Data("not-audio".utf8).write(to: audioURL)
        let rec = Recording(title: "Meeting", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "we discussed the roadmap")
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(capturedModel, "gpt-4o-mini",
                       "The OpenAI summary path must send openAIModelName, not the Live AI model")
    }

    // MARK: - JSON envelope (summary + action items)

    /// The one-shot summarizer now asks for a JSON envelope so it can
    /// populate BOTH the summary and the action-items list from the full
    /// transcript — restoring the pair the pre-#87 inline final Live-AI
    /// tick used to produce. A well-formed envelope must land both halves.
    func test_summarize_parses_envelope_and_stores_summary_and_action_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            #"{"summary": "We agreed to ship next week.", "items": [{"id": "ship", "text": "Ship the beta", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}, {"id": "deck", "text": "Dana sends the deck", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}]}"#
        }

        let audioURL = store.freshAudioURL(suggestedName: "Envelope")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Envelope",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap and agreed to ship next week"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "We agreed to ship next week.")
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Ship the beta", "Dana sends the deck"])
    }

    /// Back-compat: a model that ignores the JSON instruction and returns
    /// plain prose must still have its whole output stored as the summary,
    /// with no action items — exactly the pre-change behaviour.
    func test_summarize_plain_text_output_still_stored_as_summary_without_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "Just a plain prose summary." }

        let audioURL = store.freshAudioURL(suggestedName: "Prose")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Prose",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Just a plain prose summary.")
        XCTAssertNil(updated.actionItems,
                     "plain-text output must not fabricate an action-items list")
    }

    /// `regenerate` (the Live-AI finalize path + manual affordance) must
    /// REPLACE stale action items with the fresh full-transcript set, the
    /// same way it already replaces the summary.
    func test_regenerate_replaces_action_items_from_full_transcript() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            #"{"summary": "Fresh summary.", "items": [{"id": "new", "text": "New follow-up", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}]}"#
        }

        let audioURL = store.freshAudioURL(suggestedName: "RegenItems")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "RegenItems",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "old", text: "Stale item", speaker: nil,
                                      timestampSeconds: 0, source: .llmInferred,
                                      addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Fresh summary.")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["New follow-up"],
                       "regenerate must replace the stale action items")
    }

    /// An empty (or absent) items list must NOT wipe action items the
    /// recording already has — e.g. a Live-AI recording's rolling snapshot.
    /// A glitchy prose response shouldn't cost the user their items.
    func test_regenerate_empty_items_preserves_existing_action_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "Only a prose summary, no JSON." }

        let audioURL = store.freshAudioURL(suggestedName: "KeepItems")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "KeepItems",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "keep", text: "Keep me", speaker: nil,
                                      timestampSeconds: 0, source: .llmInferred,
                                      addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Only a prose summary, no JSON.")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["Keep me"],
                       "an empty items response must not wipe existing action items")
    }

    /// The prompt's preferred shape: a plain-text summary, the sentinel on
    /// its own line, then a JSON array. The summary stays plain text (no JSON
    /// wrapping) and the items are parsed from the trailing array.
    func test_summarize_parses_sentinel_format() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            We agreed to ship next week and Dana owns the deck.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "ship", "text": "Ship the beta", "source": "inferred"}, {"id": "deck", "text": "Dana sends the deck", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "Sentinel")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Sentinel",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "We agreed to ship next week and Dana owns the deck.")
        XCTAssertFalse(updated.summary?.contains(RecordingSummarizer.actionItemsSentinel) ?? true,
                       "the sentinel marker must not leak into the summary")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["Ship the beta", "Dana sends the deck"])
    }

    /// Regression for the reported bug: the model returned a JSON envelope
    /// whose summary value had UNESCAPED quotes and newlines (Hebrew review),
    /// so the object decode failed. The summarizer must NOT dump the raw
    /// `{...}` blob into the summary — it salvages the summary text and still
    /// recovers the (independently valid) items array.
    func test_summarize_salvages_summary_from_malformed_json_envelope() async throws {
        llm.tool = .claude
        // Note the unescaped inner quotes around על חלל and the literal \n —
        // exactly what broke JSONDecoder in production.
        let malformed = #"{"summary": "השיחה עסקה בניהול צוות.\n\n• בייליס מתנהג כאילו הוא "על חלל" ואינו לוקח אחריות.", "items": [{"id": "a", "text": "להחזיר לבייליס ביקורת ישירה", "source": "inferred"}, {"id": "b", "text": "לנטרל את גוליאן משיחות פרודקט", "source": "inferred"}]}"#
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in malformed }

        let audioURL = store.freshAudioURL(suggestedName: "Malformed")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Malformed",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        let summary = try XCTUnwrap(updated.summary)
        XCTAssertFalse(summary.hasPrefix("{"),
                       "a raw JSON blob must never be shown as the summary")
        XCTAssertFalse(summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertTrue(summary.contains("השיחה עסקה בניהול צוות"),
                      "the real summary text must be salvaged")
        XCTAssertTrue(summary.contains("\n"),
                      "escaped newlines must be restored so it renders as lines")
        XCTAssertEqual(updated.actionItems?.count, 2,
                       "the valid items array must still be recovered")
    }

    // MARK: - Parsing the one-shot output (pure, no runner)

    /// `parseSummaryAndItems` must say WHICH shape it got. The tolerant
    /// paths are the whole point of this fix, and a model that quietly
    /// ignores the output contract on every single call should be
    /// diagnosable from Console rather than invisible.
    func test_parse_origin_reports_which_shape_arrived() {
        XCTAssertEqual(RecordingSummarizer.parseSummaryAndItems(from: "Plain prose.").origin,
                       .plain)
        XCTAssertEqual(
            RecordingSummarizer.parseSummaryAndItems(
                from: "A summary.\n\(RecordingSummarizer.actionItemsSentinel)\n[]"
            ).origin,
            .sentinel)
        XCTAssertEqual(
            RecordingSummarizer.parseSummaryAndItems(
                from: #"{"summary": "A summary.", "items": []}"#
            ).origin,
            .envelope)
    }

    /// A malformed envelope that is PRETTY-PRINTED. The salvage anchored on
    /// the separator spelled exactly `", "items"` / `","items"`, so
    /// multi-line JSON — what a CLI printing an indented object emits — fell
    /// through to "take everything up to the last quote" and dragged the
    /// whole items array into the summary. That is the same scaffolding leak
    /// the fix exists to prevent, just one whitespace variation away.
    ///
    /// `legacySalvageSummaryValue` below reproduces the old anchor and is
    /// asserted to leak, so the assertions here are provably discriminating
    /// rather than vacuous.
    func test_parse_salvages_pretty_printed_malformed_envelope_without_leaking_scaffolding() {
        let malformed = """
        {
          "summary": "Team review. Baylis acts as if he is "on another planet" and takes no ownership.",
          "items": [
            {"id": "a", "text": "Give Baylis direct feedback", "source": "inferred"}
          ]
        }
        """

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: malformed)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope)
        XCTAssertFalse(parsed.summary.hasPrefix("{"),
                       "a raw JSON blob must never be shown as the summary")
        XCTAssertFalse(parsed.summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertFalse(parsed.summary.contains("\"source\""),
                       "no item field may leak into the summary")
        XCTAssertTrue(parsed.summary.hasSuffix("takes no ownership."),
                      "the summary must end where its value ended; got \(parsed.summary)")
        XCTAssertTrue(parsed.summary.contains("\"on another planet\""),
                      "the unescaped quotes that broke the decode are part of the text")
        XCTAssertEqual(parsed.items.map(\.text), ["Give Baylis direct feedback"],
                       "the independently valid items array must still be recovered")

        // Negative control: the pre-fix anchor swallows the array.
        XCTAssertTrue(legacySalvageSummaryValue(from: malformed).contains("\"items\""),
                      "control: the literal-separator anchor must leak, or this test proves nothing")
    }

    /// A JSON object with no readable summary at all. Storing it verbatim is
    /// the reported bug, and it is self-perpetuating — a stored blob passes
    /// the "already summarized" gate, so the recording is never retried.
    /// No summary is the honest answer; the origin makes it diagnosable.
    func test_parse_unreadable_json_object_yields_no_summary_rather_than_the_blob() {
        let blob = #"{"resumen": "clave equivocada", "items": []}"#

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: blob)

        XCTAssertEqual(parsed.origin, .unreadableEnvelope)
        XCTAssertTrue(parsed.summary.isEmpty,
                      "an unreadable object must yield no summary; got \(parsed.summary)")
    }

    /// The same malformed envelope, WRAPPED — a label line plus ```json
    /// fences, which is the shape an LLM emits most often. `parseEnvelope`
    /// accepts that wrapper (it plucks the first balanced block out of the
    /// string rather than requiring position 0), but the salvage and
    /// `unreadableEnvelope` branches were gated on `trimmed.hasPrefix("{")`.
    /// So the wrapped form failed the object decode AND the prefix test and
    /// landed in `.plain`, storing the whole fenced blob as the summary — the
    /// reported bug, for the commonest shape.
    func test_parse_salvages_a_malformed_envelope_inside_fences_and_a_label() {
        let fenced = """
        Here is the summary:
        ```json
        {
          "summary": "Team review. Baylis acts as if he is "on another planet".",
          "items": [
            {"id": "a", "text": "Give Baylis direct feedback", "source": "inferred"}
          ]
        }
        ```
        """

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: fenced)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope,
                       "a fenced malformed envelope is still an envelope")
        XCTAssertFalse(parsed.summary.contains("```"),
                       "fence scaffolding must never reach the summary")
        XCTAssertFalse(parsed.summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertFalse(parsed.summary.hasPrefix("Here is the summary:"),
                       "the label must not be stored as the summary")
        XCTAssertTrue(parsed.summary.hasSuffix("\"on another planet\"."),
                      "the salvaged value must be the summary; got \(parsed.summary)")
        XCTAssertEqual(parsed.items.map(\.text), ["Give Baylis direct feedback"],
                       "items recovered by the lenient parse must survive the wrapper")

        // The unfenced label-only variant takes the same branch.
        let labelled = #"""
        Here is the JSON:
        {"summary": "A "quoted" thing.", "items": []}
        """#
        let labelledParse = RecordingSummarizer.parseSummaryAndItems(from: labelled)
        XCTAssertEqual(labelledParse.origin, .salvagedEnvelope)
        XCTAssertEqual(labelledParse.summary, "A \"quoted\" thing.")
    }

    /// The wrapper-stripper must never ABORT the salvage. A malformed
    /// envelope whose summary text mentions ```` ``` ```` — a meeting that
    /// discussed code — has backticks that are content, not a wrapper, and the
    /// first cut of the fence handling let that hijack the parse: it stripped
    /// before the shape test and bailed when the wrapper looked wrong, so this
    /// landed in `.plain` as a raw blob even though the leading `{` alone was
    /// always enough to salvage it. Unwrapping is optimistic; when it cannot
    /// identify a wrapper the original text is judged on its own merits.
    func test_parse_salvages_a_malformed_envelope_whose_summary_mentions_backticks() {
        let malformed = #"{"summary": "The team reviewed the ```retry``` helper and called it "fine".", "items": [{"id": "a", "text": "Ship the retry change", "source": "inferred"}]}"#

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: malformed)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope,
                       "backticks in the summary TEXT must not abort the salvage")
        XCTAssertFalse(parsed.summary.hasPrefix("{"),
                       "a raw JSON blob must never be shown as the summary")
        XCTAssertTrue(parsed.summary.contains("```retry```"),
                      "the backticks are part of the summary; got \(parsed.summary)")
        XCTAssertFalse(parsed.summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertEqual(parsed.items.map(\.text), ["Ship the retry change"])
    }

    /// An UNCLOSED fence must not abort the unwrap: the model simply stopped
    /// early, and a labelled envelope has no leading `{` of its own to fall
    /// back on.
    ///
    /// The payload carries an ODD number of unescaped quotes, which leaves
    /// `findFirstJSONStructure`'s `inString` inverted so the balanced-block
    /// search fails outright — exactly the malformed input this salvage path
    /// exists for. The fence candidate is therefore the ONLY route to the
    /// leading-`{` bypass, which is what makes these assertions discriminating
    /// rather than incidentally true.
    func test_parse_salvages_a_wrapped_envelope_when_the_fence_is_never_closed() {
        let unclosed = #"""
        Here is the summary:
        ```json
        {"summary": "He said "hi" and left, "items": []}
        """#

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: unclosed)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope,
                       "an unclosed fence must still reach the salvage")
        XCTAssertFalse(parsed.summary.hasPrefix("{"),
                       "a raw blob must never be shown as the summary")
        XCTAssertFalse(parsed.summary.contains("```"),
                       "fence scaffolding must not reach the summary")
        XCTAssertTrue(parsed.summary.contains("He said"), "got \(parsed.summary)")
    }

    /// A fenced block with prose AFTER it is quoted material inside a real
    /// summary — a meeting that showed a config — not a wrapper around the
    /// output. Taking the block substitutes the snippet for the summary and
    /// then blanks it (no `"summary"` key → `unreadableEnvelope`), destroying
    /// the prose on both sides. The lead-in here is deliberately SHORT, so the
    /// 80-char label guard cannot be what saves it: the structural check has
    /// to.
    func test_parse_keeps_prose_that_continues_after_a_quoted_fenced_object() {
        let prose = """
        Notes:
        ```json
        {"retries": 3}
        ```
        The team agreed to raise it next sprint after the incident review.
        """

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: prose)

        XCTAssertEqual(parsed.origin, .plain)
        XCTAssertTrue(parsed.summary.contains("next sprint after the incident review"),
                      "the prose after the block must survive; got \(parsed.summary)")
    }

    /// Backticks in the MIDDLE of a line are content, not a fence. Closing the
    /// block at the first inner run truncated the candidate mid-value and
    /// stored a short, plausible-looking WRONG summary ("We fixed the") —
    /// worse than a blob, because nothing about it looks broken, and the retry
    /// gate shuts on it just the same.
    func test_parse_does_not_let_inner_backticks_truncate_a_fenced_salvage() {
        // Unescaped quotes around "done" break the object decode, which is
        // what routes this to the salvage in the first place.
        let fenced = #"""
        Here is the summary:
        ```json
        {"summary": "We fixed the ```retry``` helper and called it "done".", "items": []}
        ```
        """#

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: fenced)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope)
        XCTAssertTrue(parsed.summary.hasSuffix("called it \"done\"."),
                      "the summary must not be clipped at an inner backtick run; got \(parsed.summary)")
        XCTAssertTrue(parsed.summary.contains("```retry```"),
                      "the quoted backticks are part of the summary text")
    }

    /// The counterweight to the test above, and the reason the fix is not
    /// simply "the output contains a `{`". A real summary may quote braces or
    /// a code block; blanking a GOOD summary is a worse outcome than showing
    /// a blob, so an object must be what the output IS — nothing but
    /// whitespace after it, and at most a short label before it.
    func test_parse_keeps_prose_that_merely_quotes_braces_or_a_code_block() {
        let braces = "The team reviewed the config {mode: fast} and shipped it."
        let bracesParse = RecordingSummarizer.parseSummaryAndItems(from: braces)
        XCTAssertEqual(bracesParse.origin, .plain)
        XCTAssertEqual(bracesParse.summary, braces,
                       "prose that mentions a brace block must survive intact")

        let withCode = """
        The team walked through the retry handler at length and agreed the \
        default should change before the next release ships to users.
        ```
        {"retries": 3}
        ```
        """
        let codeParse = RecordingSummarizer.parseSummaryAndItems(from: withCode)
        XCTAssertEqual(codeParse.origin, .plain)
        XCTAssertTrue(codeParse.summary.hasPrefix("The team walked through"),
                      "a prose summary quoting a fenced block must survive intact")
    }

    // MARK: - Dictated action items survive the one-shot pass

    /// For a Live-AI recording, `QuickActionsController` snapshots the live
    /// action items — including ones the user DICTATED ("Mila, action
    /// item: …", `source == .voiceCommand`) — onto the recording at stop and
    /// then immediately calls `regenerate`. The one-shot prompt is never
    /// shown that list and only ever asks for `source: "inferred"`, so a
    /// wholesale replace trades what the user said out loud for the model's
    /// guess at it. Dictated items must survive.
    func test_regenerate_preserves_action_items_the_user_dictated() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            Fresh summary.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "fresh", "text": "Ship the beta", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "Dictated")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Dictated",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "dictated", text: "Call the bank",
                                      speaker: nil, timestampSeconds: 12,
                                      source: .voiceCommand, addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Fresh summary.")
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Call the bank", "Ship the beta"],
                       "a dictated item must not be dropped for the inferred set")
        XCTAssertEqual(items.first?.source, .voiceCommand,
                       "it must stay marked as dictated — the MCP surface reports that field")
    }

    /// The model usually DOES re-derive a dictated task from the transcript,
    /// under an id of its own. Keeping both would show the user the same
    /// task twice, so the fresh copy is dropped and the dictated one — the
    /// authoritative record of an explicit instruction — is kept. Matching
    /// is case- and whitespace-insensitive, which this fixture exercises.
    func test_regenerate_does_not_duplicate_a_dictated_item_the_model_re_derived() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            Fresh summary.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "reinferred", "text": "call the   BANK", "source": "inferred"},
             {"id": "other", "text": "Ship the beta", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "NoDupes")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "NoDupes",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.actionItems = [ActionItem(id: "dictated", text: "Call the bank",
                                      speaker: nil, timestampSeconds: 12,
                                      source: .voiceCommand, addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Call the bank", "Ship the beta"],
                       "the re-derived copy of a dictated item must be folded away")
        XCTAssertEqual(items.first?.source, .voiceCommand)
    }

    /// End-to-end negative control for the malformed-JSON path: output the
    /// summarizer cannot read a summary out of must leave the recording
    /// WITHOUT a summary — never with the raw `{...}` blob, which is what
    /// shipped and what permanently blocked a retry.
    func test_summarize_never_stores_an_unreadable_json_object_as_the_summary() async throws {
        llm.tool = .claude
        let blob = #"{"resumen": "clave equivocada", "items": []}"#
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in blob }

        let audioURL = store.freshAudioURL(suggestedName: "Unreadable")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Unreadable",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "a blob must not be stored — the recording stays eligible for a retry")
        XCTAssertTrue(summarizer.shouldSummarize(updated),
                      "and the retry gate must actually still be open")
    }

    /// The same end-to-end control for the WRAPPED shape. This is the half of
    /// the bug that bites hardest: the stored blob satisfies
    /// `shouldSummarize`'s "already has a summary" gate, so the recording is
    /// never retried and the blob is what the detail view, the Obsidian note
    /// and the MCP surface report forever. Fences are the likeliest wrapper,
    /// so gating the recovery on a leading `{` left the common case broken.
    func test_summarize_never_stores_a_fenced_unreadable_json_object() async throws {
        llm.tool = .claude
        let fenced = """
        Here is the summary:
        ```json
        {"resumen": "clave equivocada", "items": []}
        ```
        """
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in fenced }

        let audioURL = store.freshAudioURL(suggestedName: "FencedUnreadable")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "FencedUnreadable",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "a fenced blob must not be stored; got \(updated.summary ?? "nil")")
        XCTAssertTrue(summarizer.shouldSummarize(updated),
                      "and the retry gate must actually still be open")
    }

    /// End-to-end proof that the CLASS is closed, not one instance of it: an
    /// unreadable object whose text mentions ```` ``` ```` is the shape the
    /// fence-stripper used to abort on, and aborting stored the blob and shut
    /// the retry gate. Whatever the stripper makes of a wrapper, the pipeline
    /// must end up no worse than if it had never tried.
    func test_summarize_never_stores_a_blob_whose_text_mentions_backticks() async throws {
        llm.tool = .claude
        let blob = #"{"resumen": "hablamos del helper ```retry```", "items": []}"#
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in blob }

        let audioURL = store.freshAudioURL(suggestedName: "BacktickBlob")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "BacktickBlob",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "a blob must not be stored; got \(updated.summary ?? "nil")")
        XCTAssertTrue(summarizer.shouldSummarize(updated),
                      "and the retry gate must actually still be open")
    }

    // MARK: - Output language: per-recording override vs. global setting

    /// The resolution order, pinned without a store or a runner: a
    /// recording's own override wins; otherwise the global setting; and the
    /// global `.auto` hands "the same language as the transcript below" to the
    /// model instead of Mila picking one language itself — with Swedish as the
    /// other language there is no script difference left to detect, so a guess
    /// here would have been a silent coin flip.
    func test_prompt_language_resolution_order() {
        var english = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                                fullText: "we discussed the roadmap")
        var swedish = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                                fullText: "vi diskuterade roadmapen")

        // No override: the global decides. Auto is passed through verbatim,
        // for BOTH transcripts — it does not read the text any more.
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: english, global: .auto),
                       "the same language as the transcript below")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: swedish, global: .auto),
                       "the same language as the transcript below")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: swedish, global: .english), "English")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: english, global: .swedish), "Swedish")

        // An override beats every global value, including Auto's phrasing.
        english.summaryLanguage = "sv"
        swedish.summaryLanguage = "en"
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: english, global: .english), "Swedish")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: english, global: .auto), "Swedish")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: swedish, global: .swedish), "English")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: swedish, global: .auto), "English")

        // A `"he"` left on a recording made before Hebrew was dropped is not
        // an override at all (`Recording.summaryLanguageOverride` decodes
        // strictly), so the global setting applies unchanged.
        var legacy = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                               fullText: "דיברנו על מפת הדרכים", summaryLanguage: "he")
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: legacy, global: .swedish), "Swedish")
        legacy.summaryLanguage = "en"
        XCTAssertEqual(RecordingSummarizer.promptLanguageName(for: legacy, global: .swedish), "English")
    }

    /// End-to-end: the override reaches the model. Same transcript, same
    /// global setting, the only difference between the two recordings is the
    /// override — so the two prompts disagreeing is attributable to it alone
    /// (the nil case is the negative control).
    func test_summarize_per_recording_override_wins_over_global() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        // The token is now the ONLY channel for the language — Mila appends no
        // directive of its own — so the test prompt makes the substitution
        // visible without depending on the shipped default's wording.
        liveAI.summaryPrompt = "LANG={{LANGUAGE}}"
        var prompts: [UUID: String] = [:]
        useStubRunner { _, prompt, transcript, _, _, _, _, _, _, _, _ in
            // Key by transcript so the two runs can be told apart.
            prompts[UUID(uuidString: transcript) ?? UUID()] = prompt
            return "ok"
        }

        // Each recording's transcript is its own id, so the stub can file
        // the prompt under the right recording without peeking at state.
        var withOverride = try addRecording(named: "Override", text: "")
        withOverride.fullText = withOverride.id.uuidString
        withOverride.summaryLanguage = "sv"
        store.update(withOverride)
        var without = try addRecording(named: "Default", text: "")
        without.fullText = without.id.uuidString
        store.update(without)

        summarizer.summarizeIfNeeded(withOverride)
        summarizer.summarizeIfNeeded(without)
        await summarizer.awaitInFlight(withOverride.id)
        await summarizer.awaitInFlight(without.id)

        let overridden = try XCTUnwrap(prompts[withOverride.id])
        let defaulted = try XCTUnwrap(prompts[without.id])
        XCTAssertTrue(overridden.contains("LANG=Swedish"),
                      "the override must name Swedish; got \(overridden.prefix(200))")
        XCTAssertFalse(overridden.contains("LANG=English"),
                       "nothing in the prompt may still ask for the global language")
        XCTAssertTrue(defaulted.contains("LANG=English"),
                      "control: without an override the global setting applies")
    }

    /// Today's behaviour, pinned: with no override, a literal global value is
    /// used as-is, and global Auto passes "the same language as the transcript
    /// below" through to the model — for every transcript, Hebrew-script or not.
    func test_summarize_without_override_follows_global_setting() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "LANG={{LANGUAGE}}"
        var lastPrompt = ""
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            lastPrompt = prompt
            return "ok"
        }

        liveAI.outputLanguage = .auto
        let hebrewText = try addRecording(named: "Auto-he", text: "דיברנו על מפת הדרכים והסכמנו")
        summarizer.summarizeIfNeeded(hebrewText)
        await summarizer.awaitInFlight(hebrewText.id)
        XCTAssertTrue(lastPrompt.contains(
                        "LANG=the same language as the transcript below"),
                      "Auto is the model's call now, not Mila's; got \(lastPrompt.prefix(200))")

        let englishText = try addRecording(named: "Auto-en", text: "we discussed the roadmap")
        summarizer.summarizeIfNeeded(englishText)
        await summarizer.awaitInFlight(englishText.id)
        XCTAssertTrue(lastPrompt.contains(
                        "LANG=the same language as the transcript below"),
                      "same phrasing for a Latin-script transcript — the text is not inspected")

        liveAI.outputLanguage = .swedish
        let forcedSwedish = try addRecording(named: "Global-sv", text: "we discussed the roadmap")
        summarizer.summarizeIfNeeded(forcedSwedish)
        await summarizer.awaitInFlight(forcedSwedish.id)
        XCTAssertTrue(lastPrompt.contains("LANG=Swedish"),
                      "a literal global value applies regardless of the transcript's language")
    }

    /// recordings.json is user-editable on disk. A code the app does not know
    /// must fall back to the global setting — NOT to Swedish, which is what
    /// `RecordingLanguage.fromCode` would have done
    /// (`bugbot-rules/untrusted-persisted-data.md`). Includes a `"he"` left by
    /// a build that still offered Hebrew.
    func test_summarize_ignores_an_unknown_persisted_summary_language() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        liveAI.summaryPrompt = "LANG={{LANGUAGE}}"
        var lastPrompt = ""
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            lastPrompt = prompt
            return "ok"
        }

        for retired in ["fr", "he"] {
            var rec = try addRecording(named: "Unknown-\(retired)", text: "we discussed the roadmap")
            rec.summaryLanguage = retired
            store.update(rec)
            XCTAssertNil(rec.summaryLanguageOverride, "`\(retired)` is not an override")

            summarizer.summarizeIfNeeded(rec)
            await summarizer.awaitInFlight(rec.id)
            XCTAssertTrue(lastPrompt.contains("LANG=English"),
                          "unknown code must defer to the global setting; got \(lastPrompt.prefix(200))")
            XCTAssertFalse(lastPrompt.contains("LANG=Swedish"))
        }
    }

    /// The mirror image of what used to be pinned here. The language now reaches
    /// the model ONLY through the `{{LANGUAGE}}` slot, so a prompt with no slot
    /// gets NO language from Mila — not a directive appended behind its back.
    /// That is the deliberate trade-off of making the whole prompt editable: the
    /// setting stops being a override the user cannot see, and the Settings
    /// caption says so.
    func test_a_custom_prompt_without_the_language_token_gets_no_language_from_mila() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        liveAI.summaryPrompt = "Sammanfatta mötet på svenska."
        var lastPrompt = ""
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            lastPrompt = prompt
            return "ok"
        }

        var rec = try addRecording(named: "Custom", text: "we discussed the roadmap")
        rec.summaryLanguage = "sv"
        store.update(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)
        XCTAssertEqual(lastPrompt.prefix("Sammanfatta mötet på svenska.".count),
                       "Sammanfatta mötet på svenska.",
                       "the user's prompt leads the request and nothing is prepended")
        XCTAssertFalse(lastPrompt.contains("English"),
                       "Mila must not state a language anywhere: \(lastPrompt)")
        XCTAssertFalse(lastPrompt.contains("{{LANGUAGE}}"))
    }


    /// Picking a language while a summary is already in flight. The language
    /// was resolved when the run started, so, left alone, the override would
    /// be stored and the OLD-language output written over it. The pick's
    /// `regenerate` hits the in-flight guard and requests a re-run (#318);
    /// the completion must discard its result and run again from the live
    /// row. Deterministic: the stub parks on a gate the test opens only
    /// after setting the override.
    func test_summarize_reruns_when_the_summary_language_changes_mid_flight() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        liveAI.summaryPrompt = "LANG={{LANGUAGE}}"
        let gate = TestGate()
        var prompts: [String] = []
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            prompts.append(prompt)
            if prompts.count == 1 {
                await gate.wait()
                return "FIRST (stale language)"
            }
            return "SECOND"
        }

        let rec = try addRecording(named: "Race", text: "we discussed the roadmap")
        summarizer.summarizeIfNeeded(rec)
        XCTAssertTrue(summarizer.isSummarizing(rec.id))

        // What the menu does: `setSummaryLanguage` writes the override on
        // the live row, then asks for a regenerate — which the dedup guard
        // drops.
        summarizer.setSummaryLanguage(.swedish, for: rec.id)
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summaryLanguage, "sv",
                       "the override is persisted even while the stale run is still out")
        gate.open()
        await summarizer.awaitInFlight(rec.id)

        // The re-run is started from the interrupted run's completion.
        // Wait for the stub to have been CALLED a second time — monotonic —
        // rather than for `isSummarizing`, which may already have flipped
        // back to false if the re-run completed before this continuation
        // resumed; then await it like any other run.
        await waitUntil { prompts.count == 2 }
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(prompts.count, 2, "exactly one re-run")
        XCTAssertTrue(prompts[0].contains("LANG=English"))
        XCTAssertTrue(prompts[1].contains("LANG=Swedish"),
                      "the re-run must use the language the user just picked")
        let final = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(final.summary, "SECOND",
                       "the stale-language output must never be stored")
        XCTAssertEqual(final.summaryLanguage, "sv")
    }

    /// The mid-flight replay must not depend on the interrupted call
    /// succeeding: a pick made while a run is out is a user action, and it
    /// gets its one re-run whether that run stored a summary, parsed nothing
    /// or failed. Before this, only the success path compared the language,
    /// so a timeout at the wrong moment left ✓ Swedish on the menu and an
    /// English summary on the recording with nothing scheduled to fix it.
    /// (The empty-output path goes through the same helper.)
    func test_summarize_reruns_in_the_new_language_when_the_interrupted_call_fails() async throws {
        struct StubFailure: Error {}
        llm.tool = .claude
        liveAI.outputLanguage = .english
        // Pin the prompt so the language the re-run used is observable in the
        // text: the shipped default is Swedish prose with `{{LANGUAGE}}` buried
        // in a sentence, which would make this assertion about prose, not about
        // which language the switch produced.
        liveAI.summaryPrompt = "LANG={{LANGUAGE}}"
        let gate = TestGate()
        var prompts: [String] = []
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            prompts.append(prompt)
            if prompts.count == 1 {
                await gate.wait()
                throw StubFailure()
            }
            return "SECOND"
        }

        let rec = try addRecording(named: "Race", text: "we discussed the roadmap")
        summarizer.summarizeIfNeeded(rec)
        XCTAssertTrue(summarizer.isSummarizing(rec.id))
        summarizer.setSummaryLanguage(.swedish, for: rec.id)
        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await waitUntil { prompts.count == 2 }
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(prompts.count, 2, "exactly one re-run, even though the first call failed")
        XCTAssertTrue(prompts[1].contains("LANG=Swedish"),
                      "the re-run must use the language the user picked")
        let final = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(final.summary, "SECOND")
        XCTAssertEqual(final.summaryLanguage, "sv")
    }

    // MARK: - Regenerate while a run is in flight (#318)

    /// A re-transcription finishing (or "Regenerate summary") while the
    /// previous transcript's summary is still out used to be dropped by the
    /// in-flight dedup guard, so the OLD transcript's summary was stored and
    /// shown as current with nothing left to fix it. The request must cause
    /// exactly one follow-up, and the interrupted call's output must never
    /// be stored — not even briefly before the follow-up replaces it — and
    /// the attempt must be signalled once, by the follow-up.
    func test_regenerate_during_an_in_flight_run_causes_one_follow_up_and_never_stores_the_stale_output() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var transcripts: [String] = []
        var summaryAtFollowUp: String??
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            transcripts.append(transcript)
            if transcripts.count == 1 {
                await gate.wait()
                return "STALE"
            }
            // The only row in the store is the one under test.
            summaryAtFollowUp = .some(self.store.recordings.first?.summary)
            return "FRESH"
        }
        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Retranscribed", text: "old transcript")
        summarizer.summarizeIfNeeded(rec)
        XCTAssertTrue(summarizer.isSummarizing(rec.id))

        // What `TranscriptionService` does on a re-transcription: persist
        // the new transcript, then ask for a fresh summary.
        var updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        updated.fullText = "new transcript"
        store.update(updated)
        summarizer.regenerate(updated)

        gate.open()
        // The follow-up is started synchronously in the interrupted run's
        // completion, so awaiting the run in flight twice — the stale one,
        // then the follow-up — is deterministic, and nothing can be left
        // scheduled once the second returns.
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(transcripts, ["old transcript", "new transcript"],
                       "exactly one follow-up, summarizing the new transcript")
        XCTAssertEqual(summaryAtFollowUp, .some(nil),
                       "the stale output must not be stored while the follow-up runs")
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "FRESH")
        XCTAssertEqual(finished, 1, "the attempt is signalled once, by the follow-up")
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// Several changes during one run — two re-transcriptions and a
    /// language pick, each followed by its request — coalesce into ONE
    /// follow-up: it reads the live row, so a second one would summarize the
    /// same row again and bill for it twice.
    func test_changes_during_one_run_coalesce_into_one_follow_up() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var transcripts: [String] = []
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            transcripts.append(transcript)
            if transcripts.count == 1 { await gate.wait() }
            return "SUMMARY \(transcripts.count)"
        }

        let rec = try addRecording(named: "Coalesce", text: "v1")
        summarizer.regenerate(rec)
        XCTAssertTrue(summarizer.isSummarizing(rec.id))
        for text in ["v2", "v3"] {
            var row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
            row.fullText = text
            store.update(row)
            summarizer.regenerate(row)
        }
        summarizer.setSummaryLanguage(.swedish, for: rec.id)
        summarizer.summarizeIfNeeded(rec)

        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(transcripts, ["v1", "v3"], "one follow-up, from the row as of completion")
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SUMMARY 2")
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// "Regenerate summary" while a run is out on the SAME transcript and
    /// language is served by that run instead of paying for a second
    /// identical call: the run's output is stored with force semantics, so it
    /// replaces a summary another path stored meanwhile.
    func test_regenerate_with_unchanged_inputs_is_folded_into_the_in_flight_run() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return "FROM THE RUN"
        }
        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Fold", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        var row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        row.summary = "stored by another path"
        store.update(row)
        summarizer.regenerate(row)

        gate.open()
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(calls, 1, "no second call for identical inputs")
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "FROM THE RUN",
                       "the folded-in regenerate overwrites, as a regenerate does")
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// The follow-up re-reads the live row when it starts, so it summarizes
    /// the transcript as of COMPLETION — not the one the request carried.
    /// A transcript that changes again between the request and completion,
    /// with no request of its own, is the one summarized.
    func test_follow_up_uses_the_transcript_as_of_completion_not_as_of_the_request() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var transcripts: [String] = []
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            transcripts.append(transcript)
            if transcripts.count == 1 { await gate.wait() }
            return "SUMMARY \(transcripts.count)"
        }

        let rec = try addRecording(named: "Moving", text: "first")
        summarizer.summarizeIfNeeded(rec)
        var atRequest = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        atRequest.fullText = "second"
        store.update(atRequest)
        summarizer.regenerate(atRequest)
        var atCompletion = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        atCompletion.fullText = "third"
        store.update(atCompletion)

        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(transcripts, ["first", "third"])
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SUMMARY 2")
    }

    /// A permanent delete between the request and the run's completion must
    /// not spend an LLM call on a recording that is gone.
    func test_follow_up_is_not_started_for_a_recording_deleted_mid_flight() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var calls = 0
        var returned = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            // The completion runs in the same main-actor job as this return.
            returned = true
            return "SUMMARY"
        }
        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Doomed", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        summarizer.regenerate(rec)
        // The call must be out before the delete. A permanent delete now
        // cancels the run (#334) and drops it from `inFlight` at once, so
        // `awaitInFlight` cannot be what waits for it: wait for the stub's
        // own return instead (the gate ignores the cancel, standing in for
        // a call that comes back anyway).
        await waitUntil { calls == 1 }
        store.permanentlyDelete(rec)
        XCTAssertFalse(summarizer.isSummarizing(rec.id), "the delete cancels the run")

        gate.open()
        await waitUntil { returned }
        await Task.yield()
        await summarizer.awaitInFlight(rec.id)

        XCTAssertTrue(returned)
        XCTAssertEqual(calls, 1, "no follow-up for a deleted recording")
        XCTAssertEqual(finished, 0, "nothing to export for a deleted recording")
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// The #318 case as `onTranscriptionCompleted` actually routes it when
    /// the re-transcribed row had NO summary yet (its first one is the run
    /// in flight): `wasRetranscription` is false, so the new transcript
    /// arrives through `summarizeIfNeeded`, not `regenerate`. The completion
    /// still sees the transcript moved, and the follow-up goes back through
    /// the normal (non-force) gate.
    func test_non_force_request_with_a_new_transcript_during_a_run_causes_a_follow_up() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var transcripts: [String] = []
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            transcripts.append(transcript)
            if transcripts.count == 1 { await gate.wait() }
            return "SUMMARY of \(transcript)"
        }

        let rec = try addRecording(named: "FirstPass", text: "old transcript")
        summarizer.summarizeIfNeeded(rec)
        summarizer.summarizeIfNeeded(rec)  // same transcript: a true duplicate
        var updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        updated.fullText = "new transcript"
        store.update(updated)
        summarizer.summarizeIfNeeded(updated)

        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(transcripts, ["old transcript", "new transcript"])
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary,
                       "SUMMARY of new transcript")
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// A row re-transcribed and then moved to Recently Deleted while its run
    /// was out gets no follow-up call (summarizer spend on trashed rows is
    /// skipped elsewhere too), and the stale output is still discarded.
    func test_follow_up_is_not_started_for_a_recording_trashed_mid_flight() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return "SUMMARY"
        }

        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Trashed", text: "old transcript")
        summarizer.summarizeIfNeeded(rec)
        var row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        row.fullText = "new transcript"
        store.update(row)
        summarizer.summarizeIfNeeded(row)
        store.softDelete(row)

        gate.open()
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(calls, 1, "no follow-up for a trashed recording")
        XCTAssertNil(store.recordings.first { $0.id == rec.id }?.summary,
                     "the stale output must not be stored, or a restore brings it back")
        XCTAssertEqual(finished, 0,
                       "no completion work (an Obsidian export) for a recording the user threw away")
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
    }

    /// A regenerate folded into a run with the same inputs is served by that
    /// run — but if the run then produces nothing (a timeout, an unparseable
    /// reply), the explicit request still gets its own attempt rather than
    /// being dropped.
    func test_folded_regenerate_gets_its_own_attempt_when_the_run_fails() async throws {
        struct StubFailure: Error {}
        llm.tool = .claude
        let gate = TestGate()
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                throw StubFailure()
            }
            return "SECOND"
        }
        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Retry", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        summarizer.regenerate(rec)

        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SECOND")
        XCTAssertEqual(finished, 1)
    }

    /// "Regenerate summary" after editing the summary prompt in Settings,
    /// while a run built from the OLD prompt is out, must not be served by
    /// that run: the row snapshot does not see a global edit, so the request
    /// itself marks the run for a follow-up built from the current settings.
    func test_regenerate_after_a_prompt_change_reruns_with_the_new_prompt() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "OLD PROMPT {{LANGUAGE}}"
        let gate = TestGate()
        var prompts: [String] = []
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            prompts.append(prompt)
            if prompts.count == 1 { await gate.wait() }
            return "SUMMARY \(prompts.count)"
        }

        let rec = try addRecording(named: "Prompt", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        liveAI.summaryPrompt = "NEW PROMPT {{LANGUAGE}}"
        summarizer.regenerate(rec)

        gate.open()
        await summarizer.awaitInFlight(rec.id)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("NEW PROMPT"))
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SUMMARY 2")
    }

    /// Normalising an unrecognised stored language code to Default while a
    /// run is out changes the stored string but not the language in force —
    /// `setSummaryLanguage` deliberately skips the LLM call for it, and the
    /// staleness check must not spend one either.
    func test_normalising_an_unknown_language_code_mid_flight_does_not_rerun() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return "SUMMARY \(calls)"
        }

        let rec = try addRecording(named: "Junk", text: "a transcript")
        _ = store.setSummaryLanguage("fr", recordingID: rec.id)
        summarizer.summarizeIfNeeded(try XCTUnwrap(store.recordings.first { $0.id == rec.id }))
        summarizer.setSummaryLanguage(nil, for: rec.id)
        XCTAssertNil(store.recordings.first { $0.id == rec.id }?.summaryLanguage)

        gate.open()
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SUMMARY 1")
    }

    /// Picking an explicit language that matches what the running call
    /// already resolved to (English while the global setting is English)
    /// changes the stored override but not the prompt, so the run's output
    /// is kept and no second call is made.
    func test_picking_the_language_already_in_force_mid_flight_does_not_rerun() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        let gate = TestGate()
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return "SUMMARY \(calls)"
        }

        let rec = try addRecording(named: "Same", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        summarizer.setSummaryLanguage(.english, for: rec.id)
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summaryLanguage, "en")

        gate.open()
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.recordings.first { $0.id == rec.id }?.summary, "SUMMARY 1")
    }

    /// A run cancelled via `cancel(recordingID:)` stores nothing and signals
    /// nothing when its call returns anyway, so it cannot overwrite what a
    /// newer run for the same id produces.
    func test_a_cancelled_run_stores_nothing_when_its_call_returns() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var returned = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            await gate.wait()
            // The summarizer's completion runs in the same main-actor job as
            // this return, so once the test sees the flag it has finished.
            returned = true
            return "LATE"
        }
        var finished = 0
        summarizer.onSummaryFinished = { _ in finished += 1 }

        let rec = try addRecording(named: "Cancelled", text: "a transcript")
        summarizer.summarizeIfNeeded(rec)
        summarizer.cancel(recordingID: rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))

        gate.open()
        await waitUntil { returned }
        await Task.yield()
        XCTAssertTrue(returned)

        XCTAssertNil(store.recordings.first { $0.id == rec.id }?.summary)
        XCTAssertEqual(finished, 0)
    }

    // MARK: - Deleting a recording mid-summary

    /// A runner stub for the delete tests: the FIRST call parks until it is
    /// cancelled (`Task.sleep` throws `CancellationError` at the cancel,
    /// which is what `LLMRunner.run` turns a cancel into), every later call
    /// returns at once. `started` records each call's transcript, in order.
    private func useParkingRunner(_ started: @escaping @MainActor (String) -> Int) {
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            if started(transcript) == 1 {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                return "LATE"
            }
            return "SUMMARY of \(transcript)"
        }
    }

    /// Two completed recordings, both without a summary, for the cancel tests:
    /// one whose call gets cancelled and one that must survive it. `store.add`
    /// inserts at the front, so the one added LAST is the one the tests start
    /// first.
    private func addQueuedPair() throws -> (running: Recording, queued: Recording) {
        var queued = try addRecording(named: "Queued", text: "queued transcript")
        queued.status = .completed
        store.update(queued)
        var running = try addRecording(named: "Running", text: "running transcript")
        running.status = .completed
        store.update(running)
        return (running, queued)
    }

    /// Permanently deleting a recording whose summary is being generated cancels
    /// that call. Nothing else calls `cancel(recordingID:)`, so without the
    /// store's `permanentlyDeleted` wiring the deleted row's provider call would
    /// run to completion and store its output nowhere — and, worse, a row the
    /// user threw away would keep costing money.
    func test_permanently_deleting_a_recording_mid_summary_cancels_it() async throws {
        llm.tool = .claude
        var started: [String] = []
        useParkingRunner { started.append($0); return started.count }
        var finished: [UUID] = []
        summarizer.onSummaryFinished = { finished.append($0.id) }

        let (running, queued) = try addQueuedPair()
        summarizer.summarizeIfNeeded(running)
        summarizer.summarizeIfNeeded(queued)
        await waitUntil { started.count == 2 }
        // `useParkingRunner` parks only the FIRST call, which is `running`'s —
        // that is the one being cancelled. `queued`'s stub returns at once, so
        // it is deliberately NOT asserted to be in flight here.
        XCTAssertTrue(summarizer.isSummarizing(running.id))

        store.permanentlyDelete(running)
        XCTAssertFalse(summarizer.isSummarizing(running.id),
                       "the delete must cancel the deleted row's summary")

        await summarizer.awaitInFlight(queued.id)
        XCTAssertNil(store.recordings.first { $0.id == running.id },
                     "the deleted row is gone")
        XCTAssertEqual(store.recordings.first { $0.id == queued.id }?.summary,
                       "SUMMARY of queued transcript")
        XCTAssertEqual(finished, [queued.id], "a deleted recording is never signalled")
    }

    /// The same through "Empty Recently Deleted" — and moving a row to the bin
    /// on its own does NOT cancel: that is reversible, and the call is one the
    /// user already asked for, so a restore finds it finished rather than
    /// silently missing.
    func test_emptying_the_trash_cancels_a_trashed_rows_summary_but_trashing_does_not() async throws {
        llm.tool = .claude
        var started: [String] = []
        useParkingRunner { started.append($0); return started.count }

        let (running, queued) = try addQueuedPair()
        summarizer.summarizeIfNeeded(running)
        summarizer.summarizeIfNeeded(queued)
        await waitUntil { started.count == 2 }
        XCTAssertTrue(summarizer.isSummarizing(running.id))

        store.softDelete(running)
        XCTAssertTrue(summarizer.isSummarizing(running.id),
                      "moving to Recently Deleted must not cancel the summary")

        XCTAssertEqual(store.emptyTrash(), 1)
        XCTAssertFalse(summarizer.isSummarizing(running.id))
        await summarizer.awaitInFlight(queued.id)
        XCTAssertEqual(store.recordings.first { $0.id == queued.id }?.summary,
                       "SUMMARY of queued transcript")
    }

    /// A request that arrives AFTER a permanent delete, with the caller's
    /// stale copy, starts no call: the delete's cancel has already fired, so
    /// nothing would ever stop it (e.g. a post-recording step finishing after
    /// a discard, or a regenerate racing the delete).
    func test_a_request_for_a_permanently_deleted_recording_starts_no_call() async throws {
        llm.tool = .claude
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            return "SUMMARY"
        }
        let rec = try addRecording(named: "Gone", text: "a transcript")
        store.permanentlyDelete(rec)

        summarizer.summarizeIfNeeded(rec)
        summarizer.regenerate(rec)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        await summarizer.awaitInFlight(rec.id)
        await Task.yield()
        XCTAssertEqual(calls, 0, "a deleted recording must not cost an LLM call")
    }

    /// A request that is SKIPPED (no call: LLM not configured, empty
    /// transcript) for a recording that was already permanently deleted signals
    /// nothing. The skip paths used to signal
    /// with the caller's stale copy, so the completion hook ran for a row
    /// that no longer exists. A row still in the store keeps its signal.
    func test_a_skipped_request_for_a_deleted_recording_is_not_signalled() async throws {
        llm.tool = .claude
        var calls = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            calls += 1
            return "SUMMARY"
        }
        var finished: [UUID] = []
        summarizer.onSummaryFinished = { finished.append($0.id) }

        let gone = try addRecording(named: "Gone", text: "a transcript")
        let kept = try addRecording(named: "Kept", text: "a transcript")
        store.permanentlyDelete(gone)

        // summarizeIfNeeded's skip: no provider configured.
        llm.tool = .none
        summarizer.summarizeIfNeeded(gone)
        summarizer.summarizeIfNeeded(kept)
        XCTAssertEqual(finished, [kept.id],
                       "summarizeIfNeeded's skip must not signal a deleted recording")

        // regenerate's skip: an empty transcript (regenerate ignores the
        // configured gate only in that case, which is what it checks first).
        finished = []
        llm.tool = .claude
        var emptyGone = gone
        emptyGone.fullText = ""
        summarizer.regenerate(emptyGone)
        XCTAssertEqual(finished, [], "regenerate's empty-transcript skip must not signal a deleted recording")

        await summarizer.awaitInFlight(gone.id)
        XCTAssertEqual(calls, 0)
    }


    /// The other half of #318: when the row's FIRST summary finishes while a
    /// re-transcription is still running, the pass started with no summary,
    /// but completes with one built from the transcript it just replaced.
    /// That must still count as a re-transcription, so the hook regenerates
    /// instead of `summarizeIfNeeded` skipping the row as summarized.
    func test_a_summary_stored_mid_pass_makes_the_completion_a_retranscription() {
        var row = Recording(title: "R", source: .microphone, audioFileName: "r.wav", fullText: "new")
        XCTAssertFalse(TranscriptionService.isRetranscription(hadSummaryBeforeRun: false, persisted: row))
        XCTAssertTrue(TranscriptionService.isRetranscription(hadSummaryBeforeRun: true, persisted: row))
        row.summary = "  "
        XCTAssertFalse(TranscriptionService.isRetranscription(hadSummaryBeforeRun: false, persisted: row))
        row.summary = "summary of the old transcript"
        XCTAssertTrue(TranscriptionService.isRetranscription(hadSummaryBeforeRun: false, persisted: row))
    }

    /// Re-picking the entry that is already ✓'d — Default while no override
    /// is set, or the language already in force — must neither write the row
    /// nor start an LLM call. The menu's job is to CHANGE the language;
    /// "Regenerate summary" is the explicit re-run. Each host used to carry
    /// its own copy of the pick glue and every copy regenerated
    /// unconditionally, so a stray click on the ✓'d entry cost a full
    /// summary call (review of #308).
    func test_set_summary_language_noop_pick_neither_writes_nor_regenerates() async throws {
        llm.tool = .claude
        liveAI.outputLanguage = .english
        var callCount = 0
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            callCount += 1
            return "SUMMARY \(callCount)"
        }
        let rec = try addRecording(named: "Noop", text: "we discussed the roadmap")
        func live() -> Recording? { store.recordings.first { $0.id == rec.id } }

        // Default is already in force: picking Default again does nothing.
        summarizer.setSummaryLanguage(nil, for: rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        XCTAssertEqual(callCount, 0, "a no-op pick must not start an LLM call")
        XCTAssertNil(live()?.summaryLanguage)

        // A real change persists and regenerates exactly once.
        summarizer.setSummaryLanguage(.swedish, for: rec.id)
        XCTAssertEqual(live()?.summaryLanguage, "sv")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(live()?.summary, "SUMMARY 1")

        // Re-picking the language now in force is the no-op again.
        summarizer.setSummaryLanguage(.swedish, for: rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        XCTAssertEqual(callCount, 1, "re-picking the ✓'d language must not regenerate")
        XCTAssertEqual(live()?.summary, "SUMMARY 1")

        // Clearing back to Default IS a change: it regenerates.
        summarizer.setSummaryLanguage(nil, for: rec.id)
        XCTAssertNil(live()?.summaryLanguage)
        await summarizer.awaitInFlight(rec.id)
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(live()?.summary, "SUMMARY 2")

        // An unrecognised persisted code reads as Default (what the ✓ shows),
        // so picking Default cleans the stored value WITHOUT an LLM call —
        // the language in force did not change — while a concrete language
        // is a real change.
        store.setSummaryLanguage("fr", recordingID: rec.id)
        summarizer.setSummaryLanguage(nil, for: rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        XCTAssertEqual(callCount, 2, "Default on an unknown code is still the ✓'d entry")
        XCTAssertNil(live()?.summaryLanguage, "…but the junk value is cleaned out of the row")
        summarizer.setSummaryLanguage(.english, for: rec.id)
        XCTAssertEqual(live()?.summaryLanguage, "en")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertEqual(callCount, 3)

        // An id that is not in the store is ignored outright.
        summarizer.setSummaryLanguage(.swedish, for: UUID())
        XCTAssertEqual(callCount, 3)
    }

    // MARK: - Helpers

    /// Add a completed-looking recording with `text` as its transcript (the
    /// summarizer never reads the audio, but `RecordingStore.add` wants the
    /// file to exist).
    // MARK: - The prompt IS the request: variables, transcript slot, speaker labels

    /// The values Mila substitutes for the fields the user can see in Settings.
    /// Dates are fixed-format in the device's own clock (`en_US_POSIX` shapes,
    /// not locale-following text) because they land in a prompt and in an
    /// Obsidian `[[YYYY-MM-DD]]` link, not on a screen.
    ///
    /// `createdAt` is the moment the row was written — i.e. when capture ENDED —
    /// so `{{TIME}}` is `createdAt - duration` and `{{END_TIME}}` is `createdAt`
    /// itself. Treating `createdAt` as the start made every summary see a
    /// meeting that began when it finished and ended twice its length later.
    func test_promptVariables_format_the_recording_itself() throws {
        var rec = Recording(title: "Stämma", source: .microphone, audioFileName: "s.wav",
                            fullText: "vi diskuterade roadmapen")
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 4
        components.hour = 9; components.minute = 15
        rec.createdAt = try XCTUnwrap(Calendar.current.date(from: components))
        rec.duration = 3_720   // 1 h 2 min
        rec.appName = "Zoom"
        rec.language = "sv"
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "vi", speaker: "SPEAKER_00"),
                        TranscriptSegment(start: 1, end: 2, text: "diskuterade", speaker: "SPEAKER_01")]
        rec.speakerNames = ["SPEAKER_00": "Anna"]

        let values = RecordingSummarizer.promptValues(for: rec,
                                                      languageName: "Swedish",
                                                      transcript: "TRANSCRIPT")
        XCTAssertEqual(values["LANGUAGE"], "Swedish")
        XCTAssertEqual(values["TRANSCRIPT"], "TRANSCRIPT")
        XCTAssertEqual(values["TITLE"], "Stämma")
        XCTAssertEqual(values["DATE"], "2026-03-04")
        XCTAssertEqual(values["TIME"], "08:13",
                       "createdAt is the END, so the start is createdAt - duration")
        XCTAssertEqual(values["END_TIME"], "09:15",
                       "the end is createdAt itself, not createdAt + duration")
        XCTAssertEqual(values["DURATION"], "1 h 2 min")
        XCTAssertEqual(values["SOURCE_APP"], "Zoom")
        XCTAssertEqual(values["SPEAKERS"], "Anna, Talare B")
    }

    /// A recording that ran across midnight is dated by the day it BEGAN — the
    /// day a user looks for it under, and the day a `[[YYYY-MM-DD]]` heading in
    /// their own notes would carry.
    func test_promptVariables_date_follows_the_start_not_the_end() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 5
        components.hour = 0; components.minute = 10
        var rec = Recording(title: "Night shift", source: .microphone, audioFileName: "n.wav",
                            fullText: "handover")
        rec.createdAt = try XCTUnwrap(Calendar.current.date(from: components))
        rec.duration = 2_400   // 40 min, so it started 2026-03-04 23:30

        let values = RecordingSummarizer.promptValues(for: rec,
                                                      languageName: "English",
                                                      transcript: "TRANSCRIPT")
        XCTAssertEqual(values["DATE"], "2026-03-04")
        XCTAssertEqual(values["TIME"], "23:30")
        XCTAssertEqual(values["END_TIME"], "00:10")
        XCTAssertEqual(values["DURATION"], "40 min")
    }

    /// A row whose duration was never filled in (a recovered recording before
    /// transcription) has nothing to subtract: start and end collapse onto
    /// `createdAt`, which is the least wrong answer, not a bogus midnight start.
    func test_promptVariables_zero_duration_collapses_start_onto_createdAt() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 4
        components.hour = 14; components.minute = 30
        var rec = Recording(title: "Recovered", source: .microphone, audioFileName: "r.wav",
                            fullText: "x")
        rec.createdAt = try XCTUnwrap(Calendar.current.date(from: components))
        rec.duration = 0

        let values = RecordingSummarizer.promptValues(for: rec,
                                                      languageName: "English",
                                                      transcript: "TRANSCRIPT")
        XCTAssertEqual(values["DATE"], "2026-03-04")
        XCTAssertEqual(values["TIME"], "14:30")
        XCTAssertEqual(values["END_TIME"], "14:30")
        XCTAssertEqual(values["DURATION"], "0 min")
    }

    func test_durationText_stays_a_number_the_user_can_wrap_in_their_own_words() {
        XCTAssertEqual(RecordingSummarizer.durationText(600), "10 min")
        XCTAssertEqual(RecordingSummarizer.durationText(59), "1 min")
        XCTAssertEqual(RecordingSummarizer.durationText(3_600), "1 h")
        XCTAssertEqual(RecordingSummarizer.durationText(3_720), "1 h 2 min")
        XCTAssertEqual(RecordingSummarizer.durationText(0), "0 min")
    }

    /// What the model is shown for each turn. A name the user assigned wins;
    /// an unnamed voice gets the SAME fallback the transcript view shows
    /// (`Talare B` in Swedish), not the diarizer's raw id — the old `fullText`
    /// gave no labels at all, and plain `TranscriptFormatter.plainText` would
    /// have handed the model `SPEAKER_00` to echo back.
    func test_model_sees_speaker_names_and_not_speaker_ids() {
        var rec = Recording(title: "Möte", source: .microphone, audioFileName: "m.wav",
                            fullText: "Hej allihopa Hej Vidare")
        rec.language = "sv"
        rec.segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hej allihopa", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 1, end: 2, text: "Hej", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 2, end: 3, text: "Vidare", speaker: "SPEAKER_00"),
        ]
        rec.speakerNames = ["SPEAKER_00": "Anna"]

        XCTAssertEqual(RecordingSummarizer.transcriptForLLM(for: rec),
                       "Anna: Hej allihopa\nTalare B: Hej\nAnna: Vidare")
    }

    /// An English recording gets "Speaker A" — the label follows the recording's
    /// transcription language, exactly as in the UI, because that is the
    /// language the model is being asked to work in.
    func test_unnamed_speaker_label_follows_the_recordings_language() {
        var rec = Recording(title: "Meeting", source: .microphone, audioFileName: "m.wav",
                            fullText: "hello there")
        rec.language = "en"
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "hello", speaker: "SPEAKER_00"),
                        TranscriptSegment(start: 1, end: 2, text: "there", speaker: "SPEAKER_01")]
        XCTAssertEqual(RecordingSummarizer.transcriptForLLM(for: rec),
                       "Speaker A: hello\nSpeaker B: there")
    }

    /// Diarization off: no segment carries a speaker, so there is nobody to
    /// label and the plain joined text is the transcript — same as before.
    func test_transcript_without_speakers_falls_back_to_the_plain_text() {
        let rec = Recording(title: "Memo", source: .voiceMemo, audioFileName: "v.m4a",
                            fullText: "handlade bara om en grej")
        XCTAssertEqual(RecordingSummarizer.transcriptForLLM(for: rec),
                       "handlade bara om en grej")
    }

    /// `{{SPEAKERS}}` is the attendance-shaped variable: every voice that
    /// produced audio, in the order they first speak, with the labels the
    /// transcript lines already carry. `{{CALENDAR_ATTENDEES}}` cannot answer
    /// who was IN the room — it is the event's invite list, response status
    /// unread — so a prompt that wants presence needs this one instead.
    func test_speakers_lists_every_voice_in_first_speech_order() {
        var rec = Recording(title: "Möte", source: .meeting, audioFileName: "m.wav",
                            fullText: "a b c d")
        rec.language = "sv"
        rec.speakerNames = ["SPEAKER_00": "Anna"]
        rec.segments = [
            TranscriptSegment(start: 0, end: 1, text: "a", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 1, end: 2, text: "b", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 2, end: 3, text: "c", speaker: "SPEAKER_01"),
            TranscriptSegment(start: 3, end: 4, text: "d", speaker: "SPEAKER_02"),
        ]

        XCTAssertEqual(RecordingSummarizer.speakerList(for: rec), "Talare B, Anna, Talare C")
    }

    /// A name Mila knows for a voice that never speaks in THIS recording is not
    /// evidence that person was there — the list is built from the segments, not
    /// from `speakerNames`.
    func test_speakers_omits_named_voices_that_never_spoke() {
        var rec = Recording(title: "Möte", source: .meeting, audioFileName: "m.wav",
                            fullText: "hej då")
        rec.language = "en"
        rec.speakerNames = ["SPEAKER_00": "Anna", "SPEAKER_09": "Elsa"]
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "hej", speaker: "SPEAKER_00"),
                        TranscriptSegment(start: 1, end: 2, text: "då", speaker: "SPEAKER_00")]

        XCTAssertEqual(RecordingSummarizer.speakerList(for: rec), "Anna")
    }

    /// An unaccepted suggestion is a guess. It lives in
    /// `speakerNameSuggestions`, which `displaySpeakerName` never reads, so it
    /// cannot dress itself up as an attendee — only names the user accepted (or
    /// typed, or that a voice profile confirmed) reach the list.
    func test_speakers_omits_unaccepted_name_suggestions() {
        var rec = Recording(title: "Möte", source: .meeting, audioFileName: "m.wav",
                            fullText: "jag heter anna")
        rec.language = "sv"
        rec.speakerNameSuggestions = [SpeakerNameSuggestion(speaker: "SPEAKER_00", name: "Anna",
                                                            evidence: "jag heter anna",
                                                            origin: .transcript)]
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "jag heter anna",
                                          speaker: "SPEAKER_00")]

        XCTAssertEqual(RecordingSummarizer.speakerList(for: rec), "Talare A",
                      "a suggestion the user has not acted on is not a name")
    }

    /// Two diarizer ids can carry one name — a rename that gave both halves the
    /// same name, or a split that left one unnamed while the other took a name
    /// it shares. A reader counts people, so the name appears once.
    func test_speakers_lists_a_shared_name_once() {
        var rec = Recording(title: "Möte", source: .meeting, audioFileName: "m.wav",
                            fullText: "a b")
        rec.language = "sv"
        rec.speakerNames = ["SPEAKER_00": "Anna", "SPEAKER_01": "Anna"]
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "a", speaker: "SPEAKER_00"),
                        TranscriptSegment(start: 1, end: 2, text: "b", speaker: "SPEAKER_01")]

        XCTAssertEqual(RecordingSummarizer.speakerList(for: rec), "Anna")
    }

    /// Diarization off: no voice can be told apart, so the value is empty —
    /// never "unknown", which a model would happily restate as a fact.
    func test_speakers_is_empty_when_diarization_was_off() {
        let rec = Recording(title: "Memo", source: .voiceMemo, audioFileName: "v.m4a",
                            fullText: "handlade bara om en grej")
        XCTAssertEqual(RecordingSummarizer.speakerList(for: rec), "")
    }

    /// `{{TRANSCRIPT}}` in the prompt: the transcript goes where the user put
    /// it, and Mila appends nothing — paying for the transcript twice in every
    /// summary call would be a quiet 2× cost on long meetings.
    func test_transcript_token_places_the_transcript_and_mila_appends_nothing() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "SAMMANFATTA: {{TRANSCRIPT}}"
        var seenPrompt = ""
        var seenTranscript: String?
        useStubRunner { _, prompt, transcript, _, _, _, _, _, _, _, _ in
            seenPrompt = prompt
            seenTranscript = transcript
            return "ok"
        }

        let rec = try addRecording(named: "Token", text: "vi diskuterade roadmapen")
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertTrue(seenPrompt.contains("SAMMANFATTA: vi diskuterade roadmapen"),
                      "the transcript lands in the user's own slot; got \(seenPrompt)")
        XCTAssertEqual(seenTranscript ?? "<nil>", "",
                       "nothing appended — the prompt already carries the transcript")
        XCTAssertFalse(seenPrompt.contains("Transcript:"))
    }

    /// The back-compat half: a prompt with no slot keeps today's envelope, so a
    /// user who never heard of the variable loses nothing.
    func test_prompt_without_the_token_still_gets_the_transcript_appended() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "Sammanfatta mötet."
        var seenTranscript = ""
        useStubRunner { _, _, transcript, _, _, _, _, _, _, _, _ in
            seenTranscript = transcript
            return "ok"
        }

        let rec = try addRecording(named: "NoToken", text: "vi diskuterade roadmapen")
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(seenTranscript, "vi diskuterade roadmapen")
    }

    /// Nothing of Mila's own is stitched onto the request any more: no
    /// action-items contract, no language directive, no calendar block. Every
    /// one of them was English text a Swedish user could not edit, translate
    /// or remove, appended below a prompt they had written themselves.
    func test_the_summarizer_adds_no_text_of_its_own_to_the_prompt() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "Sammanfatta mötet."
        var seenPrompt = ""
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            seenPrompt = prompt
            return "ok"
        }

        let rec = try addRecording(named: "Clean", text: "vi diskuterade roadmapen")
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(seenPrompt, "Sammanfatta mötet.",
                       "the prompt the model sees is the prompt the user wrote")
        for phrase in ["After the summary, list the action items",
                       RecordingSummarizer.actionItemsSentinel,
                       "Write the summary and every action item",
                       "BACKGROUND"] {
            XCTAssertFalse(seenPrompt.contains(phrase), "\(phrase) must not be injected")
        }
    }

    /// A token Mila does not offer is left exactly as typed. Deleting it would
    /// silently rewrite the user's prompt; a literal `{{MEETING_NAME}}` in the
    /// output is visible in the one place they can act on it.
    func test_an_unknown_token_is_left_verbatim() async throws {
        llm.tool = .claude
        liveAI.summaryPrompt = "Rubrik: {{MEETING_NAME}} — {{LANGUAGE}}"
        var seenPrompt = ""
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            seenPrompt = prompt
            return "ok"
        }

        let rec = try addRecording(named: "Unknown", text: "vi diskuterade roadmapen")
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertTrue(seenPrompt.contains("{{MEETING_NAME}}"), "unknown token survives verbatim")
        XCTAssertFalse(seenPrompt.contains("{{LANGUAGE}}"), "known tokens are substituted")
    }

    /// Naming a voice while a summary call is out changes the transcript the
    /// call was built from, so its output is stale in a new way: it cannot say
    /// who said anything. The completion compares the RENDERED transcript, so
    /// the rename gets its re-run (the pre-render comparison of `fullText` was
    /// blind to it).
    func test_naming_a_speaker_mid_flight_discards_the_unlabelled_output() async throws {
        llm.tool = .claude
        let gate = TestGate()
        var prompts: [String] = []
        useStubRunner { _, prompt, _, _, _, _, _, _, _, _, _ in
            prompts.append(prompt)
            if prompts.count == 1 {
                await gate.wait()
                return "FIRST (no names)"
            }
            return "SECOND"
        }

        var rec = try addRecording(named: "Rename race", text: "Hej allihopa Hej")
        // The unnamed label follows the recording's language (`SpeakerLabel`:
        // "Speaker A" in English, "Talare A" in Swedish). Pin English so the two
        // assertions below are about the RENAME race, not about which language
        // the transcript renders in — that part has its own test
        // (`test_unnamed_speaker_label_follows_the_recordings_language`).
        rec.language = "en"
        rec.segments = [TranscriptSegment(start: 0, end: 1, text: "Hej allihopa", speaker: "SPEAKER_00"),
                        TranscriptSegment(start: 1, end: 2, text: "Hej", speaker: "SPEAKER_01")]
        store.update(rec)

        summarizer.summarizeIfNeeded(rec)
        XCTAssertTrue(summarizer.isSummarizing(rec.id))

        var renamed = rec
        renamed.speakerNames = ["SPEAKER_00": "Anna"]
        store.update(renamed)
        gate.open()
        await waitUntil { prompts.count == 2 }
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(prompts.count, 2, "the rename re-runs the summary")
        XCTAssertTrue(prompts[0].contains("Speaker A:"), "the first run had no assigned names")
        XCTAssertTrue(prompts[1].contains("Anna:"), "the re-run shows the name the user just gave")
        let final = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(final.summary, "SECOND")
    }

    private func addRecording(named name: String, text: String) throws -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: name)
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(title: name, source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: text)
        store.add(rec)
        return rec
    }

    /// Spin the main actor until `condition` holds, bounded so a regression
    /// fails the assertion that follows instead of hanging the suite.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// The pre-fix salvage end-anchor, kept ONLY as a negative control for
    /// `test_parse_salvages_pretty_printed_malformed_envelope_without_leaking_scaffolding`.
    /// It matched the separator between the summary value and the `"items"`
    /// key literally, so any other spelling of it fell through to
    /// `lastIndex(of:)`. Do not use for anything else.
    private func legacySalvageSummaryValue(from json: String) -> String {
        guard let keyRange = json.range(of: "\"summary\"") else { return "" }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return "" }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return "" }
        let rest = afterColon[afterColon.index(after: openQuote)...]
        let endIdx: Substring.Index
        if let itemsAnchor = rest.range(of: "\", \"items\"")
            ?? rest.range(of: "\",\"items\"") {
            endIdx = itemsAnchor.lowerBound
        } else if let lastQuote = rest.lastIndex(of: "\"") {
            endIdx = lastQuote
        } else {
            endIdx = rest.endIndex
        }
        return String(rest[..<endIdx])
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuild `summarizer` with a deterministic `runLLM` stub so the
    /// end-to-end tests don't depend on a real subprocess. Call after
    /// configuring `llm` / `liveAI` for the test.
    private func useStubRunner(_ run: @escaping RecordingSummarizer.RunLLM) {
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI,
                                         runLLM: run)
    }
}

/// A one-shot async gate for deterministically ordering a stubbed runner
/// against the test body — the stub awaits `wait()`, the test calls `open()`
/// once it has set up the mid-flight condition. Replaces `sleep`-based
/// ordering, which slipped under CI contention. Main-actor isolated because
/// the summarizer and tests both run on the main actor.
@MainActor
final class TestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}
