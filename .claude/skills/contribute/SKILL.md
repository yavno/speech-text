---
name: contribute
description: The workflow for any change to SpeechText, from picking the work to an open pull request: whether an issue is needed first, where code goes, the checks to run, commits with sign-off, and the pull request description. Use it whenever you are about to change code, tests or docs here, fix a bug, take a GitHub issue, or open, update or describe a pull request, even when the user only says "fix this", "take issue #N" or "make a PR".
---

# Contribute a change

The rules are in `CONTRIBUTING.md` and `AGENTS.md`. This is the order to apply them in.

1. **Is it wanted?** A small fix needs nothing first. A feature, a refactor, a new
   setting, a UI change or anything in the recording pipeline needs an agreed issue;
   `good first issue` and `help wanted` are agreed already. A new dependency or a new
   place user data goes is unlikely to be accepted (`CONTRIBUTING.md`). Without an agreed
   issue, stop and ask.
2. **Set up.** `git config core.hooksPath .githooks`, a branch from fresh `origin/main`.
3. **Read before writing.** The entries in `docs/decisions.md` on what you touch. Many
   things that look like oversights are decisions written down there; keep them or ask.
4. **Put code where it belongs.** Logic in `Packages/SpeechTextCore/Sources/SpeechTextCore/`
   (no `import SwiftUI`, no engine imports, `public` for what the app uses). Views,
   `AppState`, `SpeechEngine`, capture, hotkeys and stores in `SpeechText/SpeechText/`.
   A more specific skill in `.claude/skills/` may apply, such as `add-provider`.
5. **Write like the code around it.** Same naming, comment density and idiom. Touch
   only the lines the change needs; never run a formatter over a file.
6. **Tests.** Never touch `UserDefaults` or the keychain in a test; build values
   directly. Then run:
   ```bash
   xcodebuild test -project SpeechText/SpeechText.xcodeproj -scheme SpeechText -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SPT_WARNINGS_AS_ERRORS=YES
   scripts/lint-swift.sh
   ```
   A new Swift file needs the SPDX header the others have.
7. **Docs in the same change.** `docs/decisions.md` if a decision changed,
   `docs/settings-keys.md` if a settings key did, the guide in `docs/` the change makes
   untrue. Not `CHANGELOG.md`: the maintainer writes that entry after the merge, from the
   pull request's *Users will notice*. Not `AGENTS.md`: a rule there that no longer holds
   is named in the pull request, and the maintainer rewrites it.
8. **Commit.** `git commit -s` on every commit, a message that says what and why. English
   everywhere: code, comments, commits, the pull request.
9. **Pull request.** Fill `.github/PULL_REQUEST_TEMPLATE.md`: what and why with
   `Closes #N`, the checklist, *Users will notice* (what changes for someone using the app,
   or "Nothing"), *Privacy*, *Needs a real-app run* (what only a person
   with the running app can check, or "None"), screenshots for UI.

End with a short summary for the user: what changed, what ran and its result, what was
not run, and anything left for the maintainer to decide.
