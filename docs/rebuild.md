# Rebuild and reinstall SpeechText

```bash
scripts/rebuild.sh
```

A plain shell script — run it from anywhere; it finds the repository root itself. One command builds the
current source, replaces `/Applications/SpeechText.app`, and starts it.

| Option | Effect |
|---|---|
| *(none)* | Build Release, install, launch |
| `--debug` | Debug configuration instead (backups are kept per configuration) |
| `--release` | Release configuration (the default; undoes an earlier `--debug` on the same line) |
| `--no-launch` | Build and install, leave it stopped |
| `--status` | What is installed, what is running, whether the installed build is HEAD |
| `--list` | The retained previous builds |
| `--rollback [ID]` | Reinstall the previous build, or a named one, and launch it |
| `--remove-legacy` | Move `SpeachText.app` / `VoicePeter.app` to the Trash |
| `--tag X.Y.Z` | Cut a release: version, CHANGELOG, commit, annotated tag |
| `-h`, `--help` | Print the usage lines from the script's header |

The script prints one line per stage and exits non-zero on failure, then ends every
build and rollback — successful or not — with a **SUMMARY** block: what happened, the
version now installed and the one it replaced, the app's path, whether it is running
and from where (a copy running from anywhere else is called out), the signing, and any
pre-rename copy still in `/Applications`. Open the build log only when the summary
points you at one.

## Two things to do once, before the first run (and a third, optional)

**1. Accept the Xcode licence.** Xcode's GUI licence was agreed for an older version
than the one installed, and `xcodebuild` refuses to run until the terminal one is
too. It needs a password, so the script cannot do it:

```bash
sudo xcodebuild -license accept
```

The script checks this first and stops with that instruction rather than producing a
confusing build failure.

**2. Make a code-signing certificate.** Without one the app is signed *ad-hoc*, and
an ad-hoc signature is pinned to the binary's hash: to macOS, every rebuild is a
different application, so the Accessibility grant is dropped and paste-back silently
stops working until you toggle SpeechText off and on in System Settings. A
certificate makes the signature stable, and the grant then survives every rebuild.

If the keychain holds a **Developer ID Application** certificate — the one releases are
signed with (docs/releasing.md) — the script uses it without being asked, ahead of a
`SpeechText Dev` one: a grant made to a local build then carries over to a release
instead of being asked for again. Otherwise, make a self-signed one:

In **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a
Certificate…**:

- Name: `SpeechText Dev`
- Identity Type: *Self Signed Root*
- Certificate Type: **Code Signing**
- leave "Let me override defaults" off, Create, Done

That is all — no need to mark it trusted. Xcode still builds with its usual local
signature; the script then re-signs the finished bundle with this certificate using
`codesign` directly, because Xcode's own manual signing rejects a self-signed
certificate as untrusted. The first time, macOS asks whether `codesign` may use the
key: choose **Always Allow**. Run with `SPT_SIGN_IDENTITY="Other Name"` if you named
yours differently.

**3. Optional: the provisioning profile.** With the Developer ID certificate *and*
`~/.config/speech-text/SpeechText_Developer_ID.provisionprofile` (docs/releasing.md ›
The provisioning profile; `SPT_PROVISIONING_PROFILE` points elsewhere), the build is
signed for the data-protection keychain and keeps the API keys there, as a release does
— the run prints `Signed for the keychain`. The profile is embedded only when its team,
app and certificate match the signing identity and it has not expired, since one that does not match is an app
that never launches; anything else prints why and keeps the keys in UserDefaults.

Whichever way it went, the summary at the end of a run says which you got:

```
  Signing:    stable — Accessibility permission survives rebuilds
  Signing:    ad-hoc — if paste stops working, re-enable SpeechText in ...
```

It reads that from the built bundle's designated requirement rather than from what
it asked for, so it reports what actually happened.

**Why a teamless build carries an extra entitlement.** The app is built with the
hardened runtime, which loads only frameworks signed by the app's own *team* — and
Sparkle, the updater, is a framework. A Developer ID or Apple Development certificate
has a team, and the script re-signs Sparkle with it. An ad-hoc signature or a
self-signed `SpeechText Dev` has none, and macOS refuses Sparkle even when every piece
is signed the same way: the app dies at launch with *"mapping process and mapped file
have different Team IDs"*. So for those two the script adds
`com.apple.security.cs.disable-library-validation` to the local build's signature.
Only here: `scripts/package-release.sh`, which makes what users install, never adds
it.

