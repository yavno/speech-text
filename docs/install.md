# Installing SpeechText

**SpeechText is a beta.** It does what the README describes and is used daily by its author, and 0.10.0 is its first public release: some settings will move, some rough edges are known, and you may be the first person to hit a given one. It updates itself, so a fix reaches you without a second download. If something breaks, [open an issue](https://github.com/yavno/speech-text/issues).

It needs macOS 14 (Sonoma) or later. API keys are optional: only the cloud engines you choose need one.

## Download it

1. Download [SpeechText.dmg](https://github.com/yavno/speech-text/releases/latest/download/SpeechText.dmg), the latest version, or `SpeechText-<version>.dmg`, the same image, from the [latest release](https://github.com/yavno/speech-text/releases/latest).
2. Open the image, drag **SpeechText** onto **Applications**, then double-click **SpeechText** in the same window: it opens the copy you just dragged. (Double-clicking it without the drag works too: it offers to move itself to Applications.)
3. Because it came from the Internet, macOS checks it before the first launch and asks *"SpeechText is an app downloaded from the Internet. Are you sure you want to open it?"*, naming the developer. Click **Open**. Every release is signed with an Apple Developer ID certificate and notarized by Apple before it is published, and until the project's Apple account becomes an organization, the developer macOS names is Alona Sheiko, whose Apple Developer account signs the releases. If your Mac says something stronger than that (an unidentified developer, or a trip through System Settings › Privacy & Security to open it at all), that download did not pass the check, and we would like to know: please [open an issue](https://github.com/yavno/speech-text/issues).
4. SpeechText lives in the menu bar: look for its ST mark at the top right; *Open SpeechText* there opens its main window. A setup window opens on the first run and walks through the rest: which speech engine to use, an optional AI provider, the keys those need, the permissions below, and a dictation to try before you rely on it.

After that, SpeechText keeps itself up to date: it checks once a day, shows you what changed, and installs the update when you agree. *Check for Updates…* in the menu asks straight away.

To verify the download, each release carries a `.sha256` file beside the versioned image (it names `SpeechText-<version>.dmg`, so check that file):

```bash
shasum -a 256 -c SpeechText-<version>.dmg.sha256
```

## Or with Homebrew

```bash
brew install --cask yavno/tap/speechtext
```

The cask lives in our own tap, [yavno/homebrew-tap](https://github.com/yavno/homebrew-tap), and installs the same signed image. SpeechText still updates itself, so `brew upgrade` leaves it alone unless you pass `--greedy`. `brew uninstall --zap speechtext` also removes its settings, History and downloaded models, but not your API keys, which live in the keychain: delete them in Settings › API Keys first.

## Permissions

The setup window explains each of these as it asks for it, and Settings shows what is still missing.

**Required**

- **Microphone**: to hear you. Nothing works without it.
- **Accessibility**: to paste at the cursor in another app, which is how the text gets where you want it. Without it a dictation opens the Record Window instead, so you can copy the text out by hand. macOS ties this permission to the app's signature, so an update or an OS upgrade can quietly drop it; SpeechText tells you whenever it is missing (on Home, and on any dictation it could not paste, with a button that opens the right System Settings pane).

**Asked only if you use the feature**

- **Speech Recognition**: only for the Apple on-device engine, and only the first time it transcribes something. Pick a cloud engine or a downloaded model and macOS never asks.
- **Automation**: only when returning to the app you dictated into needs an AppleScript nudge, because the ordinary way of bringing it back failed. macOS asks once per app.

SpeechText runs as a menu bar agent with a Dock icon, so its windows can be found again once something covers them; Settings › General can show the icon only while one of its windows is open, or never.

## Build it yourself

You need Xcode 27.1 or later, which runs on macOS 26.6 or later: the project builds in the Swift 6 language mode with Swift 6.4 tools. The app it builds runs on macOS 14 or later.

```bash
git clone https://github.com/yavno/speech-text.git
cd speech-text
open SpeechText/SpeechText.xcodeproj
```

Then press `Cmd+R` in Xcode. A build from Xcode has no updater and is not signed for distribution: see [development.md](development.md), and [releasing.md](releasing.md) for how a release is signed, notarized and published.
