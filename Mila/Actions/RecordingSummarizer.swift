import Foundation
import Combine
import OSLog
import MilaKit

private let summarizerLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                   category: "RecordingSummarizer")

/// Fires a one-shot LLM call against a finished recording's transcript and
/// stores the result on the `Recording.summary` field.
///
/// Two entry points, both explicit user actions (issue #3934):
///   * `summarizeIfNeeded(_:)` — "Summarize" in the detail-view header and in
///     the recording's right-click menu. Skips work when a summary is already
///     there, so the button can be pressed twice without billing twice.
///   * `regenerate(_:)` — "Regenerate summary" on a row that already has one
///     (including a stale-flagged one after a re-transcription). Bypasses the
///     "already has summary" gate so the old summary is replaced.
///
/// There is deliberately NO automatic path here any more. There were three: a
/// launch sweep, a sweep whenever the LLM got configured, and one call per
/// finished recording — that last one fired TWICE per meeting, once when the
/// transcript landed and again seconds later when speaker identification did,
/// so a meeting cost two provider calls and the first output was thrown away.
/// Nothing in this type may spawn a call on its own. The single automatic
/// exception lives in `QuickActionsController.stopRecording`, which regenerates
/// once for a Live AI recording to finish the rolling summary that feature had
/// already been paying for during the meeting.
///
/// Uses the same `LLMRunner` + sandboxing the rename sheet's "Send to
/// Claude" path uses, so any `$PATH` / TCC-popup mitigations carry over
/// for free.
@MainActor
final class RecordingSummarizer: ObservableObject {
    private let store: RecordingStore
    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings

    /// The LLM invocation, behind a seam so tests don't have to spawn a
    /// real subprocess. Production wires this to `LLMRunner.run`, which
    /// shells out to the configured `claude` / `cursor-agent` CLI. Tests
    /// inject a closure that returns canned output synchronously, so the
    /// summarizer's store-write logic is exercised without depending on
    /// process spawn / exec / pipe-drain timing — the source of the
    /// residual CI flake (the assertion lands deterministically because no
    /// child process is involved). The closure receives the same arguments
    /// the summarizer would have forwarded to the CLI, so a test can still
    /// assert on the wire shape (e.g. the one-shot `-p` prompt built by
    /// `LLMTool.arguments`) by inspecting them directly instead of
    /// capturing a shell script's argv.
    ///
    /// `@MainActor` so a test stub can read/write main-actor-isolated test
    /// fixtures (e.g. capture the argv it was handed) without Sendable
    /// gymnastics — the whole summarizer already runs on the main actor.
    typealias RunLLM = @MainActor (
        _ tool: LLMTool,
        _ prompt: String,
        _ transcript: String,
        _ executablePathOverride: String?,
        _ model: String?,
        _ extraArgs: [String],
        _ timeout: TimeInterval,
        _ openAIBaseURL: String?,
        _ openAIAPIKey: String?,
        _ jsonMode: Bool,
        _ transport: OpenAITransport?
    ) async throws -> String

    private let runLLM: RunLLM

    /// Background work tracked per-recording so a second `summarizeIfNeeded`
    /// call for the same id (e.g. a re-transcribe trigger) doesn't spawn
    /// two overlapping CLI invocations.
    ///
    /// Published as a set so detail views can show a "Summarizing…"
    /// spinner on the summary section while a call is in flight — used by both
    /// the "Summarize" button and "Regenerate summary".
    @Published private(set) var inFlightIDs: Set<UUID> = []
    private var inFlight: [UUID: InFlightRun] = [:]

    /// One in-flight summary call, with the snapshot it was built from.
    ///
    /// The snapshot is how a completion tells whether its output is still a
    /// summary of the recording (#318). A re-transcription persisting a new
    /// transcript, a summary-language pick, a `.milashare` re-import — any of
    /// them can change the row while the call is out, and requests that
    /// arrive meanwhile hit the dedup guard. So the completion compares the
    /// LIVE row's `fullText` and summary-language override against the
    /// snapshot (`completion(of:token:produced:)`): if either moved, the
    /// output is discarded and one follow-up runs from the live row. That
    /// replaces #313's language-only `replayIfSummaryLanguageChanged` rather
    /// than adding a second mechanism next to it.
    private struct InFlightRun {
        /// Identifies THIS run, so a completion only acts on its own state:
        /// after `cancel(recordingID:)` a newer run for the same id can start
        /// while the cancelled task is still unwinding.
        let token: UUID
        let task: Task<Void, Never>
        let inputs: SummaryInputs
        /// The global output language the run resolved against. The
        /// completion re-resolves the LIVE row's prompt language against
        /// this same global value: what matters is the language the prompt
        /// asks for, not the stored override — so picking English when Auto
        /// already resolved to English, or normalising an unrecognised stored
        /// code to Default, costs no call. A GLOBAL flip mid-flight with no
        /// request keeps the result, as it always has.
        let globalLanguage: LiveAISettings.OutputLanguage
        /// Starts as the run's own `force`; any `regenerate` that hits the
        /// dedup guard sets it, so the output is stored with force semantics
        /// (overwriting a summary another path stored meanwhile) and a
        /// follow-up goes through `regenerate` too.
        var force: Bool
        /// A `regenerate` arrived with exactly this run's inputs. It is
        /// served by this run rather than by a second identical call — unless
        /// the run produces no summary, in which case the request still gets
        /// its own attempt.
        var regenerateFolded = false
        /// A `regenerate` arrived whose inputs differ from this run's in a
        /// way the row snapshot does not see (the summary prompt, global
        /// output language, tool or model changed in Settings). Its output is
        /// discarded for a follow-up built from the current settings.
        var regenerateWithNewInputs = false
    }

    /// Everything a summary call is built from that could change between
    /// two requests. The API key is left out: it changes whether a call
    /// works, not what it produces.
    private struct SummaryInputs: Equatable {
        let tool: LLMTool
        let executableOverride: String?
        let model: String
        let extraArgs: [String]
        let promptLanguageName: String
        let prompt: String
        /// The transcript rendered for the model (speaker labels included).
        /// Always the snapshot, whatever `transcriptInline` says — the
        /// staleness check in `completion(of:token:produced:)` compares it
        /// against the live row, so it has to describe what the run was built
        /// from even when the prompt carried the text itself.
        let transcript: String
        /// Whether the transcript goes to `LLMRunner` as its own appended
        /// block. `false` when the user's prompt placed `{{TRANSCRIPT}}`
        /// somewhere in its own text — the prompt already holds it, and
        /// appending a second copy would pay for the transcript twice.
        let transcriptInline: Bool
        let openAIBaseURL: String
    }

    /// How a completed call is handled — see `completion(of:token:produced:)`.
    private enum Completion {
        /// This run no longer owns the id (cancelled): store nothing, signal
        /// nothing.
        case abandoned
        /// Discard the output; the task's `defer` starts one follow-up from
        /// the live row, whose own completion signals.
        case rerun
        /// Carry on as normal with this run's state.
        case proceed(InFlightRun)
    }

