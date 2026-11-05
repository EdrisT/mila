import XCTest
import Carbon.HIToolbox
@testable import Mila

@MainActor
final class HotkeySettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "HotkeySettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func test_fresh_install_returns_compiled_in_defaults() {
        let settings = HotkeySettings(defaults: defaults)
        let english = settings.binding(for: .dictateEnglish)
        let swedish = settings.binding(for: .dictateSwedish)
        XCTAssertEqual(english.keyCode, UInt32(kVK_ANSI_2))
        XCTAssertEqual(english.modifiers, UInt32(cmdKey))
        XCTAssertEqual(swedish.keyCode, UInt32(kVK_ANSI_3))
        XCTAssertEqual(swedish.modifiers, UInt32(cmdKey))
    }

    func test_set_binding_persists_across_instances() {
        let first = HotkeySettings(defaults: defaults)
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F5),
                                   modifiers: UInt32(cmdKey | shiftKey))
        first.setBinding(custom, for: .dictateEnglish)

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateEnglish), custom)
        XCTAssertEqual(reloaded.binding(for: .dictateSwedish),
                       HotkeyAction.defaults[.dictateSwedish]!,
                       "Swedish binding must not be touched when only English changes")
    }

    /// `HotkeyAction.rawValue` IS the `UserDefaults` key, so renaming
    /// `dictateHebrew` → `dictateSwedish` (Hebrew was replaced by Swedish)
    /// would otherwise silently hand every upgrader their compiled-in ⌘3 back
    /// instead of the combo they chose.
    func test_legacy_hebrew_key_migrates_to_swedish() {
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F7),
                                   modifiers: UInt32(cmdKey | controlKey))
        let data = try! JSONEncoder().encode(custom)
        defaults.set(data, forKey: "hotkey.dictateHebrew")

        let settings = HotkeySettings(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .dictateSwedish), custom)
        XCTAssertNil(defaults.data(forKey: "hotkey.dictateHebrew"),
                     "The retired key must not linger")

        // Idempotent: a second launch of the migrated install keeps the value
        // under the live key and still finds nothing under the old one.
        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateSwedish), custom)
        XCTAssertNil(defaults.data(forKey: "hotkey.dictateHebrew"))
    }

    /// The live key is the one that wins — a binding the user set after the
    /// upgrade must not be overwritten by a stale `hotkey.dictateHebrew`.
    func test_migration_does_not_clobber_a_newer_binding() {
        let legacy = HotkeyBinding(keyCode: UInt32(kVK_F7), modifiers: UInt32(cmdKey))
        let current = HotkeyBinding(keyCode: UInt32(kVK_F8), modifiers: UInt32(cmdKey))
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "hotkey.dictateHebrew")
        defaults.set(try! JSONEncoder().encode(current),
                     forKey: "hotkey.\(HotkeyAction.dictateSwedish.rawValue)")

        let settings = HotkeySettings(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .dictateSwedish), current)
    }

    func test_reset_to_default_clears_persisted_value() {
        let settings = HotkeySettings(defaults: defaults)
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
        settings.setBinding(custom, for: .dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish), custom)

        settings.resetToDefault(.dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish]!)

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish]!)
    }

    func test_display_name_uses_modifier_glyphs_in_canonical_order() {
        let binding = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        XCTAssertEqual(binding.displayName, "⌃⌥⇧⌘2")
    }

    func test_display_name_for_function_keys() {
        let binding = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
        XCTAssertEqual(binding.displayName, "⌘F5")
    }

    func test_codable_round_trip() throws {
        let original = HotkeyBinding(keyCode: 42, modifiers: UInt32(cmdKey | optionKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
