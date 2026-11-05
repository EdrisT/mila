import Foundation
import Combine

/// Persisted settings for the Live AI mode (split-pane recording with a
/// background LLM loop emitting action items). Off by default — even with
/// the toggle on, the feature only activates when the user has configured
/// the upstream LLM CLI in `LLMSettings` (so `isLiveAIReady` requires both).
///
/// Two cost dials live here so power users can shave dollars without
/// touching code: which model the CLI is asked to use (default = the
/// cheapest current Claude / Cursor model), and the minimum spacing
/// between LLM calls (`llmMinIntervalSeconds`, default 20 s). The LLM
/// feed itself is event-driven — it fires whenever new transcript
/// lands — so without a floor it can spawn a `claude` subprocess every
/// few seconds in VAD mode. The interval caps that to at most one call
/// per N seconds.
@MainActor
final class LiveAISettings: ObservableObject {
    // `enabled` and `model` are manageable by a configuration profile
    // (`ManagedSettings`): computed over private `@Published` storage so a
    // locked write is refused before anything is stored, published or
    // persisted.
    @Published private var storedEnabled: Bool
    @Published private var storedModel: String

    var enabled: Bool {
        get { storedEnabled }
        set {
            guard !isManaged(.liveAIEnabled) else { return }
            storedEnabled = newValue
            defaults.set(newValue, forKey: Keys.enabled)
        }
    }

    /// `enabled`'s change publisher (fires on willSet, like `$enabled` did).
    var enabledPublisher: Published<Bool>.Publisher { $storedEnabled }

    /// The administrator-forced fields, if any. Empty (`ManagedSettings.empty`)
    /// unless `MilaApp` passes the system's managed preferences. Only
    /// `enabled` and `model` are manageable — the same two a `.milaconfig`
    /// carries.
    private let managed: ManagedSettings

    /// Whether a configuration profile locks `field` (see `ManagedSettings`).
    func isManaged(_ field: ManagedField) -> Bool { managed.isManaged(field) }

    /// Snapshot of the host Mac's hardware identity. Injected in tests
    /// (so `isLiveAIAvailable` can be exercised without a real
    /// MacBook Air); defaults to `SystemCapabilities.live` in
    /// production. The choice is made at init time and never
    /// reassigned — hardware doesn't change at runtime.
    let capabilities: SystemCapabilities

    /// Model name passed to the CLI as `--model <value>`. Empty string ==
    /// "let the CLI pick" — typically the CLI's last-configured model. The
    /// UI nudges the user toward a cheap model via the placeholder.
    var model: String {
        get { storedModel }
        set {
            guard !isManaged(.liveAIModel) else { return }
            storedModel = newValue
            defaults.set(newValue, forKey: Keys.model)
        }
    }

    /// Tick frequency in seconds. The Live transcriber + LLM run on this
    /// cadence; lowering it costs more LLM calls (and more whisper CPU).
    @Published var chunkSeconds: Double {
        didSet { defaults.set(chunkSeconds, forKey: Keys.chunkSeconds) }
    }

    /// Minimum spacing, in seconds, between Live AI LLM calls. The feed
    /// loop wakes on every new transcript segment (every few seconds in
    /// VAD mode), and each call spawns a fresh `claude` / `cursor-agent`
    /// subprocess — so back-to-back ticks pegged CPU on long recordings.
    /// This is a floor measured from the START of the previous call: at
    /// most one call begins per `llmMinIntervalSeconds`. The final
    /// stop-time flush bypasses it so the saved summary always covers up
    /// to stop. 0 disables the floor (legacy "fire as fast as segments
    /// arrive" behaviour).
    @Published var llmMinIntervalSeconds: Double {
        didSet { defaults.set(llmMinIntervalSeconds, forKey: Keys.llmMinInterval) }
    }

    /// When true, the live transcriber routes audio through a VAD
    /// instead of cutting on a fixed time interval. Whisper runs once
    /// per detected utterance (on silence ≥400ms), capped at 25s for
    /// monologues. Off by default for now — opt-in beta until we've
    /// tuned the RMS threshold against real recordings.
    @Published var useVAD: Bool {
        didSet { defaults.set(useVAD, forKey: Keys.useVAD) }
    }

