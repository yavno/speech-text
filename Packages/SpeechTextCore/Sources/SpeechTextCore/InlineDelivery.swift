// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What an inline dictation's stop does with the engine's final text.
///
/// Nothing is handed to another app while the user speaks: the text is built on the
/// overlay, where the provider can still re-punctuate and re-word it, and the stop pastes
/// it once. There is therefore no ledger to subtract, no correction to make and no draft
/// to replace — which is what used to fill this file, when committed spans were pasted
/// into the target app as they arrived.
///
/// Pure logic. `AppState` asks it where the dictation goes when the user
/// stops, and what to do with the text once the engine has gone idle; it keeps everything
/// that is not a decision: the overlay, the status notices, the Record Window fallback,
/// the LLM call, the paste itself.
public enum InlineDelivery {
    /// The app an inline dictation started in: the one in front at its start — none when
    /// that was SpeechText's own window (the main window, Settings), since the app never
    /// pastes into itself. A dictation that starts there and ends there goes to the Record
    /// Window, never to whichever app an earlier dictation was in.
    public static func origin<App>(front: App?, frontIsSpeechText: Bool) -> App? {
        frontIsSpeechText ? nil : front
    }

    /// Where an inline dictation is pasted: the app in front when the user stopped, in
    /// whatever app that is — not the one it started in. With nothing to paste
    /// before the stop there is nothing spread across two apps, so the only question is
    /// where the one paste goes, and the answer is where the user is.
    ///
    /// Fixed at the stop, never re-read at the paste: an AI rewrite takes seconds, the
    /// user may move again meanwhile, and the app they stopped in is re-activated for the
    /// paste — so the prompt's `<context>` and the destination are always the same app.
    ///
    /// SpeechText's own window in front (Settings, History) is not a destination — the
    /// app never pastes into itself — so the dictation goes where it started, and with no
    /// origin either, to the Record Window.
    ///
    /// Generic so the replay resolves its fake apps through the same rule.
    public static func destination<App>(front: App?, frontIsSpeechText: Bool, origin: App?) -> App? {
        guard let front, !frontIsSpeechText else { return origin }
        return front
    }

    /// Whether a ⌘V may be posted into the app the text is for, once it was asked to the
    /// front and the blind wait is over. A posted ⌘V goes to whatever app is in front, and
    /// that may not be this one: since macOS 14 activation is a request another app can
    /// decline without `activate()` saying so, and an app that quit — during an AI
    /// rewrite, which takes seconds — cannot come forward at all. The paste would land in
    /// whichever app the user is in while the overlay named another.
    ///
    /// Asked by every paste into another app: the stop's (`AppState.deliver`), the Edit
    /// shortcut's rewrite and put-back, and the Record Window's Insert.
    public enum PasteCheck: Equatable, Sendable {
        case paste
        /// The app quit since it was chosen.
        case quit
        /// Another app is in front.
        case notInFront
        /// The app is in front, but a menu bar menu another app opened — Control Center,
        /// Sound, Wi-Fi — has the keyboard: the ⌘V would go to it, and activating the app
        /// does not close it (measured 2026-10-22).
        case menuOpen
        /// Its focused element takes no text (a button, a list).
        case takesNoText
    }

    /// `menuOpen` and `takesText` are asked only of an app in front: each is a round trip
    /// to another process.
    public static func pasteCheck(quit: Bool, inFront: Bool, menuOpen: @autoclosure () -> Bool,
                                  takesText: @autoclosure () -> Bool) -> PasteCheck {
        if quit { return .quit }
        guard inFront else { return .notInFront }
        if menuOpen() { return .menuOpen }
        return takesText() ? .paste : .takesNoText
    }

    /// What a stop's result comes to, once the engine has gone idle.
    public enum StopResult: Equatable, Sendable {
        /// The transcription failed. `partial` is whatever text there was, for the
        /// Record Window; nil or empty when there is nothing to hand over.
        case failed(partial: String?)
        /// Nothing was transcribed.
        case noSpeech
        case paste(String)
        /// AI mode: rewrite `input`, then paste the result.
        case refine(input: String)
    }

    /// The stop's decision, given the engine's final text.
    ///
    /// `recordingText` is the whole recording's text (`spanLayer.text`), which is what is
    /// pasted or rewritten: `finalText` holds only the last segment after a device
    /// restart closed one mid-dictation, and pasting it alone dropped everything said
    /// before. An empty final text keeps its meaning — the span layer is empty too, or
    /// holds ghost text a failed stream took back.
    public static func stopResult(finalText: String, failed: Bool, aiMode: Bool, recordingText: String) -> StopResult {
        let last = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = recordingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = last.isEmpty || whole.isEmpty ? last : whole

        if failed {
            // With no final text, what the recording did show is still worth handing to
            // the Record Window: a stream that committed words and then broke, with an
            // upload that failed too, had those words on the overlay — and, when text was still pasted while the user
            // spoke, in the document.
            return .failed(partial: text.isEmpty ? whole : text)
        }
        guard !text.isEmpty else { return .noSpeech }
        return aiMode ? .refine(input: text) : .paste(text)
    }
}