## Which build is running

Every build is stamped with the commit it came from, and Settings › General › Version
shows it (`--status` prints the same):

```
SpeechText 0.9.0 (build 47 · a18a7d1 · 2026-09-16 14:20)
```

`0.9.0` is the release version — `MARKETING_VERSION` in `project.pbxproj` — and only moves on
`--tag`, which dates the matching CHANGELOG section at the same time. `build 47`
is the commit count, `a18a7d1` the commit — with a trailing `+` when the working
tree had uncommitted changes, which is the whole warning: what ran is not any commit,
so a bug found in it cannot be reproduced from git alone. Clicking the line copies it,
for pasting into an issue.

The stamp is passed on the `xcodebuild` line into `$(SPT_GIT_COMMIT)` /
`$(SPT_BUILD_DATE)` placeholders in `Info.plist`. A plain Xcode ⌘R build defines
neither, so the menu says `0.9.0 (dev)` — which is the honest answer for a build that
was never recorded, not a bug. `--status` compares the installed stamp against HEAD
and says whether they agree.

## Why the app is installed to /Applications rather than run from the build directory

Two grants depend on where the bundle lives. macOS keys Accessibility partly on the
path, and a login item registered from a `build/` directory points at something that
a `git clean` deletes. A fixed install path also makes one check possible that is
otherwise guesswork: after launching, the script asserts that the running process
really is the one under `/Applications/SpeechText.app`. Without that, a stray copy
elsewhere goes on showing the old behaviour while the build log says success.

## Why everything is stopped first

SpeechText registers its global shortcuts through Carbon's `RegisterEventHotKey`,
which is system-wide. A leftover instance keeps its claim on `⌃⇧Q`, so two copies
compete and the dictation lands in whichever one won. The symptom is confusing — the
app "sometimes ignores the hotkey" — and the cause is invisible, because a menu bar
agent has no dock icon to reveal that two are running.

The script stops **every name the app has shipped under** — `SpeechText`,
`SpeachText`, `VoicePeter` — not just the current one. Behind those three process names
are four bundle identifiers (`com.voicepeter.app`, `com.speachtext.app`, then
`com.speechtext.app` and `app.speech-text.SpeechText`, both shipped as `SpeechText`),
each with its own registration, so stopping only the current name leaves exactly the
race this is meant to prevent.

The stop happens **after** a successful build, not before it. A build that fails
therefore leaves the app you were using running and installed; there is nothing to
roll back to.

## The first run replaces a pre-rename install

`/Applications/SpeachText.app` is the app under its misspelled name, and it is a
different bundle identifier. Installing the correctly-spelled one:

- fires the two one-shot migrations (`adoptPreRenameStore`, `adoptPreRenameDefaults`)
  that carry history, shortcuts and presets across — **once**, on the first launch that
  finds them — and the API keys, which `APIKeyStore` moves into the keychain (or, in a
  build without the profile, copies across) from every old domain;
- re-asks for microphone, speech recognition and accessibility, because macOS keys
  those to the bundle identifier;
- registers itself as a login item, since `hasRegisteredLaunchAtLogin` deliberately
  does not migrate.

The old bundle is left in place — it is the working install until the new one has
proved itself, and it holds the grants. Once the new one works, `--remove-legacy`
moves it to the Trash (not `rm -rf`, so it can be fished back out), and the old login
item is worth clearing in System Settings › General › Login Items, or two agents
start at every boot.

The last step, `com.speechtext.app` → `app.speech-text.SpeechText`, kept the name, so it
installs over the same `/Applications/SpeechText.app` and there is no old bundle to
remove — `--remove-legacy` knows only `SpeachText` and `VoicePeter`. It still re-asks for
the three permissions, and a login item registered under the old identifier is worth
clearing in Login Items the same way.

## Backups and rollback

Before each install the outgoing `/Applications/SpeechText.app` is copied to
`build/backups/<config>/<timestamp>/` with the stamp it carried. The last three are
kept (~40 MB each). Only the built bundle is saved, never the source — the source is
in git, and a second source-history mechanism would drift out of step with it.

What this buys you is the case git cannot cover on its own: a change that compiles and
then misbehaves at runtime. `--rollback` puts the last working binary back without
waiting for a rebuild, which matters because this app's failure modes — hotkeys,
microphone, paste-back — only appear when it is actually running.