    /// When true (and `useVAD` is on), each RMS-detected utterance is
    /// re-checked by the bundled Silero neural VAD before it reaches
    /// whisper. Utterances that contain no actual human speech (room
    /// noise, music, keyboard, AC hum that cleared the energy cutoff)
    /// are dropped, which kills the "whisper hallucinates filler on
    /// silence/noise" problem (e.g. the Hebrew `תודה רבה אדוני יושב
    /// ראש הכנסת`). On by default — the model is ~0.9 MB and the check
    /// is a few ms per utterance, and it *saves* CPU by skipping
    /// whisper on noise-only segments. Escape hatch for the rare case
    /// where it clips genuinely quiet speech. Only meaningful when
    /// `useVAD` is on (the fixed-timer path has no per-utterance gate).
    @Published var useNeuralVAD: Bool {
        didSet { defaults.set(useNeuralVAD, forKey: Keys.useNeuralVAD) }
    }

    /// When true, the recording UI stays on the Home screen (just a
    /// Stop button) instead of switching to the LiveAIRecordingView's
    /// split pane. Transcription + summary continue to run in the
    /// background and are saved when the recording stops. Useful for
    /// lower-power Macs (MacBook Air etc.) where the live pane's
    /// continuous rendering competes with whisper for CPU.
    @Published var backgroundMode: Bool {
        didSet { defaults.set(backgroundMode, forKey: Keys.backgroundMode) }
    }

    /// Whether recordings are transcribed live, while they run. Default ON.
    /// OFF is the low-CPU mode: a recording only captures audio — no live
    /// whisper, no live speaker-diarization daemon (~1 GB of pyannote/torch),
    /// no Live AI loop — and is transcribed by the ordinary batch pass after
    /// Stop. Unlike `backgroundMode`, which only hides the live pane, this
    /// actually takes the work off the CPU during the call.
    ///
    /// Read once per recording, at record start (see
    /// `QuickActionsController.recordingRunsLivePipeline`); flipping it
    /// mid-recording applies to the next one.
    @Published var transcribeWhileRecording: Bool {
        didSet { defaults.set(transcribeWhileRecording, forKey: Keys.transcribeWhileRecording) }
    }

    /// Override that lets a user opt into Live AI on hardware the
    /// auto-detect rules excluded (MacBook Air etc.). Off by default —
    /// the auto-detect is right for most users. Surfaced as an
    /// "Override hardware gate" toggle inside the "Disabled on this
    /// Mac" notice block in Settings so it's only visible when
    /// relevant. With ANE encoder offload landed, the actual realtime
    /// budget on Airs is much closer to fast Macs than when the gate
    /// was first added; this toggle lets us collect signal without
    /// flipping the default for everyone.
    @Published var forceLiveAIOnLowEndHardware: Bool {
        didSet { defaults.set(forceLiveAIOnLowEndHardware, forKey: Keys.forceLowEnd) }
    }

    /// Speaker-similarity cosine threshold. ≥ this is the same speaker;
    /// below is a new speaker. 0.75 is a reasonable starting point for
    /// pyannote/embedding output.
    @Published var speakerSimilarityThreshold: Double {
        didSet { defaults.set(speakerSimilarityThreshold, forKey: Keys.simThreshold) }
    }