    /// Fired once per summarize attempt, after the recording's summary state
    /// is final — i.e. after a summary was generated, or synchronously when
    /// generation was skipped (disabled / not configured / already summarized
    /// / empty transcript), or when it failed. Passes the latest recording.
    ///
    /// The Obsidian exporter uses this to write a note only once the summary +
    /// action items are ready, falling back to the transcript when no summary
    /// was produced. It is NOT fired for the dedup early-return (a duplicate
    /// call while one is already in flight — the in-flight task fires instead)
    /// or when the recording is no longer in the store (whether it was
    /// deleted mid-flight or before a skipped request arrived), or was moved
    /// to Recently Deleted while a stale run was out (nothing to export;
    /// this covers the failure and empty-output paths too, not just success —
    /// a permanent delete calls `cancel(recordingID:)` through
    /// `RecordingStore.permanentlyDeleted`, and the cancelled call surfaces
    /// here as a thrown `LLMRunnerError.cancelled` / `CancellationError`).
    ///
    /// Exactly one of the branches below fires it per attempt — or hands the
    /// attempt off to a re-run (`Completion.rerun`), whose own
    /// completion fires instead — and each one returns immediately
    /// afterwards, so a single `runSummary` can never fire twice. Anything
    /// the observer does is its own problem: this is a plain
    /// synchronous call on the main actor, so an observer that throws is a
    /// programmer error, but an observer that *fails internally* (e.g. a file
    /// write that can't complete) cannot stall or corrupt summarisation —
    /// nothing downstream of the call site depends on it.
    var onSummaryFinished: ((Recording) -> Void)?

    /// Runs `cancel(recordingID:)` has removed from `inFlight` whose tasks
    /// have not unwound yet, keyed by run token. Their child is still being
    /// killed (SIGTERM, grace, SIGKILL, bounded reap), so the entry is kept
    /// until the task has actually unwound and `awaitInFlight` waits on it:
    /// a test asserting "a permanent delete stored nothing" must not pass
    /// vacuously while the cancelled call is still alive.
    private var cancelledRuns: [UUID: (recordingID: UUID, task: Task<Void, Never>)] = [:]

    /// Subscribers held for the lifetime of the summarizer. Only the store's
    /// permanent-delete signal today — the `LLMSettings.$tool` observer existed
    /// to re-run the launch/backfill sweep when the user configured a provider,
    /// and that sweep is gone (#3934).
    private var cancellables: Set<AnyCancellable> = []

    /// Timeout for the one-shot summary call. Reads from `LLMSettings.cliTimeout`
    /// so it follows the user's preference set in Settings → AI Provider.
    var timeoutSeconds: TimeInterval { llmSettings.cliTimeout }

