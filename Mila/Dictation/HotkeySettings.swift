import Foundation
import Combine
import Carbon.HIToolbox

/// Persists user-customized hotkey bindings (one per `HotkeyAction`) to
/// `UserDefaults` and re-publishes them so the Settings UI can observe edits.
///
/// Bindings are encoded as JSON under the key `hotkey.<action.rawValue>`. If
/// no binding has been saved (fresh install) the action's `defaults` value is
/// used.
@MainActor
final class HotkeySettings: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: HotkeyBinding] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyKeys(in: defaults)
        var initial: [HotkeyAction: HotkeyBinding] = [:]
        for action in HotkeyAction.allCases {
            if let stored = Self.load(action: action, from: defaults) {
                initial[action] = stored
            } else if let fallback = HotkeyAction.defaults[action] {
                initial[action] = fallback
            }
        }
        self.bindings = initial
    }

    func binding(for action: HotkeyAction) -> HotkeyBinding {
        bindings[action] ?? HotkeyAction.defaults[action] ?? HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey)
        )
    }

    /// Atomically update a single action's binding and persist it.
    func setBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        bindings[action] = binding
        Self.save(binding, action: action, into: defaults)
    }

    /// Restore the action to its compiled-in default.
    func resetToDefault(_ action: HotkeyAction) {
        if let fallback = HotkeyAction.defaults[action] {
            setBinding(fallback, for: action)
        }
        defaults.removeObject(forKey: Self.key(action: action))
    }

    // MARK: - Storage

    /// One-off rename of a persisted key, for when a `HotkeyAction` case is
    /// renamed: `rawValue` IS the storage key, so `dictateHebrew` →
    /// `dictateSwedish` would otherwise silently throw away a user's custom
    /// binding and hand them back the compiled-in default.
    ///
    /// Only fills the new key when it is still empty — the new key is the live
    /// one, so a binding the user set after the upgrade wins. The old key is
    /// removed either way, which also makes the migration idempotent.
    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        let oldKey = "hotkey.dictateHebrew"
        let newKey = "hotkey.\(HotkeyAction.dictateSwedish.rawValue)"
        if defaults.data(forKey: newKey) == nil,
           let legacy = defaults.data(forKey: oldKey) {
            defaults.set(legacy, forKey: newKey)
        }
        defaults.removeObject(forKey: oldKey)
    }

    private static func key(action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue)"
    }

    private static func load(action: HotkeyAction, from defaults: UserDefaults) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: key(action: action)) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    private static func save(_ binding: HotkeyBinding,
                             action: HotkeyAction,
                             into defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: key(action: action))
        }
    }
}
