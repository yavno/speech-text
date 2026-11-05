---
name: add-setting
description: Add or change a user setting in SpeechText — a new UserDefaults key, its default, whether it survives a rename (SettingsKeys.portable), its control in Settings and its row in docs/settings-keys.md. Use it whenever a change adds a toggle, picker, option or preference, renames or retires a settings key, or changes a default, even if the user only says "make it configurable" or "add an option for…".
---

# Add a setting

A setting is a promise kept across updates and renames, and the user's real settings
live in the same defaults domain the app reads. Follow the `contribute` skill for the
workflow; a new setting needs an agreed issue first. Then:

1. **Name.** Check whether macOS or the field already has a name for the thing
   (`AGENTS.md` › Naming). The key is camelCase and says what it holds.
2. **Key.** A `public static let` in `SettingsKeys` (`Settings.swift`, SpeechTextCore),
   beside the keys it belongs with, with a doc comment saying what it holds when that
   is not obvious.
3. **Default.** Written where it is read (`@AppStorage(SettingsKeys.x) private var x = …`
   in the app, `UserDefaults` reads in a configuration snapshot). Every reader uses the
   same default; with more than one reader, keep it in one constant.
4. **Survives a rename?** A choice the user made goes in `SettingsKeys.portable`, and in
   the literal set `CatalogueTests` pins. A fact about this Mac (a download, a marker,
   a one-shot migration done) stays out. API keys never go in it.
5. **Control.** In the Settings page it belongs to (`SettingsView.swift`,
   `SettingsEngines.swift`), with the words macOS uses in its own windows, American
   spelling. If setup asks the same thing, both read and write the same key.
6. **Logic.** What the setting changes is decided by a pure function in SpeechTextCore
   that takes the value as a parameter, so a test can call it without `UserDefaults`.
7. **Changing or retiring a key.** Never reuse a key for a different meaning. Move the
   old value once at launch (the `migrate…IfNeeded` functions are the pattern) and say
   in its `docs/settings-keys.md` row when the old key is read and when it is deleted.
8. **Docs.** A row in `docs/settings-keys.md` (key, purpose, default), and its
   entry in `docs/decisions.md` if a decision changed. The new control goes under
   *Users will notice* in the pull request; `CHANGELOG.md` is written after the merge.

Tests: the decision function's cases and the `portable` set. In *Needs a real-app run*,
say what to check by hand: the control, and that the value survives a relaunch.