    /// System prompt sent to the CLI on every tick. Asks the model to emit
    /// a STRICT JSON object containing a rolling summary plus a list of
    /// action items so we can parse without a free-text regex. The
    /// prompt also defines wake-word semantics: anything the speaker
    /// says directly to "Mila" ("Mila, add a note for me") becomes an item
    /// tagged `source: "voice_command"`.
    ///
    /// The literal token `{{LANGUAGE}}` in the prompt is replaced at
    /// send time with the user's chosen output language ("English" or
    /// "Swedish"). Two reasons it lives in the prompt rather than as an
    /// instruction layered on top: (1) it makes the prompt itself
    /// editable in Settings without losing the language directive, and
    /// (2) keeping the substitution token visible reminds users not to
    /// strip it when customising.
    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Keys.prompt) }
    }

    /// Background notes for the CURRENT meeting only — an agenda, a list
    /// of attendees, acronyms the model won't know. Injected into every
    /// Live AI tick as a clearly-labelled non-transcript block (see
    /// `LiveAISession.promptWithContext`) and cleared by
    /// `QuickActionsController.stopRecording` when the recording ends.
    ///
    /// Deliberately NOT persisted to `UserDefaults` and deliberately not
    /// part of `prompt`. Both properties are what makes this safe:
    /// users used to paste the agenda into the `prompt` editor in
    /// Settings, which is a permanent template — so every LATER recording
    /// was told the previous meeting's agenda was its context and the
    /// model produced a blended "previous call + this call" summary plus
    /// action items lifted straight from the stale agenda (stamped
    /// `timestamp_seconds: 0`, since they were never said out loud).
    /// In-memory + cleared-at-stop means a meeting's context can never
    /// outlive the meeting, even across an app relaunch.
    @Published var meetingContext: String = ""

    /// Output language for the LLM's summary and action items.
    /// Default English. The recording can still be in any language —
    /// this only controls what the AI's commentary comes back in.
    @Published var outputLanguage: OutputLanguage {
        didSet { defaults.set(outputLanguage.rawValue, forKey: Keys.outputLanguage) }
    }

    /// Whether Live AI's live-transcript / action-items pane should be
    /// offered on this hardware. False on MacBook Air (whisper +
    /// pyannote together are too slow on Air-class chips to feel
    /// real-time); true on every other Mac. Independent of the user's
    /// `enabled` toggle and of whether the LLM CLI is configured —
    /// this is purely "is the feature reachable on this machine."
    ///
    /// The user's `enabled` preference is still persisted across
    /// launches (it round-trips even when unavailable), so taking the
    /// app from a slow Mac back to a fast Mac restores the previous
    /// state without surprises.
    var isLiveAIAvailable: Bool {
        capabilities.isLiveAIRecommended || forceLiveAIOnLowEndHardware
    }

    /// Whether the next recording runs the live pipeline: the hardware allows
    /// it AND the user hasn't turned live transcription off. Kept separate
    /// from `isLiveAIAvailable` on purpose — that one is purely "can this Mac
    /// do it" and drives the "gated off on Air-class chips" notice, which a
    /// user who simply switched live transcription off must not see.
    var runsLivePipeline: Bool {
        isLiveAIAvailable && transcribeWhileRecording
    }

    /// Whether Live AI is currently ready to actually run — i.e. the
    /// hardware supports it AND the user has an LLM CLI configured.
    /// The user's `enabled` toggle is intentionally NOT part of this
    /// gate: callers compose `isLiveAIReady && enabled` themselves so
    /// the readiness signal can also be used to grey out the toggle
    /// in Settings without flipping the persisted preference.
    func isLiveAIReady(llmConfigured: Bool) -> Bool {
        llmConfigured && isLiveAIAvailable
    }

    /// Prompt used for the post-recording one-shot summary. This fires
    /// after a recording finishes whenever the LLM CLI is configured —
    /// not just when Live AI mode was on during the recording — so every
    /// recording ends up with a summary even if the user never opted
    /// into the live split-pane UI. Kept separate from `prompt` (the
    /// Live AI tick prompt) because the live prompt asks for a JSON
    /// envelope with action items, which is overkill for a one-shot
    /// plain-text summary. `{{LANGUAGE}}` is substituted at send time
    /// the same way `prompt` does.
    @Published var summaryPrompt: String {
        didSet { defaults.set(summaryPrompt, forKey: Keys.summaryPrompt) }
    }

    enum OutputLanguage: String, CaseIterable, Identifiable {
        case auto = "auto"
        case english = "en"
        case swedish = "sv"

        var id: String { rawValue }

        /// Name we substitute into the prompt's `{{LANGUAGE}}` slot.
        ///
        /// `.auto` passes the instruction through verbatim — "the same language
        /// as the transcript below" — rather than resolving it here to one of
        /// the two concrete names. It used to resolve by script (count Hebrew vs
        /// Latin letters, `isPredominantlyHebrew`) because that was cheap and
        /// reliable; with Swedish as the other language there is no script
        /// difference to count, and guessing Swedish-vs-English from the text is
        /// a guess we'd rather the model make than one Mila makes wrongly and
        /// silently. Legacy `"he"` values in `liveAI.outputLanguage` therefore
        /// decode to `.auto` (`init`), which is the safe reading.
        var promptName: String {
            switch self {
            case .auto:    return "the same language as the transcript below"
            case .english: return "English"
            case .swedish: return "Swedish"
            }
        }

        var displayName: String {
            switch self {
            case .auto:    return "Auto"
            case .english: return "English"
            case .swedish: return "Swedish"
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         capabilities: SystemCapabilities = .live,
         managed: ManagedSettings = .empty) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.managed = managed
        // Default ON: users who never touched the toggle should get
        // the LLM summary/action-items pane. If their LLM CLI isn't
        // configured, `isLiveAIReady` still gates everything down to
        // a no-op, so this is safe. A managed value wins over both.
        self.storedEnabled = managed.liveAIEnabled ?? (defaults.object(forKey: Keys.enabled) as? Bool) ?? true
        self.storedModel = managed.liveAIModel ?? defaults.string(forKey: Keys.model) ?? Self.defaultModel
        // Migrate pre-1.6.1 persisted values (default was 5s, range 3-20s).
        // 5s windows cut words mid-utterance and made the trailing-window
        // merge stitch together inconsistent segments. Only values below
        // the current slider minimum (15s) are treated as stale — 15 and
        // 20 are legal choices on today's 15-60s slider and must survive
        // a relaunch, so they can't be used as a migration marker.
        let raw = defaults.double(forKey: Keys.chunkSeconds)
        self.chunkSeconds = raw >= 15.0 ? raw : 30.0
        // Default 20s. `double(forKey:)` returns 0 for an unset key, and
        // 0 is also the legitimate "disable the floor" value — so use a
        // sentinel via object(forKey:) to tell "never set" (→ 20) apart
        // from "user explicitly chose 0".
        self.llmMinIntervalSeconds = (defaults.object(forKey: Keys.llmMinInterval) as? Double) ?? 20.0
        // Default ON: users who never touched the toggle get the
        // cleaner-boundary VAD path. Explicit false is preserved.
        self.useVAD = defaults.object(forKey: Keys.useVAD) as? Bool ?? true
        // Default ON: the neural-VAD gate is a strict quality win
        // (drops noise-only utterances that whisper would hallucinate
        // on) and a CPU win (skips whisper on those). Explicit false
        // is preserved for users who turned it off.
        self.useNeuralVAD = defaults.object(forKey: Keys.useNeuralVAD) as? Bool ?? true
        self.backgroundMode = defaults.bool(forKey: Keys.backgroundMode)
        // Default ON — today's behaviour. Explicit false is preserved.
        self.transcribeWhileRecording = defaults.object(forKey: Keys.transcribeWhileRecording) as? Bool ?? true
        self.forceLiveAIOnLowEndHardware = defaults.bool(forKey: Keys.forceLowEnd)
        let sim = defaults.double(forKey: Keys.simThreshold)
        if defaults.bool(forKey: Keys.simThresholdMigrated) {
            self.speakerSimilarityThreshold = sim > 0 ? sim : 0.55
        } else {
            // One-shot migration of the old 0.75 default — too strict for
            // wespeaker on 1-5s VAD utterances; same-speaker cosine sim at
            // that length sits in 0.5-0.7, so 0.75 split every utterance
            // into a new SPEAKER_NN. Treat values >= 0.7 as "old default,
            // migrate" — but only ONCE: the Settings slider legitimately
            // offers up to 0.95, so re-running this on every launch would
            // silently discard a user's chosen threshold. The flag (plus
            // writing the migrated value back) makes later >= 0.7 values
            // stick.
            let migrated = (sim > 0 && sim < 0.7) ? sim : 0.55
            self.speakerSimilarityThreshold = migrated
            defaults.set(migrated, forKey: Keys.simThreshold)
            defaults.set(true, forKey: Keys.simThresholdMigrated)
        }
        // Same migration as `summaryPrompt` below: a nil value (never set) or
        // an exact match of the shipped English default adopts the Swedish one;
        // anything else is a user customisation and is preserved untouched. A
        // pure read — nothing is written back — so it is idempotent.
        let storedPrompt = defaults.string(forKey: Keys.prompt)
        if let stored = storedPrompt, stored != Self.legacyPromptV1 {
            self.prompt = stored
        } else {
            self.prompt = Self.defaultPrompt
        }
        let langRaw = defaults.string(forKey: Keys.outputLanguage) ?? OutputLanguage.auto.rawValue
        self.outputLanguage = OutputLanguage(rawValue: langRaw) ?? .auto
        // Migrate users still on a shipped English default up to the Swedish
        // one (`legacySummaryPromptV1` = the pre-1.8.x concise text, `V2` = the
        // thorough English text that shipped until the Swedish default). A nil
        // value (never set) or an exact match of either adopts the new default;
        // any other value is a user customisation and is preserved as-is —
        // which matters more here than it used to, because the prompt is now
        // the ENTIRE request: overwriting something a user tuned for Obsidian
        // would be destructive in a way appending a paragraph never was.
        // Idempotent: the migration is a pure read (we don't write the default
        // back), so a later prompt revision can migrate the same way.
        let storedSummaryPrompt = defaults.string(forKey: Keys.summaryPrompt)
        if let stored = storedSummaryPrompt,
           stored != Self.legacySummaryPromptV1,
           stored != Self.legacySummaryPromptV2 {
            self.summaryPrompt = stored
        } else {
            self.summaryPrompt = Self.defaultSummaryPrompt
        }
    }

    /// Default model. Currently `claude-sonnet-4-6` — better
    /// summarisation quality than Haiku at modest extra cost. Users
    /// on cursor-agent can override in Settings if their CLI accepts
    /// a different model name.
    static let defaultModel = "claude-sonnet-4-6"

    /// The default Live-AI tick prompt. Swedish, because the model's output
    /// is read by the user in the middle of a meeting and the shipped default
    /// should ask for it in the language the app now ships with. The OUTPUT
    /// FORMAT paragraph stays English: the JSON keys, the `source` enum values
    /// and the `SPEAKER_00` id are protocol with `LiveAISession.parseEnvelope`
    /// / `parseActionItems`, and translating the words around them is safe
    /// while translating those is not.
    ///
    /// Idempotent: we re-send the full growing transcript on every tick and the
    /// model re-emits the FULL list (plus the latest rolling summary) every
    /// time, so the UI always gets a complete snapshot. Dedup happens in Swift
    /// via the `id` field on each item.
    ///
    /// `{{LANGUAGE}}` is substituted with the user's chosen output language at
    /// send time (`PromptTemplate`). If a user removes it from a custom prompt
    /// the LLM falls back to whatever language the transcript itself is in —
    /// fine for matching the conversation, but the user picked a setting for a
    /// reason, so we keep the substitution token in the default text.
    static let defaultPrompt = """
Du är Mila, en live-assistent för möten. Skriv allt på {{LANGUAGE}}.

Du anropas upprepade gånger medan mötet pågår. Varje anrop ger dig mer
transkribering. Ditt svar ERSÄTER hela den panel användaren ser, så du
MÅSTE skicka med HELA det aktuella läget vid varje anrop:
  • HELA listan med åtgärdspunkter — varje punkt du någonsin tagit fram,
    inte bara de nya.
  • HELA den löpande sammanfattningen — skriv om den så att den täcker
    hela samtalet så här långt, inte bara det senaste avsnittet.

Behanda varje svar som om det föregående svaret inte längre finns. Anta
inte att användaren kom ihåg något från tidigare anrop. Upprepa varje
åtgärdspunkt, med sin stabila id, i varje svar. Ser du att en tidigare
punkt var fel, utelämna den helt (användarens panel speglar det). Vill du
uppdatera en punkt, skicka den igen med SAMMA id och ny text. Upprepar
någon sig finns punkten ändå med exakt EN gång.

En åtgärdspunkt är:
- En konkret uppgift någon förbundit sig att göra (med eller utan deadline).
- En uttrycklig instruktion riktad till dig (t.ex. "Mila, lägg till ..."). Märk sådana med source: "voice_command".

UTDATAFORMAT: svara med ENDAST ett JSON-objekt på en enda rad — ingen \
inledning, ingen Markdown, ingen efterföljande text:
{"summary": "...", "items": [{"id": "stable-slug", "text": "...", "speaker": "SPEAKER_00" or null, "timestamp_seconds": 0, "source": "inferred" or "voice_command"}]}

Har anropet precis börjat och det ännu inte finns någon transkribering, \
skicka {"summary": "", "items": []}.
"""

    /// The default one-shot summary prompt. Plain text, meeting-style: this
    /// runs ONCE against the complete transcript after a recording finishes.
    ///
    /// It governs the WHOLE request now. `RecordingSummarizer` used to append
    /// its own English paragraphs to whatever the user wrote — an action-items
    /// contract, a language directive, a labelled calendar block — none of
    /// which could be edited, translated or removed. Those are `{{VARIABLE}}`
    /// slots now: `{{LANGUAGE}}`, `{{EVENT_TITLE}}`, `{{CALENDAR_ATTENDEES}}`,
    /// `{{CALENDAR_NOTES}}`, and the transcript itself via `{{TRANSCRIPT}}`
    /// (absent here, in which case Mila appends it, as it always has).
    ///
    /// Depth deliberately matches the pre-#87 live summary: an overview, the
    /// main topics with their key points, decisions made, and — when the
    /// conversation centres on specific people / projects / items — a per-item
    /// breakdown so each one's situation and next steps are clear.
    static let defaultSummaryPrompt = """
Sammanfatta mötet i transkriptionen nedan. Skriv allt på {{LANGUAGE}}.

Skriv en grundlig sammanfattning åt någon som inte deltog. Täcka:
  • En kort övergripande beskrivning av vad mötet handlade om.
  • De viktigaste ämnena som diskuterades, med huvudpoängerna för varje.
  • De beslut som fattades.
  • När samtalet kretsar kring specifika personer, projekt eller ärenden,
    bryt ner per person/ärende så att läget och nästa steg blir tydliga.

Använd korta stycken eller punktlistor och **fetstil** på viktiga namn och
ämnen så går sammanfattningen att skumma. Var utförlig men upprepa dig
inte. Skriv ingen inledning som "Här kommer sammanfattningen" — börja
direkt med innehållet.

Mötesinbjudan — skriven före mötet, ofta av någon annan. Tomma fält betyder
att ingen inbjudan är kopplad, eller att användaren höll den privat. Använd
inbjudan bara som kontext för namn, stavning och ämnen: sammanfatta den
inte, gör den inte till åtgärdspunkter och rapportera inget från den som
transkriptionen inte nämner.
Titel: {{EVENT_TITLE}}
Inbjudna: {{CALENDAR_ATTENDEES}}
Anteckningar: {{CALENDAR_NOTES}}

Röster som hördes i inspelningen — de namn du gett rösterna, i annat fall
Talare A, Talare B: {{SPEAKERS}}
Den som är inbjuden men inte hörs deltog inte — tillskriv den personen inget.
"""

    /// The pre-1.8.x concise default. Kept verbatim so `init` can migrate a
    /// user still on the old default up to `defaultSummaryPrompt` without
    /// clobbering a genuinely customised prompt. Do not edit — changing it
    /// would break the migration match. (Retire once enough releases have
    /// passed that no one is on the old default.)
    static let legacySummaryPromptV1 = """
You are summarizing a meeting transcript. Output everything in {{LANGUAGE}}.

Read the transcript below and produce a concise summary suitable for
someone who didn't attend the meeting. Cover:
  • What was discussed (the main topics).
  • Any decisions that were made.
  • Any action items or follow-ups that came up.

Keep it short — a few bullet points or a short paragraph is fine. Do
NOT include a preamble like "Here is the summary"; start directly with
the content.
"""

    /// The pre-Swedish English live-tick default, kept verbatim so `init` can
    /// tell "this is the stock prompt" from "the user wrote this" and migrate
    /// only the former. Do not edit — changing it breaks the migration match.
    /// (Retire once enough releases have passed that no one is on it.)
    static let legacyPromptV1 = """
You are Mila, a live meeting assistant. Output everything in {{LANGUAGE}}.

You are called repeatedly as a live meeting unfolds. Each call gives
you additional transcript. Your response REPLACES the entire panel
the user sees, so you MUST output the COMPLETE current state on
every single call:
  • The FULL list of action items — every one you have ever
    identified, not just the new ones.
  • The FULL rolling summary — refresh and rewrite it to cover the
    whole conversation so far, not just the latest chunk.

Treat every response as if the previous response no longer exists.
Do not assume the user retains anything from earlier calls. Repeat
every action item, with its stable id, in every reply. If you
realise an earlier item was wrong, simply omit it (the user's panel
will reflect that). If you want to update an item, re-emit it with
the SAME id and new text. If the speaker repeats themselves, the
item still appears exactly ONCE.

An action item is:
- A concrete task someone committed to do (with or without a deadline).
- An explicit instruction directed at you (e.g. "Mila, add ..." or in Swedish "Mila, lägg till..."). Tag those with source: "voice_command".

OUTPUT FORMAT: respond with ONLY a JSON object on a single line — no \
preamble, no Markdown, no trailing text:
{"summary": "...", "items": [{"id": "stable-slug", "text": "...", "speaker": "SPEAKER_00" or null, "timestamp_seconds": 0, "source": "inferred" or "voice_command"}]}

If the call has just started and there is no transcript yet, output \
{"summary": "", "items": []}.
"""

    /// The pre-Swedish English one-shot summary default, kept verbatim for the
    /// same reason as `legacyPromptV1`. Do not edit.
    static let legacySummaryPromptV2 = """
You are summarizing a meeting transcript. Output everything in {{LANGUAGE}}.

Write a thorough summary for someone who did not attend. Cover:
  • A short overview of what the meeting was about.
  • The main topics discussed, with the key points for each.
  • Any decisions that were made.
  • When the conversation centres on specific people, projects, or items,
    break the summary down per person / topic so each one's situation and
    the next steps for it are clear.

Use short paragraphs or bullet points, and **bold** the key names and
topics so the summary is easy to skim. Be comprehensive but do not repeat
yourself. Do NOT include a preamble like "Here is the summary"; start
directly with the content.
"""


    private enum Keys {
        static let enabled = "liveAI.enabled"
        static let model = "liveAI.model"
        static let chunkSeconds = "liveAI.chunkSeconds"
        static let llmMinInterval = "liveAI.llmMinIntervalSeconds"
        static let useVAD = "liveAI.useVAD"
        static let useNeuralVAD = "liveAI.useNeuralVAD"
        static let backgroundMode = "liveAI.backgroundMode"
        static let transcribeWhileRecording = "liveAI.transcribeWhileRecording"
        static let forceLowEnd = "liveAI.forceOnLowEndHardware"
        static let simThreshold = "liveAI.speakerSimilarityThreshold"
        static let simThresholdMigrated = "liveAI.speakerSimilarityThreshold.migrated"
        static let prompt = "liveAI.prompt"
        static let outputLanguage = "liveAI.outputLanguage"
        static let summaryPrompt = "liveAI.summaryPrompt"
    }
}

/// One action item surfaced by `LiveAISession`. The `id` is chosen by the
/// LLM and is stable across ticks so we can dedupe; `addedAt` is when the
/// item first appeared in our UI (so the list can be sorted newest-first
/// without trusting the LLM's `timestamp_seconds`).
struct ActionItem: Identifiable, Hashable, Codable {
    let id: String
    var text: String
    var speaker: String?
    var timestampSeconds: Double
    var source: Source
    var addedAt: Date

    enum Source: String, Codable {
        case llmInferred = "inferred"
        case voiceCommand = "voice_command"
    }
}
