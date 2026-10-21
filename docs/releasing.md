# Releasing

A release is a disk image that opens without a Gatekeeper warning: the app inside is
signed with a **Developer ID** certificate, built with the hardened runtime,
**notarized** by Apple and stapled, and so is the image around it. Nothing less
installs cleanly — since macOS Sequoia an unnotarized app can only be opened through
System Settings › Privacy & Security › Open Anyway, and Homebrew no longer accepts
casks that fail Gatekeeper.

The pipeline is `scripts/package-release.sh`, run by `.github/workflows/release.yml`
when a version tag is pushed. The certificate and notary credentials live only in
repository secrets (or your keychain); the tracked project keeps its empty
`DEVELOPMENT_TEAM`.

## Before the first public release: whose team signs it

The signature names a team, and **that team becomes part of the app's identity**.
macOS keys the Accessibility, microphone and speech-recognition grants to the code
signature's designated requirement, which includes the team ID. Moving to a different
team later re-asks every user for all of them — the same cost each rename of this app
has had. Pick the team that should own SpeechText for the long run before the first
image reaches anyone. The bundle identifier is in the same requirement, which is why it
became `app.speech-text.SpeechText` (the project's domain, reversed) before the first
release rather than after it.

The team's name is what users see in the installer's and System Settings' "developer"
line, and the account holder is the one Apple holds responsible for what is signed.

### The decision, taken 2026-09-22

**The first release is signed by an individual Apple Developer account**, with a
migration to an organization account planned later. The certificate is
*Developer ID Application: Alona Sheiko (7F9975AM6N)*, and that name is public: macOS
shows it in the *Background Items Added* notice when the app registers itself as a login
item, in System Settings › General › Login Items, and in any signature check. Confirmed
on 2026-10-15, before the first public release, with the account holder's consent; an
organization account would put the company's legal name there instead and keep the team
ID.

That is only safe because of what the migration does *not* change. Apple's path from an
individual membership to an organization keeps the same team, so the team ID — and with
it the designated requirement every permission grant is keyed to — survives the move.
This was checked by the account holder before the decision was made, not assumed from
the general rule above.

Two consequences follow, and both matter more than they look:

- **Re-confirm the team ID at migration time**, against the certificate rather than
  against the account page: `codesign -dvvv /Applications/SpeechText.app` names it in
  the authority line, and it must read the same before and after. If it ever differs,
  the release that follows re-asks every existing user for microphone, speech
  recognition and Accessibility, and the only honest response is to say so in the
  release notes rather than let it look like a fault.
- **The account holder's own name is what users see** in the installer and in System
  Settings' developer line until the migration happens.

**The repository will be made public.** Two things had to happen first; both are done:

1. Done: the history rewrite that removes unpublished material (2026-10-15, see
   docs/development.md › History rewrite). Before it, `git log -p` reached every deleted
   blob, and making the repository public would have published them.
2. Done: the continuous-integration rework. Every `runs-on` in `ci.yml`, and
   the pull-request run in `release.yml`, is keyed on the repository's visibility, so once
   it is public a pull request runs on a GitHub-hosted machine, never on the
   organisation's self-hosted Mac. That hosted half has never run, so the first pull
   request after the flip is watched job by job (docs/development.md › The first run
   after going public).

## One-time setup

Everything here is done by someone with the right role on the Apple Developer account.

### 1. The Developer ID Application certificate

Only the **Account Holder** can create one.

1. On the Mac that will hold the private key: Xcode › Settings › Accounts › select the
   team › Manage Certificates… › **+** › *Developer ID Application*. (Or create a
   certificate signing request in Keychain Access and upload it at
   developer.apple.com › Certificates, IDs & Profiles › Certificates › **+**.)
2. In Keychain Access, find *Developer ID Application: … (TEAMID)*, expand it so the
   private key shows, select both, and **Export 2 items…** as a `.p12` with a strong
   password.

The `.p12` is the key to publishing software under that name. Keep it out of the
repository, chat and cloud folders; it goes into GitHub secrets and a password manager.

### 2. Credentials for the notary service

Prefer an **App Store Connect API key**: it is not anyone's password, it can be revoked
on its own, and it can be limited to the *Developer* role.

- App Store Connect › Users and Access › Integrations › App Store Connect API ›
  generate a key with the *Developer* role. Download the `.p8` (it can be downloaded
  only once) and note the **Key ID** and **Issuer ID**.

If the account offers no API keys, use an **app-specific password** instead:
account.apple.com › Sign-In and Security › App-Specific Passwords, together with the
Apple ID and the team ID.

### 3. The update-signing key

SpeechText updates itself with [Sparkle](https://sparkle-project.org): the app reads an
**appcast** — an XML feed published as an asset of each release — and installs what it
finds there. What makes that download trustworthy is not Apple's certificate but an
**EdDSA key pair of our own**, and the two are deliberately independent: if the app is
ever signed by a different Apple team (a transfer to another account — converting this
one to an organization keeps its team ID, see above), an update signed with the same
EdDSA key still installs.

Generate it once, on the maintainer's Mac. The private half stays in that Mac's Keychain:

```bash
scripts/make-appcast.sh --fetch-tools    # downloads Sparkle's tools into build/tools/
build/tools/sparkle-2.10.0/bin/generate_keys
```

It prints the **public** key. Put it in `SpeechText/SpeechText/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>…the printed key…</string>
```

Until that key is there the app simply has no updater: no menu item, no settings row,
nothing started at launch — and `scripts/package-release.sh` refuses to build a
distributable image at all, because an app that cannot be updated is not one to hand out.

A build from Xcode (⌘R) has no updater either, key or no key: it carries no commit and
build number 1, so it is older than every release, and every Sparkle setting lives in the
app's *own* defaults domain — which a ⌘R build shares with the copy in `/Applications`.
Updates are exercised from a `scripts/rebuild.sh` install.

The private half never goes in the repository. Export it for the CI secret and for a
password manager, then delete the file:

```bash
build/tools/sparkle-2.10.0/bin/generate_keys -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
rm sparkle-private-key.txt
```

Whoever holds this key can publish an update to every installed copy of SpeechText.
Losing it is survivable only the hard way: a new key means a new `SUPublicEDKey`, which
existing installs will not accept — everyone would have to download the next version by
hand. Keep a copy somewhere safe, and keep it out of everything else.

### 4. Repository secrets

```bash
gh secret set DEVELOPER_ID_P12_BASE64   < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD             # prompts for the value

# API key:
gh secret set NOTARY_KEY_P8_BASE64      < <(base64 -i AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID

# …or an Apple ID:
gh secret set NOTARY_APPLE_ID
gh secret set NOTARY_APP_PASSWORD
gh secret set NOTARY_TEAM_ID

# The provisioning profile (section 5):
gh secret set DEVELOPER_ID_PROFILE_BASE64 < <(base64 -i ~/.config/speech-text/SpeechText_Developer_ID.provisionprofile)
```

### 5. The provisioning profile

The API keys live in the data-protection keychain (docs/development.md › API keys), and
macOS lets an app use it only when a provisioning profile authorises the app's keychain
group. A Developer ID app can carry one:

1. developer.apple.com › Certificates, IDs & Profiles › Identifiers › **+** › App IDs ›
   App: description `SpeechText`, platform macOS, explicit bundle ID
   `app.speech-text.SpeechText`. No capability needs switching on — the profile
   authorises `TEAMID.*` keychain groups by default.
2. Profiles › **+** › Distribution › **Developer ID**, that App ID, the *Developer ID
   Application* certificate from section 1; name it `SpeechText Developer ID`.
3. Save it as `~/.config/speech-text/SpeechText_Developer_ID.provisionprofile`, where
   `rebuild.sh` and a local `package-release.sh` look for it (`SPT_PROVISIONING_PROFILE`
   overrides the path), and set the secret above for the release workflow.

The profile lists the certificates it authorises. A new Developer ID certificate
therefore needs the profile regenerated with it too, or the next image is refused by
`package-release.sh` — which checks team, app and certificate before it embeds anything,
because a profile that does not match is an app that never launches (and an expired
one is refused the same way). The profile issued
on 2026-09-28 expires in 2044.

## Cutting a release

Before the tag, run `scripts/check-vendor-models.sh` on the commit being tagged
([vendor watch](vendor-watch.md)). It must exit **0**:

- **No catalogue model may be one the vendor no longer serves while it is in any state
  but `deprecated` or `retired`.** Such a model fails every dictation or rewrite that
  uses it. Mark it deprecated with its replacement, so that this release moves its users
  off it.
- Every vendor must have been checked. Exit 3 means a key was missing or a vendor did not
  answer, and that is not an all-clear.
- A shutdown the vendor's API announces for a `current` model does not block the tag. It
  is the warning to deprecate the model in this release or the next, before that date.
- A `retired` model past its six months is removed in this release.

The lifecycle states (`current`, `superseded`, `deprecated`, `retired`) are being added to
the catalogues by the model-lifecycle work. Until they land, every model exports as
`current`, so any model the vendor no longer serves fails the rule. If this paragraph
reaches `main` first, whichever change merges second connects `CatalogueExport.lifecycle`
to the descriptors.

1. Write what changed under `## [Unreleased]` in `CHANGELOG.md` as the work lands —
   that section becomes the release notes.
2. `scripts/rebuild.sh --tag X.Y.Z` sets the version, dates the
   CHANGELOG section, commits and tags `vX.Y.Z`. Nothing is pushed.
3. `git push && git push origin vX.Y.Z`.
4. The **Release** workflow checks the tag against the project version, signs,
   notarizes (a few minutes) and writes the appcast and the release notes in its
   *Package* job; a separate *Draft release* job, the only one that may write to the
   repository, then opens a **draft** release with `SpeechText-X.Y.Z.dmg`, its `.sha256`
   and `appcast.xml`.
5. Download the image and install it on a Mac — or a fresh user account — that has
   never run SpeechText: it should open without any Gatekeeper dialog, show the drag
   window (the app, the arrow, Applications), and on first launch from Applications open
   the setup window — not permission alerts. Opened straight from the image instead, it should offer to move
   itself to Applications. A fresh user account is the clean test. On a Mac that has run
   SpeechText, first remove the keys in Settings › API Keys — a signed build keeps them in
   the keychain, out of `defaults`' reach, and a stored key makes setup take the install
   for an old one — then `defaults delete app.speech-text.SpeechText`, which also clears
   `onboardingCompleted` (left set, it keeps setup from opening at all). History and
   downloaded models stay.
   Check the image and the installed app with the commands in
   [Checking a signed build](#checking-a-signed-build). Then publish the draft.
6. Check that the release it replaces can reach it: on a Mac running the *previous*
   version, SpeechText › Check for Updates… should offer this one, and installing it
   should leave the app running the new version with its permissions intact. The real
   feed answers only once the draft is published on a public repository; before that,
   run the same check against a [test feed](#checking-an-update-before-publishing).

A tag pushed before the secrets exist fails the workflow instead of releasing an
unsigned image.

## A signed build without a tag

The Release workflow can also be started by hand, which signs and notarizes a build of
any branch without cutting a release:

```bash
gh workflow run release.yml --ref main
gh run watch                                   # pick the run
gh run download <run-id> --dir build/ci        # SpeechText-<sha>/: the .dmg, .sha256, build.log
```

It runs on the self-hosted Mac with the repository secrets, exactly as a tag does, up to
and including the image. What a tag adds is skipped: the version check, the release
notes, the appcast and the *Draft release* job. The image is kept as the run's artifact for
14 days (for a tag the artifact also carries `appcast.xml` and `notes.md`, which the
*Draft release* job downloads). This is the way to try the pipeline, or to get a newer
notarized build for an [update test](#checking-an-update-before-publishing), without a tag that would then have
to be deleted.

One difference to watch: the guard that refuses to release unsigned applies to tags
only. A manual run with no certificate in the secrets builds and uploads
`SpeechText-X.Y.Z-unsigned.dmg` and succeeds, so read the file name before trusting it.

## Checking a signed build

`scripts/package-release.sh` runs the two `spctl` checks at the end (it staples, but does
not run `stapler validate`); to check an image yourself (one from
a draft release or a manual run), or the app it installed:

```bash
xcrun stapler validate SpeechText-X.Y.Z.dmg
spctl --assess --type open --context context:primary-signature -vv SpeechText-X.Y.Z.dmg
spctl --assess --type execute -vv /Applications/SpeechText.app
```

Both `spctl` lines should say `accepted`, `source=Notarized Developer ID` and the
certificate's `origin=`. The flags matter: a bare `spctl -a` assesses as `--type
execute`, which only fits an app bundle, so on a `.dmg` it always answers `rejected (the
code is valid but does not seem to be an app)` — even for an image that is correctly
notarized. The image needs `--type open --context context:primary-signature`.

An app installed by `scripts/rebuild.sh` answers `source=Unnotarized Developer ID`. That
is expected: the script signs with the Developer ID certificate when the keychain has
one, but never sends anything to Apple. It says nothing about the release pipeline; only
a copy installed from a release image should read `Notarized`.

## Checking an update before publishing

While the repository is private, or before the draft is published, the real feed
(`…/releases/latest/download/appcast.xml`) answers 404, so an installed copy cannot see
the new version there. Sparkle reads `SUFeedURL` from the app's defaults before its
`Info.plist`, which lets one installed copy be pointed at a feed served from this Mac.
This is how the update from 0.9.0 to the build after it was checked on 2026-09-24.

1. Install the *older* notarized build from its image (not with `rebuild.sh`).
2. Put the *newer* notarized image — from a [manual run](#a-signed-build-without-a-tag)
   — alone in a folder, and write a feed for it, signed with the Sparkle key in this
   Mac's Keychain:

   ```bash
   scripts/make-appcast.sh --fetch-tools
   mkdir -p /tmp/feed && cp build/ci/SpeechText-*/SpeechText-*.dmg /tmp/feed/
   build/tools/sparkle-2.10.0/bin/generate_appcast --download-url-prefix http://localhost:8000/ /tmp/feed
   ```

   `generate_appcast` directly, not `make-appcast.sh`: the script writes the GitHub
   release URLs into the feed. Check that the feed's `sparkle:version` is higher than the
   installed build and that the item has a `sparkle:edSignature`.
3. Serve the folder, on this Mac only:

   ```bash
   cd /tmp/feed && python3 -m http.server --bind 127.0.0.1 8000
   ```

4. Point the installed copy at it, then quit SpeechText and open it again — Sparkle reads
   the setting at launch:

   ```bash
   defaults write app.speech-text.SpeechText SUFeedURL http://localhost:8000/appcast.xml
   ```

5. SpeechText › Check for Updates… should offer the new build; Install and Relaunch
   should leave `/Applications/SpeechText.app` running it, still `Notarized Developer ID`,
   with its permissions intact. The server's log shows the feed and the image being
   fetched.
6. **Always** remove the setting afterwards. Otherwise that copy keeps reading the test
   feed for good and never sees a real release:

   ```bash
   defaults delete app.speech-text.SpeechText SUFeedURL
   ```

### The update windows themselves

The same override checks Sparkle's windows rather than an install (an alert opened
behind other apps, and its modal session disabled the whole status menu, Quit included).
Use a `rebuild.sh` install — a ⌘R build starts no updater and has no Check for Updates…
— quit and reopen SpeechText after every `defaults write`, and delete `SUFeedURL` at the
end as in step 6.

- **An unreachable feed** — nothing listens on port 9:

  ```bash
  defaults write app.speech-text.SpeechText SUFeedURL http://127.0.0.1:9/appcast.xml
  ```

  With TextEdit in front and Settings closed, Check for Updates… shows "Update Error!"
  *over* TextEdit, with a Dock icon while it is open; after Cancel the status menu works
  and Quit is enabled. The Debug Log (Update) says `modal alert ordered front`. Again
  with Settings open behind TextEdit: the Dock icon is already there, and Sparkle does
  not activate the app by itself.
- **A newer version** — a feed with one item whose `sparkle:version` is above the
  menu's build number (equal to it for "You're up to date!"). The signature can be
  fake: the window appears before anything is verified, so never press Install Update.

  ```bash
  mkdir -p /tmp/feed && cat > /tmp/feed/appcast.xml <<'EOF'
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <item>
        <title>9.9.9</title>
        <sparkle:version>9999</sparkle:version>
        <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
        <enclosure url="http://127.0.0.1:8000/SpeechText.dmg" length="1"
                   type="application/octet-stream" sparkle:edSignature="AAAA"/>
      </item>
    </channel>
  </rss>
  EOF
  cd /tmp/feed && python3 -m http.server --bind 127.0.0.1 8000
  ```

  "A new version of SpeechText is available!" opens over the app in front; the Debug Log
  says `update 9.9.9 window ordered front`.
- **A scheduled check that fails** — the unreachable feed, automatic checks on, and the
  last check moved into the past:

  ```bash
  defaults write app.speech-text.SpeechText SULastCheckTime -date "2020-01-01 00:00:00 +0000"
  ```

  Reopened, the app shows nothing and the menu works; the error is only in
  `log show --last 5m --predicate 'subsystem BEGINSWITH "org.sparkle-project"'`.

## How an installed copy learns about a new version

Every release carries `appcast.xml`, and the app reads it at
`…/releases/latest/download/appcast.xml` — a URL GitHub answers with the asset of
whatever release is currently the latest *published* one. So a draft release is invisible
to installed copies, and publishing the draft is the moment the update goes out. Sparkle
checks once a day; the menu item checks now.

The feed holds one item: the release being cut. Sparkle installs the best item it finds,
so one is enough, and it means a release depends on nothing from the release before it —
no archive of old disk images, no re-signing. The consequence to know about is that the
"what's new" text in the update window covers that version alone; the full history stays
in `CHANGELOG.md`, which the window links to.

A release taken back — unpublished or deleted — stops being offered: the `latest` URL
answers with the release before it again. Copies that already updated stay where they
are, so a bad version is pulled from everyone who has not updated yet, and fixed for the
rest by the next release.

## Building a release locally

```bash
xcrun notarytool store-credentials speech-text-notary    # once; prompts for the credentials

SPT_DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
SPT_NOTARY_PROFILE=speech-text-notary \
scripts/package-release.sh
```

Run it without `SPT_DEVELOPER_ID` to exercise the packaging with no certificate at
all: it builds `SpeechText-X.Y.Z-unsigned.dmg`, signed ad-hoc and labelled as not for
distribution — and it only exercises the packaging: the app in it does not start,
because an ad-hoc signature has no team and the hardened runtime then refuses the
Sparkle framework (docs/rebuild.md explains; `scripts/rebuild.sh` is how to run a local
build). `--from-app PATH` packages an app that is already built, and `--out DIR` puts the image
somewhere other than `build/release` (the workflow uses it). [Checking a signed
build](#checking-a-signed-build) has the commands that verify the result.

## The disk image window

What a user sees on opening the image — the app on the left, a dotted arrow, the
Applications folder on the right, on a white card in the setup window's green glass rim,
under the title "One drag and you're set" and above a line saying setup starts once SpeechText is
opened from Applications — is a background drawn by `scripts/dmg/background.swift` and a Finder layout
(`.DS_Store`) written by [dmgbuild](https://github.com/dmgbuild/dmgbuild) from
`scripts/dmg/dmgbuild-settings.py`. dmgbuild writes the layout itself rather than
scripting Finder, which would need an Automation grant and someone at the screen — a tag
builds on a runner that has neither.

- **A build-time tool, not a dependency of the app.** It is installed from PyPI into a
  virtual environment under the job's temporary folder, from `scripts/dmg/requirements.txt`,
  pinned by hash (`--require-hashes`): the job has the signing keychain unlocked. It needs
  Python 3.10+ — `SPT_PYTHON`, else the first new-enough `python3` / `python3.1x` on
  PATH; the Command Line Tools' `python3` is 3.9 and is skipped.
- **1.6.7 or later, because of macOS 26.** Up to 1.6.5 dmgbuild wrote a `pBBk` bookmark
  to the background beside the classic alias. Finder on macOS 26 follows the bookmark,
  cannot resolve it on the compressed read-only image, and draws a plain white window —
  the picture is on the image, and nothing says it is missing. 1.6.7 writes the alias
  alone, which Finder resolves.
- **Finder decides how much shows.** Finder's path bar and status bar (a global setting
  that wins over the image's) each cover 28 points of the window's bottom. The window is
  one bar taller than the card and its rim, so the whole rim shows with the path bar
  on; with no bar the rim is thicker at the bottom, and with both its lower edge goes
  under the second. The picture is taller than the window.
- **Finder decides the names' colour** — black in light mode, white in dark. On the
  white card the names read in light mode only; in dark mode they fade into it. That
  was chosen over a mid-tone behind the names: the icons say what they are without
  them. `background.swift` measures the rendered luminance under both names and fails
  the build if black would not read.
- **The aura is SetupAura's, frozen.** `background.swift` renders with SwiftUI and
  copies the setup's blobs, gradient and blur at one moment; Finder shows a background
  as a still picture, so nothing in it can move.
- **The window's size and the icons' centres live in two files** that have to agree:
  `background.swift` (`WINDOW`, `APP_CENTER`, `APPS_CENTER`) and `dmgbuild-settings.py`.

## When notarization fails

The script prints Apple's log for the rejected submission. The usual causes:

- **"The executable does not have the hardened runtime enabled"** — something nested
  was signed without `--options runtime`.
- **"The signature does not include a secure timestamp"** — `codesign` ran without
  network access to Apple's timestamp server.
- **get-task-allow** — a Debug build was packaged. The script refuses this before
  submitting.
- **A new protected resource** — a feature that uses one needs its entitlement in
  `SpeechText.entitlements` (see [development.md](development.md#hardened-runtime)),
  or it is refused at runtime rather than at notarization.
