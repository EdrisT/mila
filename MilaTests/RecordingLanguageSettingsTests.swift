import XCTest
@testable import Mila

@MainActor
final class RecordingLanguageSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "RecordingLanguageSettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func test_fresh_install_defaults_to_swedish() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.current, .swedish)
    }

    func test_assignment_persists_across_instances() {
        let first = RecordingLanguageSettings(defaults: defaults)
        first.current = .english

        let reloaded = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(reloaded.current, .english)
    }

    func test_other_returns_opposite_language() {
        XCTAssertEqual(RecordingLanguage.swedish.other, .english)
        XCTAssertEqual(RecordingLanguage.english.other, .swedish)
    }

    /// We render flag emoji in the toolbar — make sure they're stable so a
    /// future "let's localize the picker" change doesn't silently strip them.
    func test_flag_emojis_are_stable() {
        XCTAssertEqual(RecordingLanguage.swedish.flagEmoji, "🇸🇪")
        XCTAssertEqual(RecordingLanguage.english.flagEmoji, "🇬🇧")
    }

    func test_language_code_decoding_handles_iso_variants() {
        XCTAssertEqual(RecordingLanguage.fromCode("sv"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("SV"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("sv-SE"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("sv_SE"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("en"), .english)
        XCTAssertEqual(RecordingLanguage.fromCode("en-US"), .english)
    }

    /// Hebrew was an option until 1.9.8 and is deliberately gone: a row still
    /// on disk tagged `"he"` (or the very old `"iw"`) decodes like any other
    /// unrecognised code, i.e. the primary language. Pinned here so the
    /// behaviour is a decision on record, not an accident of the switch —
    /// RTL rendering of that row's TEXT is unaffected, because that goes
    /// through `String.isPredominantlyHebrew`, not this enum.
    func test_legacy_hebrew_code_falls_back_to_swedish() {
        XCTAssertEqual(RecordingLanguage.fromCode("he"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("he-IL"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("iw"), .swedish)
    }

    /// Unknown / future language codes fall back to Swedish rather than
    /// crashing — the UI should treat anything unrecognized the same way.
    func test_unknown_language_code_falls_back_to_swedish() {
        XCTAssertEqual(RecordingLanguage.fromCode("fr"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode(""), .swedish)
    }

    /// Only `en` and its regional forms are English. A bare prefix match would
    /// route anything starting with those letters to the English model, against
    /// the documented "unrecognised → Swedish" contract.
    func test_language_code_decoding_does_not_prefix_match_unrelated_codes() {
        XCTAssertEqual(RecordingLanguage.fromCode("en_GB"), .english)
        XCTAssertEqual(RecordingLanguage.fromCode("enochian"), .swedish)
        XCTAssertEqual(RecordingLanguage.fromCode("svenska"), .swedish,
                       "Unrecognised codes land on Swedish either way, but not via a prefix match")
        XCTAssertEqual(RecordingLanguage.fromCode("held"), .swedish)
    }

    /// Auto-detect was removed: the language is always an explicit choice, and
    /// the toolbar picker is `allCases`-driven, so this guards the picker's
    /// contents too.
    func test_only_swedish_and_english_are_offered() {
        XCTAssertEqual(RecordingLanguage.allCases, [.swedish, .english])
        XCTAssertNil(RecordingLanguage(rawValue: "auto"))
        XCTAssertNil(RecordingLanguage(rawValue: "he"),
                     "Hebrew is not a case any more, so nothing can offer it")
    }

    /// A recording tagged by an older build still carries `"auto"`; the UI must
    /// read it as Swedish rather than crashing or showing a blank language.
    func test_legacy_auto_code_reads_as_swedish() {
        XCTAssertEqual(RecordingLanguage.fromCode("auto"), .swedish)
    }

    /// Someone upgrading from a build that had auto-detect — or from one whose
    /// only languages were Hebrew and English — has a retired code sitting in
    /// defaults. It must resolve to Swedish *and* be rewritten, so the stale
    /// value doesn't linger in the plist.
    func test_persisted_retired_language_migrates_to_swedish() {
        for retired in ["auto", "he"] {
            UserDefaults().removePersistentDomain(forName: suite)
            defaults.set(retired, forKey: "recording.language")

            let settings = RecordingLanguageSettings(defaults: defaults)
            XCTAssertEqual(settings.current, .swedish, "\(retired) must resolve to Swedish")
            XCTAssertEqual(defaults.string(forKey: "recording.language"), "sv",
                           "The retired value must be rewritten, not just ignored")
        }
    }

    /// A fresh install has no stored value — don't write one just to migrate
    /// nothing (that would make "never chosen" indistinguishable from "chose
    /// Swedish" for any future first-run logic).
    func test_fresh_install_does_not_write_a_language() {
        _ = RecordingLanguageSettings(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "recording.language"))
    }
}
