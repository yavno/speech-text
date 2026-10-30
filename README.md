# SpeechText

**Talk instead of typing, anywhere on your Mac.**

Press a shortcut, say what you want to write, and the text appears at your cursor: in Slack, Mail, Notion, your code editor, anywhere.

https://github.com/user-attachments/assets/2cf9b269-2961-4f5b-97ae-a36af71dabbd

**[Download for macOS](https://github.com/yavno/speech-text/releases/latest/download/SpeechText.dmg)** · [speech-text.app](https://speech-text.app) · free and open source · macOS 14 or later

---

## Press. Speak. It types.

1. Hold `⌃⇧Q` and speak.
2. Let go.
3. Your words appear where your cursor is.

No window to switch to, no copy and paste.

## Knows where it's going

Hold `⌃⇧A` instead, and AI turns what you said into what you meant. *"So um… tell Anna the demo moved to Friday"* becomes a short message in WhatsApp and a proper email in Gmail. Ask for it in English, as a list, or shorter, and it does that too. There are no modes to pick: just talk.

## Edit by voice

Select some text, hold `⌃⇧E`, and say *"make it shorter"* or *"more friendly"*. The rewrite replaces the selection.

## And more

- **Every dictation, kept.** History has everything you said and what AI made of it, so you can search it, copy it, or retry it.
- **Your words.** Teach it names, product terms and code identifiers, and it spells them right every time.
- **Style your window.** Choose a skin and a color.

## Free on your Mac, or pennies in the cloud

- **On your Mac:** download a speech model in one click. It's free and private, works offline, and handles English, Ukrainian and dozens of other languages. AI rewriting can run on your Mac too.
- **In the cloud:** use your own Groq, OpenAI, ElevenLabs or Anthropic key. A month of heavy dictation costs cents, not a monthly subscription.

SpeechText recommends the right model for your Mac and the languages you speak.

## Private by design

- No account, no telemetry, no server of ours.
- With a model on your Mac, nothing leaves your computer.
- With a cloud provider, your audio goes straight to them, using your key.
- History stays on your Mac, and you decide how long it's kept.

[What is sent where →](docs/privacy.md)

## Install

[Download SpeechText.dmg](https://github.com/yavno/speech-text/releases/latest/download/SpeechText.dmg), drag it to Applications and open it. A short setup takes care of the rest. Or use Homebrew:

```bash
brew install --cask yavno/tap/speechtext
```

SpeechText updates itself. It's in beta, so if something breaks, [let us know](https://github.com/yavno/speech-text/issues). More details are in [docs/install.md](docs/install.md), and [docs/troubleshooting.md](docs/troubleshooting.md) helps when a dictation misbehaves.

## For developers

![CI](https://github.com/yavno/speech-text/actions/workflows/ci.yml/badge.svg)

Open `SpeechText/SpeechText.xcodeproj` in Xcode 27.1 or later and press ⌘R. See [CONTRIBUTING.md](CONTRIBUTING.md), [docs/architecture.md](docs/architecture.md), [docs/third-party.md](docs/third-party.md) the [roadmap](ROADMAP.md) (vote on it at [speech-text.app/roadmap](https://speech-text.app/roadmap)) and the [changelog](CHANGELOG.md).

## License

[GPL-3.0-or-later](LICENSE): free to use, change and share. The name and icon are covered separately ([TRADEMARKS.md](TRADEMARKS.md)), and third-party code and models are credited in [docs/third-party.md](docs/third-party.md).
