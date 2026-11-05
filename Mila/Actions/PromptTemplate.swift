import Foundation

/// `{{TOKEN}}` substitution for every LLM prompt Mila sends.
///
/// The rule the whole design rests on: **the user's prompt is the prompt.**
/// Mila used to bolt its own paragraphs onto the end of the summary prompt —
/// the action-items contract, a language directive, a labelled calendar block
/// — and each of those was a thing a user could not edit, could not translate,
/// and could not remove. Everything the model is now *told* lives in the
/// editable text; what Mila contributes is only the *values* it substitutes
/// into it, and (as a fallback) the transcript envelope, which is only used
/// when the prompt has no `{{TRANSCRIPT}}` slot of its own.
///
/// Tokens are matched case-sensitively, and a token with no value is left
/// verbatim rather than deleted. Silently dropping `{{CALENDAR_NOTE}}` for a
/// typo would make the prompt look different from what the user typed with no
/// way to see why; a literal `{{CALENDAR_NOTE}}` reaching the model is
/// confusing in exactly one place (the output) and self-explanatory in the
/// other (the settings field, where they can see it).
enum PromptTemplate {
    /// The transcript slot. The one token with a second behaviour attached:
    /// when it is absent, the caller appends the transcript itself (see
    /// `LLMRunner.composedPrompt`), so a prompt written before the token
    /// existed keeps working unchanged.
    static let transcriptToken = "{{TRANSCRIPT}}"

    /// The output-language slot.
    static let languageToken = "{{LANGUAGE}}"

    /// Substitute every `{{key}}` for which `values` has an entry. Keys are
    /// compared without their braces, so callers write `LANGUAGE:` rather
    /// than `"{{LANGUAGE}}"`.
    static func render(_ template: String, values: [String: String]) -> String {
        var output = template
        for (key, value) in values {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    /// Whether the prompt places the transcript itself.
    static func hasTranscriptSlot(_ template: String) -> Bool {
        template.contains(transcriptToken)
    }
}

/// The variable names offered in Settings → AI features. Kept as one list so
/// the settings text, the substitution and the tests cannot drift apart.
enum PromptVariable: String, CaseIterable {
    case language = "LANGUAGE"
    case transcript = "TRANSCRIPT"
    case speakers = "SPEAKERS"
    case date = "DATE"
    case time = "TIME"
    case endTime = "END_TIME"
    case duration = "DURATION"
    case title = "TITLE"
    case eventTitle = "EVENT_TITLE"
    case attendees = "CALENDAR_ATTENDEES"
    case eventNotes = "CALENDAR_NOTES"
    case sourceApp = "SOURCE_APP"

    /// The token as it is typed in a prompt.
    var token: String { "{{\(rawValue)}}" }

    /// One line of the settings help text.
    var blurb: String {
        switch self {
        case .language: return "the output language you picked"
        case .transcript: return "the transcript, with a speaker label on every turn"
        case .speakers: return "every voice that produced audio, in the order they first speak — "
                            + "named if you named it, labelled otherwise (empty if diarization was off)"
        case .date: return "the recording date as YYYY-MM-DD"
        case .time: return "when the recording started, HH:MM"
        case .endTime: return "when it ended, HH:MM"
        case .duration: return "how long it ran, e.g. 47 min"
        case .title: return "the recording's title"
        case .eventTitle: return "the calendar event's own title (empty if none is linked)"
        case .attendees: return "the event's attendees, comma-separated (empty if you kept them private)"
        case .eventNotes: return "the event's notes (empty unless you sent them at sync time)"
        case .sourceApp: return "the app the audio came from — Zoom, Teams, … (empty otherwise)"
        }
    }
}