    /// `runLLM` defaults to the real CLI invocation (`LLMRunner.run`).
    /// Tests pass a deterministic stub to remove the subprocess-timing
    /// dependency. The default forwards exactly the arguments
    /// `runSummary` collects so production behaviour is unchanged.
    init(store: RecordingStore,
         llmSettings: LLMSettings,
         liveAISettings: LiveAISettings,
         runLLM: @escaping RunLLM = { tool, prompt, transcript, executableOverride, model, extraArgs, timeout, openAIBaseURL, openAIAPIKey, jsonMode, transport in
             try await LLMRunner.run(
                 tool: tool,
                 prompt: prompt,
                 transcript: transcript,
                 executablePathOverride: executableOverride,
                 model: model,
                 extraArgs: extraArgs,
                 timeout: timeout,
                 openAIBaseURL: openAIBaseURL,
                 openAIAPIKey: openAIAPIKey,
                 jsonMode: jsonMode,
                 transport: transport,
                 // The summarizer has exactly one purpose, so the label is
                 // fixed here rather than threaded through the `RunLLM` seam.
                 feature: .summary
             )
         }) {
        self.store = store
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings
        self.runLLM = runLLM

        // Permanent delete (single row, or emptying Recently Deleted) cancels
        // that row's summary call. Wired here rather than at each delete call
        // site so no path can forget it: every permanent removal goes through
        // `RecordingStore.permanentlyDelete` / `emptyTrash`, and both emit.
        // Synchronous on the main actor, like the store mutation itself, so
        // the cancel happens in the same turn as the delete.
        store.permanentlyDeleted
            .sink { [weak self] ids in
                guard let self else { return }
                for id in ids { self.cancel(recordingID: id) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Predicates

    /// Returns true iff `recording` needs (and can get) a one-shot summary
    /// under the normal (non-force) gate: a provider is configured, the
    /// transcript is not empty, and no summary exists yet. There is no
    /// `summaryEnabled` master switch any more (#3934) — nothing runs by
    /// itself, so "did the user want this?" is answered by the button they
    /// pressed and this gate only asks "can it succeed, and would it overwrite
    /// something?".
    /// Public so callers + tests can ask the same question we ask
    /// internally without re-deriving the predicate.
    func shouldSummarize(_ recording: Recording) -> Bool {
        guard llmSettings.isConfigured else { return false }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty { return false }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return false }
        return true
    }

    /// True while a summary CLI call is in flight for `recordingID`.
    /// Used by the detail view to show a "Summarizing…" spinner on the
    /// summary section.
    func isSummarizing(_ recordingID: UUID) -> Bool {
        inFlightIDs.contains(recordingID)
    }

    /// Await the in-flight summary task for `recordingID`, if one is running.
    /// Returns immediately when nothing is in flight (already finished, or
    /// never started). Test seam: lets tests wait on the REAL completion
    /// signal — the underlying `Task` finishing — instead of polling the
    /// store on a timer. Polling is inherently racy under CI contention (the
    /// subprocess spawn + pipe drain can slip past a fixed window); awaiting
    /// the task itself is deterministic. The task clears its own `inFlight`
    /// entry in a `defer`, so by the time this returns the store write (if any)
    /// has already happened — including a follow-up's: a stale run starts its
    /// follow-up from that same `defer`, so this keeps awaiting until no run
    /// is left for the id.
    ///
    /// A run `cancel(recordingID:)` took out of `inFlight` is awaited too,
    /// until its task has unwound — otherwise a permanent delete would make
    /// this return before the cancelled call had even started, and a test
    /// asserting "nothing was stored / exported" would pass vacuously.
    func awaitInFlight(_ recordingID: UUID) async {
        while true {
            if let run = inFlight[recordingID] {
                await run.task.value
            } else if let cancelled = cancelledRuns.values.first(where: { $0.recordingID == recordingID }) {
                await cancelled.task.value
            } else {
                return
            }
        }
    }

    // MARK: - Public API

    /// Kick off a background summary for `recording` if the gate above
    /// allows. Returns immediately — the caller doesn't await the LLM.
    /// Idempotent: a second call while one is in flight is a no-op so a
    /// re-enqueue from the transcription path can't double-bill. If the
    /// transcript changed meanwhile, the in-flight run's completion notices
    /// and re-runs (`InFlightRun`).
    func summarizeIfNeeded(_ recording: Recording) {
        // Gate on the same live row `runSummary` builds from, not on
        // whatever copy the caller holds.
        let recording = latestRecording(recording.id, fallback: recording)
        guard shouldSummarize(recording) else {
            logSkip(recording, force: false)
            // No summary will be generated — signal completion now so a
            // pending Obsidian export falls back to the transcript.
            signalSkipped(recording.id)
            return
        }
        runSummary(for: recording, force: false)
    }

    /// Force-regenerate a summary for `recording`, bypassing the
    /// "already has a summary" gate. Used by:
    ///   * `TranscriptionService`'s onTranscriptionCompleted callback
    ///     when the completed recording was a re-transcription (the old
    ///     summary refers to the now-replaced transcript).
    ///   * The "Regenerate summary" context-menu action.
    ///
    /// Still respects the two hard requirements: LLM must be configured,
    /// transcript must be non-empty. Returns immediately. A call while this
    /// recording's run is in flight is not dropped: that run's output is
    /// stored with force semantics, and if the transcript or language moved
    /// meanwhile it is discarded for a follow-up regenerate from the live row
    /// (`InFlightRun`).
    func regenerate(_ recording: Recording) {
        // Gate on the same live row `runSummary` builds from, not on
        // whatever copy the caller holds.
        let recording = latestRecording(recording.id, fallback: recording)
        guard llmSettings.isConfigured else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — LLM not configured")
            signalSkipped(recording.id)
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — transcript empty")
            signalSkipped(recording.id)
            return
        }
        runSummary(for: recording, force: true)
    }

    /// The "Summary language" menu's one entry point (`SummaryLanguageMenu`,
    /// via every host's `onPick`): persist `language` as the per-recording
    /// override on the LIVE row and regenerate from that row — never from
    /// the `Recording` the menu captured, which can be a stale snapshot (see
    /// `RecordingStore.setSummaryLanguage`).
    ///
    /// A pick that matches what is already in force is a no-op: nothing is
    /// written and no LLM call starts. The menu shows a ✓ on that entry, so
    /// re-picking it reads as "leave it", and the explicit re-run is
    /// "Regenerate summary", one entry up. Before this lived here each of
    /// the three hosts had its own copy of the glue, and every copy
    /// regenerated unconditionally (review of #308).
    ///
    /// Two comparisons, because the stored string and the language in force
    /// can disagree: an unrecognised persisted code (`"fr"`, hand-edited or
    /// from a newer app) resolves to Default through
    /// `summaryLanguageOverride`, which is what the ✓ reflects. The RAW
    /// value decides whether to write — so picking Default on such a row
    /// cleans the junk out of recordings.json instead of leaving it there
    /// forever — and the TYPED override decides whether to regenerate, so
    /// that clean-up does not cost an LLM call for a summary that would come
    /// back in the same language.
    func setSummaryLanguage(_ language: RecordingLanguage?, for recordingID: UUID) {
        guard let live = liveRecording(recordingID) else { return }
        let code = language?.rawValue
        guard live.summaryLanguage != code else {
            summarizerLog.log("summary language \(self.shortID(recordingID), privacy: .public): unchanged — nothing to do")
            return
        }
        guard let updated = store.setSummaryLanguage(code, recordingID: recordingID) else { return }
        guard live.summaryLanguageOverride != language else {
            summarizerLog.log("summary language \(self.shortID(recordingID), privacy: .public): normalised an unrecognised code — language in force unchanged, not regenerating")
            return
        }
        regenerate(updated)
    }

    /// Cancel any summary call in flight for `recordingID`. Called for every
    /// permanent delete via `RecordingStore.permanentlyDeleted` (see `init`), so
    /// a deleted recording does not spend a provider call on output that has
    /// nowhere to go.
    ///
    /// Cancelling the task is what stops the child: `LLMRunner.run` bridges task
    /// cancellation to SIGTERM, escalating to SIGKILL after a short grace, with
    /// every wait bounded. The run is parked in `cancelledRuns` until its task
    /// unwinds, so `awaitInFlight` keeps waiting through the kill instead of
    /// reporting "nothing was stored" while the call is still alive.
    ///
    /// NOT called when a recording is moved to Recently Deleted. That is
    /// reversible, and a call now costs nothing the user did not already pay
    /// for — every summary is one they asked for. Emptying the bin cancels
    /// whatever is still running.
    func cancel(recordingID: UUID) {
        if let run = inFlight.removeValue(forKey: recordingID) {
            run.task.cancel()
            inFlightIDs.remove(recordingID)
            // Still holds its slot until its task unwinds (see
            // `cancelledRuns`); the task's `defer` gives it back.
            cancelledRuns[run.token] = (recordingID, run.task)
        }
    }

    // MARK: - Internals

    /// Common path used by `summarizeIfNeeded` and `regenerate`.
    /// `force` controls whether an already-present summary is overwritten
    /// when the CLI returns.
    private func runSummary(for recording: Recording, force: Bool) {
        // Built from the LIVE row when there is one: callers hand over
        // whatever copy they hold, and the completion compares against the
        // live row, so a copy that differs from the store would make every
        // run look stale from the start.
        //
        // A row that is no longer in the store gets no call at all. A
        // request can arrive after a permanent delete with the caller's
        // stale copy (a post-recording step still finishing after a
        // discard, a regenerate racing the delete), and the delete's
        // `permanentlyDeleted` cancel has already fired, so nothing would
        // ever cancel a call started now: it would hold a slot for the
        // whole `cliTimeout` for output with nowhere to go (#334). No
        // signal either, as for any deleted row.
        guard let recording = liveRecording(recording.id) else {
            summarizerLog.log("skipped \(self.shortID(recording.id), privacy: .public): recording is gone")
            return
        }
        let id = recording.id
        // Dedup: a second request while one is in flight never starts a
        // second overlapping call, so a re-enqueue can't double-bill. It is
        // not lost either: the completion re-runs if the row's transcript or
        // language moved meanwhile, and a `regenerate` is either served by
        // the running call (same inputs) or gets a follow-up (new inputs).
        if var run = inFlight[id] {
            if force {
                if run.inputs == summaryInputs(for: recording) {
                    run.regenerateFolded = true
                    summarizerLog.log("\(self.shortID(id), privacy: .public): already in flight — regenerate folded into it")
                } else {
                    run.regenerateWithNewInputs = true
                    summarizerLog.log("\(self.shortID(id), privacy: .public): already in flight — regenerate with new inputs, re-running after it")
                }
                run.force = true
                inFlight[id] = run
            } else {
                summarizerLog.log("\(self.shortID(id), privacy: .public): skipped — already in flight")
            }
            return
        }
        let globalLanguage = liveAISettings.outputLanguage
        let inputs = summaryInputs(for: recording)
        let hasLanguageOverride = recording.summaryLanguage != nil
        let timeout = timeoutSeconds
        // OpenAI-compatible config captured up front so the detached call
        // doesn't depend on `self` (mirrors tool/prompt/etc. above). Summary
        // is free-text, so `jsonMode` is false; `transport` stays nil so the
        // production `URLSession` default applies.
        let openAIAPIKey = llmSettings.openAIAPIKey
        let startedAt = Date()
        // Captured strongly: the runner closure holds no reference to
        // `self`, so this can't create a retain cycle, and capturing it
        // here means the call below doesn't depend on `self` still being
        // alive when the LLM returns.
        let runLLM = self.runLLM

        inFlightIDs.insert(id)
        let token = UUID()
        // `language` is the resolved keyword ("Hebrew"/"English"), never user
        // text, so it is safe as a `.public` field — and it is what makes a
        // "why is this summary in the wrong language" report diagnosable.
        summarizerLog.log("started \(self.shortID(id), privacy: .public) transcript=\(inputs.transcript.count, privacy: .public)c force=\(force, privacy: .public) language=\(inputs.promptLanguageName, privacy: .public) override=\(hasLanguageOverride, privacy: .public)")

        let task = Task { @MainActor [weak self] in
            // Set by whichever outcome below got `.rerun`; acted on in the
            // `defer`.
            var followUp = false
            defer {
                // `return` cannot transfer control out of a defer body in
                // Swift, so an `if let self` block is what we want here
                // rather than an early-return guard. If the summarizer
                // has already deinit'd, there's nothing to clean up —
                // the dictionary and the publisher set went with it.
                if let self {
                    // Only this run's own state: after `cancel` a newer run
                    // may own the id.
                    if let run = self.inFlight[id], run.token == token {
                        self.inFlight[id] = nil
                        self.inFlightIDs.remove(id)
                        // Started HERE, synchronously, once `inFlight` is
                        // clear, so the follow-up re-takes the id under the
                        // dedup guard rather than racing it. Re-read now, so it
                        // summarizes the row as of completion. Non-force
                        // follow-ups go back through the normal gate. A row
                        // that is gone, or in Recently Deleted, gets no LLM
                        // call and no signal — the same as a row trashed
                        // mid-pass gets no completion work from
                        // `TranscriptionService` (no export of a recording
                        // the user threw away).
                        if followUp, let live = self.liveRecording(id), !live.isTrashed {
                            if run.force {
                                self.regenerate(live)
                            } else {
                                self.summarizeIfNeeded(live)
                            }
                        }
                    }
                    // Cancelled: this run's slot was held for it in
                    // `cancelledRuns` until now. (A no-op for a run that
                    // was never cancelled.)
                    self.cancelledRuns[token] = nil
                }
            }
            do {
                // Routed through the injected `runLLM` seam (defaults to
                // `LLMRunner.run`) so tests can return canned output without
                // spawning a real CLI subprocess.
                let raw = try await runLLM(
                    inputs.tool,
                    inputs.prompt,
                    inputs.transcriptInline ? inputs.transcript : "",
                    inputs.executableOverride,
                    inputs.model.isEmpty ? nil : inputs.model,
                    inputs.extraArgs,
                    timeout,
                    inputs.openAIBaseURL,
                    openAIAPIKey,
                    false,
                    nil
                )
                // Split the CLI output into the plain-text summary and the
                // action-items list. With no marker requested, a normal run
                // lands in the `.plain` branch: the whole response is the
                // summary. `parseSummaryAndItems` still tolerates a marker the
                // user asked for, a model that returned a JSON envelope on its
                // own, and — crucially — never surfaces a raw `{...}` blob as
                // the summary when the model emits malformed JSON (unescaped
                // quotes / newlines in a long summary value, which broke the
                // object decode).
                let (summaryText, parsedItems, origin) = Self.parseSummaryAndItems(from: raw)
                guard !summaryText.isEmpty else {
                    // `origin` distinguishes "the CLI printed nothing" from
                    // "the CLI printed a JSON object we could not read a
                    // summary out of" — two very different diagnoses that
                    // used to log identically. It is a fixed keyword, never
                    // the model's text: summary output is derived from the
                    // transcript and is user content, so it must not reach a
                    // `.public` log field (`bugbot-rules/no-user-content-in-logs.md`).
                    summarizerLog.log("skipped \(self?.shortID(id) ?? "?", privacy: .public): no summary parsed origin=\(origin.rawValue, privacy: .public) output=\(raw.count, privacy: .public)c")
                    guard let self else { return }
                    switch self.completion(of: id, token: token, produced: false) {
                    case .abandoned: return
                    case .rerun: followUp = true; return
                    case .proceed: break
                    }
                    // No summary came back — let a pending export fall back to
                    // the transcript rather than waiting forever. Skip the
                    // signal entirely if the recording went away mid-flight.
                    if let current = self.liveRecording(id) {
                        self.onSummaryFinished?(current)
                    }
                    return
                }
                // The recording may have been deleted between enqueue
                // and now. Re-fetch so we never write a summary to a
                // ghost row.
                guard let self else { return }
                guard var current = self.store.recordings.first(where: { $0.id == id }) else {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): recording is gone")
                    // Deleted mid-flight — nothing to export, so no signal.
                    return
                }
                // Checked before the "a summary is already there" skip below,
                // and before storing: output built from a snapshot that is no
                // longer the row's transcript or language must not be shown
                // as current even briefly, nor survive a failed follow-up.
                let run: InFlightRun
                switch self.completion(of: id, token: token, produced: true) {
                case .abandoned: return
                case .rerun: followUp = true; return
                case .proceed(let owned): run = owned
                }
                let existing = (current.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // `run.force` includes a `regenerate` folded into this run.
                if !run.force, !existing.isEmpty {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): a summary landed mid-flight")
                    // A summary is present (just from another path) — the
                    // recording is ready to export.
                    self.onSummaryFinished?(current)
                    return
                }
                current.summary = summaryText
                // A summary written from the transcript on the row right now is
                // current by definition, so the staleness flag a completed
                // re-transcription left behind goes with it — cleared in the
                // SAME `store.update` below, never in a second write, so no
                // window exists where a fresh overview and an "out of date"
                // badge sit on one row.
                current.summaryStaleAt = nil
                // Replace the recording's action items with the fresh
                // full-transcript set whenever the model returned any — but
                // never at the cost of an item the user DICTATED out loud.
                // An empty list is treated as "keep what's there" so a
                // glitchy empty response can't wipe the rolling live snapshot
                // a Live-AI recording already captured at stop.
                if !parsedItems.isEmpty {
                    current.actionItems = Self.merged(fresh: parsedItems,
                                                      keepingDictatedFrom: current.actionItems ?? [])
                }
                self.store.update(current)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                summarizerLog.log("succeeded \(self.shortID(id), privacy: .public) origin=\(origin.rawValue, privacy: .public) length=\(summaryText.count, privacy: .public) items=\(current.actionItems?.count ?? 0, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
                self.onSummaryFinished?(current)
            } catch {
                // `logMessage(for:)`, not `localizedDescription`: this catches
                // whatever `LLMRunner.run` threw, and
                // `LLMRunnerError.nonZeroExit.errorDescription` embeds the
                // CLI's stderr verbatim — which for a summary run is the
                // composed prompt, i.e. the meeting transcript. Same leak as
                // `PostRecordingCoordinator`'s send line, found in the same
                // sweep. (Issue #193.) The summarizer has no user-facing
                // surface for a failure, so nothing is lost here.
                summarizerLog.error("""
                    failed \(self?.shortID(id) ?? "?", privacy: .public): \
                    \(LLMRunnerError.logMessage(for: error), privacy: .public)
                    """)
                guard let self else { return }
                // A row that changed while this call was out gets its re-run
                // whatever became of the call — a timeout at the wrong moment
                // must not leave a new transcript or a persisted language
                // override never honoured. A `cancel` (permanent delete)
                // arrives here as a CancellationError and is `.abandoned`.
                switch self.completion(of: id, token: token, produced: false) {
                case .abandoned: return
                case .rerun: followUp = true; return
                case .proceed: break
                }
                // Failed generation — signal so a pending export can still
                // write the transcript fallback. The store lookup is what
                // stops a deleted recording being filed.
                if let current = self.liveRecording(id) {
                    self.onSummaryFinished?(current)
                }
            }
        }
        inFlight[id] = InFlightRun(token: token,
                                   task: task,
                                   inputs: inputs,
                                   globalLanguage: globalLanguage,
                                   force: force)
    }

    /// Everything `runSummary` builds a call from, resolved now. Also used
    /// to decide whether a `regenerate` hitting the dedup guard asks for the
    /// same call as the one in flight.
    private func summaryInputs(for recording: Recording) -> SummaryInputs {
        let tool = llmSettings.tool
        let executableOverride = llmSettings.executablePath.isEmpty
            ? nil
            : llmSettings.executablePath
        // OpenAI-compatible runs use the endpoint's model name from
        // `llmSettings.openAIModelName`; CLI runs use Live AI's model
        // override. Mirrors `LiveAISession.kick`'s tool-conditional selection
        // (issue celarent7/mila#4 — previously this always sent
        // `liveAISettings.model`, e.g. "claude-sonnet-4-6", to the OpenAI
        // endpoint, which 404'd on model-not-found).
        let model = LLMSettings.backgroundModelName(tool: tool,
                                                    openAIModelName: llmSettings.openAIModelName,
                                                    liveAIModel: liveAISettings.model)
        // Per-recording override first, then the global setting (Auto passes
        // "the same language as the transcript" through to the model). Resolved
        // ONCE per run; a pick while the call is out is caught by the completion.
        let promptLanguageName = Self.promptLanguageName(for: recording,
                                                         global: liveAISettings.outputLanguage)
        // The transcript the model sees, rendered once: speaker-labelled turns
        // when diarization ran, plain joined text when it did not. Used both
        // as the `{{TRANSCRIPT}}` value and as the appended block, so the two
        // can never disagree.
        let transcript = Self.transcriptForLLM(for: recording)
        // Everything the model is TOLD now comes from the editable prompt;
        // Mila supplies only values. `promptWithActionItems`,
        // `languageDirective` and `promptWithCalendarNotes` used to append
        // English scaffolding a user could not edit, translate, or remove —
        // the event notes and the meeting's own title are now the
        // `{{CALENDAR_*}}` / `{{EVENT_TITLE}}` variables instead, so a user
        // who wants them places them (in their own language) where they want
        // them, and one who does not does not pay for them.
        let template = liveAISettings.summaryPrompt
        let prompt = PromptTemplate.render(
            template,
            values: Self.promptValues(for: recording,
                                      languageName: promptLanguageName,
                                      transcript: transcript))
        // No slot in the prompt means the old envelope: `LLMRunner.composedPrompt`
        // appends `---\nTranscript:` after it. A prompt that DOES place the
        // transcript gets nothing appended.
        let transcriptInline = !PromptTemplate.hasTranscriptSlot(template)
        return SummaryInputs(tool: tool,
                             executableOverride: executableOverride,
                             model: model,
                             extraArgs: llmSettings.extraArgsTokens,
                             promptLanguageName: promptLanguageName,
                             prompt: prompt,
                             transcript: transcript,
                             transcriptInline: transcriptInline,
                             openAIBaseURL: llmSettings.openAIBaseURL)
    }

    /// Decide what a completed call (`token`) does with its output. Called
    /// from every completion outcome, not just success — a re-transcription,
    /// a language pick or an explicit regenerate gets its re-run regardless
    /// of what became of the call it interrupted.
    ///
    /// `.rerun` when the row moved on (its transcript, or the language its
    /// prompt resolves to, differs from the run's snapshot), when a `regenerate` asked
    /// for different inputs, or when a folded-in `regenerate` would
    /// otherwise end with nothing (`produced == false`). A STALE run on a
    /// row in Recently Deleted still discards, so a stale summary cannot
    /// come back on restore, but gets no follow-up and no signal. (A run
    /// that is not stale treats a trashed row as it always has.) A row that
    /// is gone proceeds, and the callers' own lookups keep it unsignalled.
    ///
    /// Several requests during one run therefore cost one follow-up, built
    /// from the row as of completion; it can only chain if something changes
    /// again while IT is out. A GLOBAL setting flip mid-flight with no
    /// request keeps the result, as it always has.
    private func completion(of id: UUID, token: UUID, produced: Bool) -> Completion {
        guard let run = inFlight[id], run.token == token else {
            summarizerLog.log("discarded \(self.shortID(id), privacy: .public): run was cancelled")
            return .abandoned
        }
        guard let live = liveRecording(id) else { return .proceed(run) }
        let reason: String
        let liveLanguage = Self.promptLanguageName(for: live, global: run.globalLanguage)
        if Self.transcriptForLLM(for: live) != run.inputs.transcript || liveLanguage != run.inputs.promptLanguageName {
            reason = "transcript or summary language changed mid-flight"
        } else if run.regenerateWithNewInputs {
            reason = "regenerate with new inputs requested mid-flight"
        } else if run.regenerateFolded, !produced {
            reason = "folded-in regenerate produced no summary"
        } else {
            return .proceed(run)
        }
        summarizerLog.log("discarded \(self.shortID(id), privacy: .public): \(reason, privacy: .public) — re-running from the live row")
        return .rerun
    }

    /// Log why a `summarizeIfNeeded` call was rejected. Split out so the
    /// reason ends up in OSLog (and Console.app) in the same
    /// "skipped <id>: <reason>" shape every other skip uses.
    private func logSkip(_ recording: Recording, force: Bool) {
        let id = recording.id
        if !llmSettings.isConfigured {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): LLM not configured")
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): transcript empty")
            return
        }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, !existing.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): already summarized")
            return
        }
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// Marker that splits a summary from a JSON action-items array.
    ///
    /// Mila no longer ASKS for it. The request used to be hard-coded in
    /// `promptWithActionItems` (now deleted): a paragraph of English the user
    /// could not edit, translate or remove, appended to a prompt they had
    /// written themselves. The PARSE stays, which keeps the feature available
    /// on the user's own terms — write the contract into your prompt (in
    /// whatever language you like):
    ///
    /// ```text
    /// ###ACTION_ITEMS###
    /// [{"id": "stable-slug", "text": "…", "source": "inferred"}]
    /// ```
    ///
    /// and the items land in that recording's Action Items list. Without the
    /// marker the whole response is the summary and Mila adds nothing.
    ///
    /// Keeping the summary OUTSIDE any JSON is still deliberate: LLMs routinely
    /// emit long, multi-line summaries with unescaped quotes/newlines, which
    /// makes an enclosing JSON object un-decodable. Only the compact item
    /// array — far less prone to stray quotes — needs to be valid JSON.
    static let actionItemsSentinel = "###ACTION_ITEMS###"

    /// The language name the one-shot prompt is written for: the recording's
    /// own `summaryLanguageOverride` when the user set one, otherwise the
    /// global `LiveAISettings.outputLanguage` — and `.auto` passes through as
    /// "the same language as the transcript below" (`promptName`) instead of
    /// being resolved to one concrete language here.
    ///
    /// `.auto` used to be resolved by counting Hebrew vs Latin letters in the
    /// transcript, which worked only because Hebrew was the other language and
    /// is a different script. Swedish vs English is not detectable that way, so
    /// the model decides — the instruction is concrete about the transcript
    /// being the reference, and a wrong guess by Mila would have been silent.
    ///
    /// Pure and static so a test can pin the resolution order without a
    /// store or a runner. Returns the exact string substituted into the
    /// `{{LANGUAGE}}` slot of the user's prompt — Mila no longer states the
    /// language anywhere else, so a prompt that drops the token decides the
    /// language from its own wording (or from the transcript).
    static func promptLanguageName(for recording: Recording,
                                   global: LiveAISettings.OutputLanguage) -> String {
        if let override = recording.summaryLanguageOverride {
            return override.displayName
        }
        return global.promptName
    }

    /// The transcript as the model sees it: one line per speaker turn, each
    /// labelled with the name the user assigned to that voice and, where they
    /// assigned none, with the same friendly fallback the UI shows
    /// (`Speaker A`, `Talare A`, …).
    ///
    /// This used to be `recording.fullText` — every turn concatenated with no
    /// label at all, so a summary could not say WHO decided anything, and a
    /// name the user had painstakingly assigned to a voice was invisible to the
    /// model that writes the overview. `TranscriptFormatter.plainText` alone is
    /// not enough either: it falls back to the RAW diarizer id (`SPEAKER_00`),
    /// which is not what the user sees on screen and invites the model to echo
    /// `SPEAKER_00` back into the summary. Pre-resolving the map through
    /// `displaySpeakerName` makes the prompt agree with the transcript view,
    /// the clipboard and the `.srt` sidecar.
    ///
    /// Falls back to `fullText` when no segment carries a speaker at all
    /// (diarization was off) — there is then nobody to tell apart.
    static func transcriptForLLM(for recording: Recording) -> String {
        TranscriptFormatter.plainText(segments: recording.segments,
                                      fallback: recording.fullText,
                                      names: speakerLabels(for: recording))
    }

    /// Raw speaker id → the label to show the model for it. Built from the
    /// segments rather than from `speakerNames`, so a name assigned to a voice
    /// that never speaks in this recording cannot label someone else.
    static func speakerLabels(for recording: Recording) -> [String: String] {
        var labels: [String: String] = [:]
        for segment in recording.segments {
            guard let raw = segment.speaker, labels[raw] == nil else { continue }
            labels[raw] = raw.displaySpeakerName(names: recording.speakerNames,
                                                 language: recording.language)
        }
        return labels
    }

    /// Every voice that produced audio, in the order they first speak:
    /// `Anna, Erik, Talare C`.
    ///
    /// This exists because `{{CALENDAR_ATTENDEES}}` cannot answer "who was in
    /// the room": that list is the EVENT'S INVITE LIST — every `EKParticipant`
    /// (Mila never reads a response status, so people who declined are in it),
    /// capped at the user's attendee ceiling, snapshotted at sync time. It
    /// contains people who never joined and omits whoever joined uninvited.
    /// The voices here are the opposite evidence: they are only there because
    /// audio came out of them.
    ///
    /// A voice the user never named still belongs, and gets the same fallback
    /// label the transcript line and the UI use (`displaySpeakerName`) — the
    /// list must not disagree with the turns above it. Names attached to a
    /// voice that never speaks in THIS recording are not listed, and a name
    /// suggestion the user has not accepted is not either: suggestions live in
    /// `speakerNameSuggestions`, which `displaySpeakerName` never reads, so an
    /// unconfirmed guess cannot enter a list that reads as attendance. Two
    /// diarizer ids carrying the same name (a rename, or a split that left one
    /// half unnamed) are listed once — a reader of the list counts people, not
    /// cluster ids.
    static func speakerList(for recording: Recording) -> String {
        let labels = speakerLabels(for: recording)
        var seenNames = Set<String>()
        // `distinctSpeakers(in:)` is the shared "raw ids in first-appearance
        // order" helper; the ordering of this list is pinned by a test, so a
        // change to that helper cannot silently reorder it.
        return SpeakerNameSuggester.distinctSpeakers(in: recording)
            .compactMap { labels[$0] }
            .filter { seenNames.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// The values substituted into the prompt's `{{VARIABLE}}` slots.
    ///
    /// A value Mila does not have is the EMPTY string, never a placeholder
    /// word: `**Deltagare:** ` followed by nothing tells the model (and the
    /// reader of the note) that nothing is known, whereas "unknown"/"N/A" is a
    /// string that can end up inside the summary as if it were a fact.
    ///
    /// `{{EVENT_TITLE}}`, `{{CALENDAR_ATTENDEES}}` and `{{CALENDAR_NOTES}}`
    /// render empty for an unlinked recording — and for a linked one whose
    /// attendees or body the user kept private at sync time. That is the same
    /// consent boundary the deleted hard-coded block respected: the stored link
    /// records what was agreed to be sent, so a `regenerate` months later
    /// cannot widen it. `{{EVENT_TITLE}}` is NEW as an input: the old block
    /// withheld the event title on purpose ("telling the model what the meeting
    /// was called biases its summary toward the title"). As a variable that
    /// trade-off is the user's to make, not Mila's — and a note-writing prompt
    /// needs the field for its own heading.
    ///
    /// `{{CALENDAR_ATTENDEES}}` and `{{SPEAKERS}}` answer different questions —
    /// invited vs. audible — so a prompt that wants "who was here" needs the
    /// second one, and the two together let the model note who was invited but
    /// never spoke.
    static func promptValues(for recording: Recording,
                             languageName: String,
                             transcript: String) -> [String: String] {
        let start = recording.createdAt
        let link = recording.calendarLink
        return [
            PromptVariable.language.rawValue: languageName,
            PromptVariable.transcript.rawValue: transcript,
            PromptVariable.speakers.rawValue: Self.speakerList(for: recording),
            PromptVariable.title.rawValue: recording.title,
            PromptVariable.date.rawValue: Self.format(start, format: "yyyy-MM-dd"),
            PromptVariable.time.rawValue: Self.format(start, format: "HH:mm"),
            PromptVariable.endTime.rawValue: Self.format(start.addingTimeInterval(recording.duration),
                                                         format: "HH:mm"),
            PromptVariable.duration.rawValue: Self.durationText(recording.duration),
            PromptVariable.sourceApp.rawValue: recording.appName ?? "",
            PromptVariable.eventTitle.rawValue: link?.eventTitle ?? "",
            PromptVariable.attendees.rawValue: link.map { $0.attendees.joined(separator: ", ") } ?? "",
            PromptVariable.eventNotes.rawValue: link?.summaryNotes ?? "",
        ]
    }

    /// Fixed-format dates. `en_US_POSIX` so the output does not move with the
    /// user's region settings — these strings go into a prompt (and into
    /// Obsidian `[[YYYY-MM-DD]]` links), not onto a screen.
    private static func format(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// "47 min" / "1 h 5 min". Deliberately terse and unit-only: the wording
    /// is the user's to write in their own language, so the value they
    /// substitute stays as close to a number as possible.
    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Split raw CLI output into `(summary, items, origin)`, where `origin`
    /// names the branch that produced it so the tolerant paths are loggable.
    ///
    /// Resolution order, most-trusted first:
    ///   1. Sentinel format (only reached when the user's own prompt asks for
    ///      it — see `actionItemsSentinel`): plain summary before
    ///      `actionItemsSentinel`, JSON array after it.
    ///   2. A JSON envelope `{"summary":...,"items":[...]}` the model may have
    ///      returned out of habit — decoded via `LiveAISession.parseEnvelope`.
    ///   3. Malformed JSON that LOOKS like an envelope (the failure the user
    ///      hit: unescaped quotes broke the object decode) — bare, inside
    ///      ```` ```json ```` fences, or behind a one-line label, since
    ///      `parseEnvelope` accepts all three. Salvage the summary text so a
    ///      raw `{...}` blob is never shown, and keep any items the lenient
    ///      array parse recovered.
    ///   4. Plain prose — the whole output is the summary, no items.
    ///
    /// A JSON object that reaches step 3 and yields nothing readable returns
    /// an EMPTY summary rather than the blob — see `unreadableEnvelope`.
    static func parseSummaryAndItems(
        from raw: String
    ) -> (summary: String, items: [ActionItem], origin: SummaryParseOrigin) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentinel = trimmed.range(of: actionItemsSentinel) {
            let summary = String(trimmed[..<sentinel.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let items = LiveAISession.parseActionItems(from: String(trimmed[sentinel.upperBound...]))
            return (summary, items, .sentinel)
        }
        // No sentinel — the model returned a JSON envelope (or prose).
        let parsed = LiveAISession.parseEnvelope(from: trimmed)
        if !parsed.summary.isEmpty {
            return (parsed.summary, parsed.items, .envelope)
        }
        // Object decode produced no summary. If the output still IS an
        // envelope — bare, fenced, or behind a label — salvage the summary
        // value rather than surfacing the blob.
        if let envelope = Self.envelopeBody(in: trimmed) {
            let salvaged = Self.salvageSummaryValue(from: envelope)
            if !salvaged.isEmpty {
                return (salvaged, parsed.items, .salvagedEnvelope)
            }
            // A JSON object we cannot read a summary out of at all (no
            // `"summary"` key, or an empty one). Storing it verbatim is the
            // exact bug this fix exists to remove, and doing so is
            // self-perpetuating: a stored blob satisfies `shouldSummarize`'s
            // "already has a summary" gate, so the recording would never be
            // retried and the blob would be what the detail view, the Obsidian
            // note and the MCP surface all report forever. Report NO summary
            // instead — logged with this origin at the call site, exported as
            // the transcript fallback, and still re-summarizable: the row keeps
            // no summary, so "Summarize" stays available. That is the same treatment empty CLI
            // output has always had (`test_summarize_drops_empty_output`), so
            // it is an established shape rather than a new one. Items the
            // lenient array parse recovered are still returned.
            return ("", parsed.items, .unreadableEnvelope)
        }
        // Genuine prose. Items stay empty: every shape from which the lenient
        // parse can actually recover an items array is an envelope, and those
        // now route through the branch above instead of falling to here.
        return (trimmed, [], .plain)
    }

    /// The envelope-shaped payload inside the wrappers
    /// `LiveAISession.parseEnvelope` accepts — a ```` ```json ```` fence, or a
    /// one-line "Here is the JSON:" label — or nil when the output is prose
    /// that merely CONTAINS a brace.
    ///
    /// Why this exists: the salvage and `unreadableEnvelope` branches were
    /// gated on `trimmed.hasPrefix("{")`, but `parseEnvelope` does not require
    /// its object to be at position 0 — it plucks the first balanced block out
    /// of the string (`findFirstJSONStructure`) precisely because "the CLI
    /// occasionally wraps output in prose or ```json fences". A fenced or
    /// prefixed BROKEN envelope therefore failed the object decode *and* the
    /// prefix test and landed in `.plain`, which stores the raw blob as the
    /// summary — the exact bug this fix exists to remove, and the
    /// self-perpetuating one, since a stored blob satisfies
    /// `shouldSummarize`'s "already has a summary" gate and is never retried.
    /// Fences are the single most likely shape for an LLM to emit, so the
    /// promise held only for the tidiest case.
    ///
    /// Unwrapping is an OPTIMISTIC normalisation, judged separately from the
    /// envelope/prose decision, and it must never be able to make the parse
    /// worse than not having attempted it. So: if a fence is confidently
    /// identifiable and what it wraps is envelope-shaped, that is the payload;
    /// otherwise the ORIGINAL text is judged on its own merits. An
    /// unrecognised wrapper — an over-long label, quoted material rather than
    /// a wrapper, or a shape nobody enumerated — costs nothing beyond the
    /// failed attempt.
    ///
    /// The reverse is NOT symmetric, which is the trap this went through
    /// twice: unwrapping too eagerly is not free. A candidate that is
    /// object-shaped but carries no `"summary"` gets BLANKED as
    /// `unreadableEnvelope`, so substituting a quoted config snippet for a
    /// real prose summary destroys it. Hence `unfencedBody` still refuses the
    /// cases where the block is plainly quoted material.
    ///
    /// The first cut of this stripped the fence *before* the shape test and
    /// returned nil when the wrapper looked wrong, which re-broke the very
    /// case it was added for: a malformed envelope whose summary TEXT mentions
    /// ```` ``` ```` (a meeting that discussed code) was hijacked by the fence
    /// branch and aborted, though its leading `{` alone should have been
    /// enough to salvage it.
    static func envelopeBody(in trimmed: String) -> String? {
        if let unwrapped = Self.unfencedBody(in: trimmed),
           let body = Self.objectPayload(in: unwrapped) {
            return body
        }
        return Self.objectPayload(in: trimmed)
    }

    /// The contents of a ``` / ```json fenced block. Nil means only "no
    /// wrapper I can be confident about" — NOT "not an envelope"; the caller
    /// falls back to the unmodified text, never to a failed parse.
    private static func unfencedBody(in trimmed: String) -> String? {
        guard let opening = Self.lineLeadingFence(in: trimmed, from: trimmed.startIndex)
        else { return nil }
        // Only a short label may precede the fence. Without this, a long prose
        // summary that quotes a fenced JSON object would have that object
        // substituted for it and then be blanked — losing a good summary,
        // which is worse than showing a blob.
        guard trimmed[..<opening.lowerBound].count <= 80 else { return nil }
        let afterOpening = trimmed[opening.upperBound...]
        // Drop the info string (`json`) up to the end of the fence line.
        var inner = afterOpening
        if let newline = afterOpening.firstIndex(of: "\n") {
            inner = afterOpening[afterOpening.index(after: newline)...]
        }
        if let closing = Self.lineLeadingFence(in: trimmed, from: inner.startIndex) {
            // Content after the closer means the block is material QUOTED
            // INSIDE a larger prose summary, not a wrapper around the whole
            // output. Taking the block would substitute a config snippet for
            // the summary and then blank it, discarding the real prose either
            // side. So this stays a veto, and the caller judges the original.
            guard trimmed[closing.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            inner = trimmed[inner.startIndex..<closing.lowerBound]
        }
        // A MISSING closer, by contrast, is not a veto: the model simply
        // stopped early, there is no trailing prose to lose, and what follows
        // the opener is still the best candidate.
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The next ```` ``` ```` that BEGINS A LINE, at or after `from`.
    ///
    /// A fence delimits a block only at the start of a line. Backticks in the
    /// middle of one are content — a summary quoting `` `code` `` — and must
    /// neither open a block nor close one. Matching them anywhere let an inner
    /// run masquerade as the closer, which truncated the candidate mid-value
    /// and produced a short, plausible-looking WRONG summary: worse than the
    /// blob, because nothing about it looks broken.
    private static func lineLeadingFence(
        in text: String, from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while let candidate = text.range(of: "```", range: searchStart..<text.endIndex) {
            if candidate.lowerBound == text.startIndex
                || text[text.index(before: candidate.lowerBound)] == "\n" {
                return candidate
            }
            searchStart = candidate.upperBound
        }
        return nil
    }

    /// The envelope-shaped payload in `text`, or nil when this is prose that
    /// merely MENTIONS a brace block. This nil IS the envelope/prose
    /// discriminator `parseSummaryAndItems` needs, which is why it cannot
    /// simply fail open: accepting everything would route every plain-prose
    /// summary into the salvage branch and blank it.
    ///
    /// Deliberately not "contains a `{`": a real summary can quote braces, and
    /// blanking a GOOD summary is a worse outcome than showing a blob. The
    /// object must be what the text IS, not something it mentions.
    private static func objectPayload(in text: String) -> String? {
        // A leading `{` is accepted without the balanced-block check, because
        // the malformed input this path exists for can defeat the depth
        // counter (an odd number of unescaped quotes leaves `inString`
        // inverted) while `salvageSummaryValue` reads the summary fine.
        if text.hasPrefix("{") { return text }
        guard let range = LiveAISession.findFirstJSONStructure(
            in: text, opening: "{", closing: "}"
        ) else { return nil }
        guard text[..<range.lowerBound].count <= 80,
              text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return String(text[range])
    }

    /// Which branch of `parseSummaryAndItems` produced the result. Logged so
    /// the tolerant paths are VISIBLE — a model that quietly ignores the
    /// output contract on every call should be diagnosable from Console
    /// instead of hiding behind a summary that looks fine.
    ///
    /// A fixed keyword, deliberately: the model's output is derived from the
    /// user's transcript and is user content, so it must never reach a
    /// `.public` log field (`bugbot-rules/no-user-content-in-logs.md`). This
    /// records WHICH SHAPE arrived, never what it said.
    enum SummaryParseOrigin: String {
        /// The sentinel format `promptWithActionItems` asks for.
        case sentinel
        /// A decodable `{"summary":…,"items":[…]}` envelope.
        case envelope
        /// A broken envelope whose summary value was recovered textually.
        case salvagedEnvelope = "salvaged-envelope"
        /// Plain prose — the whole output is the summary.
        case plain
        /// A JSON object with no readable summary. Yields no summary at all.
        case unreadableEnvelope = "unreadable-envelope"
    }

    /// Fold the fresh full-transcript items into what the recording already
    /// has, keeping every item the user DICTATED (`source == .voiceCommand`,
    /// i.e. "Mila, action item: …") ahead of the model's inferred set.
    ///
    /// Why this is not a plain replace: for a Live-AI recording,
    /// `QuickActionsController` snapshots the live list — voice-command items
    /// included — onto the recording at stop and then immediately calls
    /// `regenerate`. The one-shot prompt is not shown the existing list and
    /// only ever asks for `source: "inferred"`, so a wholesale replace would
    /// trade an item the user said out loud for the model's guess at it, or
    /// lose it entirely. `ActionItem.source` is also mirrored all the way out
    /// to the MCP surface precisely so a client can tell a spoken commitment
    /// from an inferred one (see `MilaKit.StoredRecording.ActionItem.source`),
    /// which is the answer this would have degraded.
    ///
    /// Fresh items are deduped by id and by normalised text — the model
    /// re-derives a dictated task from the transcript under a new id, and it
    /// also duplicates ids outright, which the live path already guards
    /// against ("LLM duplicated an id; keep first" in
    /// `LiveAISession.applyResponse`).
    static func merged(fresh: [ActionItem],
                       keepingDictatedFrom existing: [ActionItem]) -> [ActionItem] {
        let dictated = existing.filter { $0.source == .voiceCommand }
        var seenIDs = Set(dictated.map(\.id))
        var seenTexts = Set(dictated.map { Self.dedupKey($0.text) })
        var result = dictated
        for item in fresh {
            let textKey = Self.dedupKey(item.text)
            guard !seenIDs.contains(item.id), !seenTexts.contains(textKey) else { continue }
            seenIDs.insert(item.id)
            seenTexts.insert(textKey)
            result.append(item)
        }
        return result
    }

    /// Normalised form used only to spot "the model re-emitted this dictated
    /// item under a different id": trimmed, case-folded, inner whitespace
    /// collapsed. Never persisted or displayed.
    private static func dedupKey(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Best-effort extraction of the `"summary"` value from a JSON string the
    /// decoder rejected (typically because the value itself contains
    /// unescaped `"`). Anchors on the structural `"items"` key that follows
    /// the summary value, so quotes INSIDE the summary don't cut it short,
    /// then un-escapes the common JSON escapes so `\n` renders as newlines.
    static func salvageSummaryValue(from json: String) -> String {
        guard let keyRange = json.range(of: "\"summary\"") else { return "" }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return "" }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return "" }
        let valueStart = afterColon.index(after: openQuote)
        let rest = afterColon[valueStart...]
        let endIdx: Substring.Index
        // Find the `"items"` KEY, then walk back to the last quote before it:
        // that quote is the summary value's terminator whatever separates the
        // two. Matching the separator literally (`", "items"` / `","items"`)
        // only covered compact output — a pretty-printed malformed envelope
        // (`",\n  "items"`, which is what a CLI emitting multi-line JSON
        // produces) fell through to `lastIndex(of:)` and dragged the entire
        // items array into the summary, i.e. exactly the scaffolding leak
        // this function exists to prevent.
        if let itemsKey = rest.range(of: "\"items\"") {
            let head = rest[..<itemsKey.lowerBound]
            endIdx = head.lastIndex(of: "\"") ?? itemsKey.lowerBound
        } else if let lastQuote = rest.lastIndex(of: "\"") {
            endIdx = lastQuote
        } else {
            endIdx = rest.endIndex
        }
        let value = String(rest[..<endIdx])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The freshest copy of a recording from the store, or `fallback` when
    /// it's no longer there. Used to GATE a request on the live row; never
    /// to signal with, since the fallback can describe a row that has been
    /// deleted (see `signalSkipped`).
    private func latestRecording(_ id: UUID, fallback: Recording) -> Recording {
        store.recordings.first(where: { $0.id == id }) ?? fallback
    }

    /// Signal `onSummaryFinished` for a request that was skipped without a
    /// call, with the LIVE row, and not at all when the row is gone. The
    /// skip paths used to fall back to the caller's copy, so a request
    /// arriving after a permanent delete (a post-recording step finishing
    /// after a discard) signalled a recording that no longer exists, and
    /// only the Obsidian exporter's discard tombstone kept that from filing
    /// a note for it. The asynchronous completion paths already refused a
    /// row that is gone; this is the same rule for the synchronous ones.
    private func signalSkipped(_ id: UUID) {
        guard let live = liveRecording(id) else {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): recording is gone — not signalled")
            return
        }
        onSummaryFinished?(live)
    }

    /// The recording as the store currently holds it, or nil when it's gone.
    /// Used by the ASYNCHRONOUS completion paths, where a delete can land
    /// between enqueue and completion: firing with the stale enqueue-time copy
    /// would let an observer act on a row the user just deleted.
    private func liveRecording(_ id: UUID) -> Recording? {
        store.recordings.first(where: { $0.id == id })
    }
}
