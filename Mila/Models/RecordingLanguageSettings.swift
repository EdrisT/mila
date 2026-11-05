import Foundation
import Combine

/// The language a freshly-started voice memo / app-audio recording will be
/// transcribed in. Surfaced in the toolbar as a flag dropdown so users can
/// flip between Swedish and English without digging into Settings.
///
/// Persisted to `UserDefaults` so the choice sticks across launches.
/// The language is always an explicit choice — there is deliberately no
/// auto-detect option. Detection sounds free but isn't: it can only be as good
/// as the model behind it, and the model itself is picked *from* this setting
/// (Swedish → the primary model, English → the multilingual one, and the same
/// split for a remote endpoint's two model ids). "Let the model decide"
/// therefore meant "guess which specialist to ask before knowing the
/// language", which produced worse transcripts than simply saying which
/// language you're about to speak. Legacy `"auto"` values are read as Swedish.
///
/// Hebrew was the pair's other language until 1.9.8 and is deliberately not
/// kept as a case: nothing in the app can offer it any more (no model routing,
/// no picker entry). Rows still on disk with `language == "he"` therefore read
/// as `.swedish` through `fromCode`, exactly like any other unrecognised code.
/// Text-level RTL rendering is unaffected — it never went through this enum
/// (`String.isPredominantlyHebrew`, see `HebrewDetection.swift`).
enum RecordingLanguage: String, CaseIterable, Identifiable, Codable {
    case swedish = "sv"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .swedish: return "Swedish"
        case .english: return "English"
        }
    }

    /// Regional flag emoji used in the toolbar picker (and every menu that
    /// offers a language), so the choice stays scannable at a glance.
    var flagEmoji: String {
        switch self {
        case .swedish: return "🇸🇪"
        case .english: return "🇬🇧"
        }
    }

    /// The opposite-language pair, used by the right-click "Re-transcribe in
    /// the other language" menu item on a recording.
    var other: RecordingLanguage {
        switch self {
        case .swedish: return .english
        case .english: return .swedish
        }
    }

    /// Best-effort decode of an ISO-style language string (`"sv"`, `"sv-SE"`,
    /// `"en"`, `"en-US"`, …). Falls back to Swedish for anything unrecognised:
    /// legacy recordings that pre-date the per-language UX, the retired
    /// `"auto"`, and — since Hebrew was dropped as an option — rows still
    /// carrying `"he"`/`"iw"` on disk.
    static func fromCode(_ code: String) -> RecordingLanguage {
        let normalized = code.lowercased()
        if isVariant(normalized, of: "sv") { return .swedish }
        if isVariant(normalized, of: "en") { return .english }
        return .swedish
    }

    /// Whether `code` is `base` or a regional form of it (`en-US`, `sv_SE`).
    /// A bare `hasPrefix` would also swallow unrelated codes that merely start
    /// with those letters — `"enochian"` must fall back to Swedish like any
    /// other unrecognised value, not pick the English model.
    private static func isVariant(_ code: String, of base: String) -> Bool {
        code == base || code.hasPrefix("\(base)-") || code.hasPrefix("\(base)_")
    }
}

@MainActor
final class RecordingLanguageSettings: ObservableObject {
    @Published private var storedCurrent: RecordingLanguage

    /// Language to use for the next voice memo / app-audio recording.
    ///
    /// When a configuration profile locks it (`ManagedSettings`), every write
    /// is refused before anything is stored, published or persisted. The
    /// toolbar picker is disabled then, so this only catches programmatic
    /// writes.
    var current: RecordingLanguage {
        get { storedCurrent }
        set {
            guard !isManaged(.recordingLanguage), newValue != storedCurrent else { return }
            storedCurrent = newValue
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// The administrator-forced fields, if any. Empty (`ManagedSettings.empty`)
    /// unless `MilaApp` passes the system's managed preferences.
    private let managed: ManagedSettings

    /// Whether a configuration profile locks `field` (see `ManagedSettings`).
    func isManaged(_ field: ManagedField) -> Bool { managed.isManaged(field) }

    private let defaults: UserDefaults
    private static let key = "recording.language"

    init(defaults: UserDefaults = .standard, managed: ManagedSettings = .empty) {
        self.defaults = defaults
        self.managed = managed
        let raw = defaults.string(forKey: Self.key)
        if let forced = managed.recordingLanguage {
            // The user's stored choice stays in `defaults` untouched, so
            // removing the profile brings it back.
            self.storedCurrent = forced
        } else if let raw, let stored = RecordingLanguage(rawValue: raw) {
            self.storedCurrent = stored
        } else {
            // Unrecognised — a fresh install, the retired `"auto"` left in
            // defaults by an older build, or a pre-1.9.8 `"he"` (Hebrew is no
            // longer an option). Fall back to Swedish and rewrite the key:
            // `init` doesn't go through `current`'s setter, so without this the
            // stale value would sit in the plist until the user touched the
            // picker.
            self.storedCurrent = .swedish
            if raw != nil {
                defaults.set(RecordingLanguage.swedish.rawValue, forKey: Self.key)
            }
        }
    }
}
