# AGENTS.md

Instructions for coding agents working on SpeechText, a macOS menu bar dictation app.

- **`CLAUDE.md`** is the map for every agent, not only Claude: what each file holds, the
  settings keys and their defaults, and the decisions behind the behaviour. Read the
  parts on the files you change before changing them.
- **`CONTRIBUTING.md`** says what is accepted and how a pull request is checked.
- **Skills** are in `.agents/skills/` (the same folder as `.claude/skills/`), one folder
  each. A `SKILL.md` is plain Markdown whose description says when it applies; read the
  one that fits even if your tool does not load skills. Start with `contribute`, which
  covers any change from picking the work to the pull request.

The rules that fail CI or harm the user's data if missed:

- `git commit -s` on every commit (DCO); `git config core.hooksPath .githooks` adds it.
- Tests never touch `UserDefaults` or the keychain: the user's real settings and API keys
  live there.
- Logic goes in `Packages/SpeechTextCore` (no SwiftUI, no engine imports); the app's
  views and services stay in `SpeechText/SpeechText/`.
- No new dependency and no new place user data goes without an agreed issue.
- English in code, comments, commits and pull requests.

Tests: `xcodebuild test -project SpeechText/SpeechText.xcodeproj -scheme SpeechText -destination 'platform=macOS'`.