- **A rebuild with no code change does not consume a slot.** The script compares the
  executable's hash against the newest backup and skips an identical copy. Without
  that, building a few times while debugging something unrelated would quietly push
  the last good version out of a three-deep window, precisely when you need it.
- **A rollback past the keychain move finds no keys.** The first launch of a build
  signed for the keychain moves the API keys out of the preferences; an older build
  reads only the preferences, so it starts with none. Enter them again, or roll
  forward.
- **History survives an older build only from builds that carry the guard.** A build
  with it keeps every History entry it cannot decode — one with a status or a usage
  entry a newer build added — byte for byte and writes it back where it stood, so
  rolling forward shows it again; a `history.json` it cannot read at all is copied aside
  as `history.json.unreadable-<date>` before it is replaced. An entry it *can* decode
  still loses, at its next save, any field added after that build (a newer build's
  usage ledger, say). And a backup — or a ⌘R build of a branch — from before the guard
  still replaces a History it cannot read with its own next dictation, so copy
  `~/Library/Application Support/SpeechText/history.json` first.
- **Rollback swaps the binary only.** The working tree still holds the code that
  produced the bad build. Going back in the source as well is a git operation; the
  script deliberately does not touch your files.

## Cutting a release

```bash
scripts/rebuild.sh --tag 0.10.0
```

Requires a clean working tree. It sets `MARKETING_VERSION` in `project.pbxproj`, moves
everything under CHANGELOG's `## [Unreleased]` into a dated `## [0.10.0]` section,
re-points the compare links, commits with a DCO sign-off and creates the annotated tag
`v0.10.0`. **Nothing is pushed** — it prints the push command and leaves the decision
to you. Run the script again afterwards to install the build that now says `0.10.0`.

Pushing the tag is what publishes: the **Release** workflow signs and notarizes the
build and opens a *draft* GitHub release with the disk image, which a person then
checks and publishes. That needs the Developer ID secrets, the provisioning profile
(`DEVELOPER_ID_PROFILE_BASE64`) and the Sparkle key (`SPARKLE_ED_PRIVATE_KEY`); without
them the workflow fails instead of releasing an unsigned image. See `docs/releasing.md`.

It never writes release notes. What goes under `[Unreleased]` is written after each
merge, from the pull request's *Users will notice*; a generated summary of commit
subjects is not a changelog.

## Reading the result

**Build failed.** The script prints the deduplicated `error:`/`warning:` lines and the
log path. Fix the code and run the script again rather than re-reading the log — a
second run gives you the current errors, and stale diagnostics from a partial build
are a common way to chase a bug that is already fixed.

**Built and launched.** There is no window to look at: the app is `LSUIElement`, so it
lives only in the menu bar. The summary's `Replaced` / `Installed` lines say what
changed; try it with `⌃⇧Q` (inline), `⌃⇧A` (AI) or `⌃⇧W` (record window).

## When something looks wrong after a successful launch

- **Settings shows an older version than you expected.** The stamp does not lie;
  `--status` will say the same. Either the build did not come from HEAD, or something
  other than `/Applications/SpeechText.app` is running — the launch check should have
  caught the second, so suspect the first.
- **The hotkeys do nothing, or paste stops working.** Accessibility permission. If
  the summary said `Signing: ad-hoc`, that is the cause and the certificate above is the
  fix. Otherwise toggle SpeechText off and on in System Settings › Privacy & Security
  › Accessibility. It cannot be fixed from code.
- **Settings look wrong, or a picker is blank.** Provider and model choices live in
  UserDefaults under `app.speech-text.SpeechText` and survive reinstalls, so a stale stored
  value can outlive the code that understood it. Read the choices one by one:

  ```sh
  for k in sttProvider groqModel elevenLabsModel openAISTTModel localSTTModel \
           llmProvider groqLLMModel anthropicModel openAIModel localLLMModel; do
    printf '%s = %s\n' "$k" "$(defaults read app.speech-text.SpeechText "$k" 2>/dev/null || echo '(unset)')"
  done
  ```

  Not a bare `defaults read app.speech-text.SpeechText`: a build without the keychain
  keeps its API keys there, and that prints them in clear text — output that tends to
  end up pasted into an issue. `defaults delete app.speech-text.SpeechText` resets every
  setting; the API keys go with it only in such a build. A build signed for the keychain
  keeps them there, where `defaults` cannot reach: clear a key in Settings › API Keys to
  remove it.
- **Old behaviour persists after a successful launch.** Check `--status`. A second
  copy under a legacy name may still be running and answering the hotkey first.
