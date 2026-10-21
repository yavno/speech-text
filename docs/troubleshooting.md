# Troubleshooting

What to check when SpeechText does not do what you expect. The default shortcuts are used below — ⌃⇧Q to dictate, ⌃⇧A for AI Rewrite, ⌃⇧E to edit a selection, ⌃⇧W for the Record Window; yours may differ (Settings › Dictation).

## The text is not pasted

SpeechText pastes by putting the text on the clipboard and pressing ⌘V for you. macOS only allows that with **Accessibility** access.

1. Open System Settings › Privacy & Security › Accessibility and check that SpeechText is listed and switched on.
2. macOS ties this permission to the app's exact signature, so an update or a rebuild of the app can quietly drop it while the switch still looks on. If SpeechText is on but nothing is pasted, remove it from the list with −, quit and reopen SpeechText, and allow it again when asked. SpeechText asks at every launch while the permission is missing.
3. Settings › Privacy & Data shows whether Accessibility (and the microphone) are allowed right now.

If you dictated and nothing appeared, the text is not lost: it is in History (status menu › History…), with Copy. It is not left on the clipboard — SpeechText puts your own clipboard back a second after the paste.

Some apps turn on macOS's *secure input* while a password field or a terminal with Secure Keyboard Entry is focused. Whether that blocks a pasted ⌘V is not established; the Debug Log records `secureInput=true` with each paste, so include it if you report this.

## The text opened in the Record Window instead

That is deliberate: when SpeechText cannot paste, it shows the text in the Record Window rather than lose it. It happens when:

- Accessibility is not allowed (see above — the permission prompt opens at the same time);
- there is no app to paste into — SpeechText's own window was in front when you stopped, and there was no app the dictation started in to go back to;
- the focused element is plainly not a text field (a button, a list, a table).

Click into a text field before stopping the dictation. The text goes to the app in front when you *stop*, wherever the dictation started.

## A dictation is cancelled as soon as I start it

With **Hold to talk** chosen (Settings › Dictation › Recording), a dictation records only while you hold the shortcut, and a short tap cancels it. Hold the shortcut and talk, or double-tap it to keep recording hands-free until the next press. A “Dictation cancelled” notice says what cancelled it.

## Microphone and Bluetooth headphones

By default the microphone is **Automatic** (Settings › Dictation › Microphone): it uses the system's input, except that a Bluetooth headset's microphone is replaced by the Mac's own. Opening a Bluetooth microphone switches the headset to its call mode — music turns mono and muffled, and the first words can be lost while it switches. The first time this happens, a notice says which microphone recorded, with **Change**.

- To record with the headset anyway, pick it by name in the Microphone menu. A device picked by name is kept even when the system's input moves; if it is not connected, Automatic is used.
- **System Default** always uses whatever macOS has selected as its input.
- With a MacBook's lid closed its own microphone cannot hear, so Automatic leaves the Bluetooth microphone in place.

The caption under the Microphone row says which device will record now and why.

## Apple Dictation: “Couldn't load the … speech model”

The Apple engine (Settings › Speech to text › On this Mac › Apple Dictation) runs on macOS's own on-device recogniser, which needs a speech model for your language. When macOS cannot load it, the dictation stops with:

> Couldn't load the Ukrainian speech model. Add it to Dictation in System Settings › Keyboard.

Add the language under System Settings › Keyboard › Dictation and let macOS download it, or choose another engine — the Speech to text page shows which of your languages each engine knows.

If the message is “Speech Recognition is off for SpeechText”, turn it on in System Settings › Privacy & Security › Speech Recognition. Only the Apple engine needs this permission.

## “No connection — saved to History”

A cloud engine could not be reached. The recording was kept:

- **Retry** on the notice tries again.
- Without a click, SpeechText retries by itself when the network comes back — for dictations saved since the app was opened.
- A retried dictation is put on the **clipboard** with a notice, not pasted, because by then you may be typing somewhere else.
- Older failures can be retried from History. The audio of a failed dictation is kept for 7 days by default (Settings › Privacy & Data).

A model on this Mac or Apple Dictation works without a network.

## A model on this Mac says it is getting ready

After a download, a local speech model shows “Getting ready for your Mac — first time only” while macOS prepares it for this Mac's processor. That can take from a few seconds to several minutes, depending on the model and the Mac — on an M1 Pro, Parakeet v3 took about 30 seconds and Whisper Large v3 Turbo about nine minutes. You can dictate meanwhile; the first dictation simply waits for it.

macOS can throw that preparation away after a system update or when it clears caches, so the first dictation after one may be slow again. SpeechText loads the selected model at launch to keep that wait out of your way.

## A shortcut does nothing

Settings › Dictation lists the four shortcuts. A problem with one is shown under it:

- “… is reserved by another app, so it won't work” — another app registered the same combination first. Choose another shortcut, or change it in that app.
- “… is already the … shortcut” — two of SpeechText's own shortcuts cannot share a combination.
- “macOS also uses …” — an enabled shortcut in System Settings › Keyboard › Keyboard Shortcuts uses it and may take it first.

An app that watches the keyboard by other means cannot be detected; if a shortcut does nothing and no warning shows, try a different combination.

## Where things are kept

| What | Where |
|---|---|
| History | `~/Library/Application Support/SpeechText/history.json`; how long it is kept is set in Settings › Privacy & Data |
| Audio of failed dictations | `~/Library/Application Support/SpeechText/Recordings/` |
| Models on this Mac | `~/Library/Application Support/SpeechText/Models/` |
| Settings | the `app.speech-text.SpeechText` preferences domain |
| API keys | the keychain in a release build (Settings › API Keys to change or remove them) |
| Log | status menu › Debug Log… — the last 1000 entries, in memory only; its menu shows all of them, hides debug lines, or only notices and above or errors and faults. Every entry also goes to the system log under its category (Engine, Paste, Groq, ElevenLabs, …): open Console and search for `app.speech-text.SpeechText`, or run `log stream --info --predicate 'subsystem == "app.speech-text.SpeechText"'` (add `AND category == "Engine"` for one part, or `AND messageType >= error` for failures only) |

## Reporting a problem

1. Settings › General › Version — click the version to copy it (it includes the build and commit).
2. Reproduce the problem, then open status menu › Debug Log… and press **Copy**.
3. Open About SpeechText (in the app menu while a SpeechText window is open) › **Report a problem**, and paste both, with what you did and what you expected.

**Glance over the log before you send it.** It holds the names of the apps you used, whether a window had a title, counts and lengths, timings, and the words of a vendor's error reply — never the words you dictated, selected or had rewritten, nor window titles or Dictionary terms. Still, remove anything you would not post publicly. The same entries also go to the system log that Console shows. Your API keys are not written to it.
