// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two shortcuts that start an inline dictation. The Record Window's shortcut is not
/// one of them: it opens a panel, and holding it means nothing.
public enum DictationHotkey: Equatable, Sendable {
    case inline
    case ai

    var isAI: Bool { self == .ai }
}

/// What one press or release of a dictation shortcut does.
public enum DictationHotkeyAction: Equatable, Sendable {
    case start(ai: Bool)
    /// The recording goes on in the other mode: what is said is the same dictation, only
    /// what happens to it at the stop changes.
    case switchTo(ai: Bool)
    case stop
    case cancel(DictationCancelReason)
    /// A double tap with hold-to-talk on: the dictation carries on with no key held, and
    /// a later press stops it as the table says. Nothing to perform — it is the cancel
    /// that does not happen.
    case lock
    case ignore
}

/// Why a dictation was cancelled — what the notice says. No cancel is silent: a
/// press that lands on the rewrite a moment after the stop throws the dictation away, and
/// with nothing on screen the user could not tell a cancel from a paste that failed.
public enum DictationCancelReason: Equatable, Sendable {
    /// A dictation shortcut pressed while the microphone was opening, or while the
    /// recording was being transcribed or rewritten.
    case shortcut
    /// Hold to talk: a lone tap, or a tap followed by the other shortcut.
    case tap
    /// Hold to talk: the shortcut let go before the microphone opened.
    case releasedEarly
    case escape
    /// The overlay's ✕.
    case closeButton
    /// The menu's recording item.
    case menu

    /// The notice's title and detail. `savedInHistory`: the dictation was already
    /// transcribed, and History holds it — so a cancel during the AI rewrite loses
    /// nothing the user cannot get back. The detail fits the notice's two lines.
    public func notice(savedInHistory: Bool) -> (title: String, detail: String) {
        switch self {
        case .tap:
            return ("Dictation canceled", "A quick tap cancels. Hold the shortcut while you speak, or double-tap to record hands-free.")
        case .releasedEarly:
            return ("Dictation canceled", "The shortcut was let go before the microphone opened. Hold it until the overlay listens.")
        case .shortcut, .escape, .closeButton, .menu:
            return ("Dictation canceled", savedInHistory
                    ? "Nothing was pasted. The dictation is saved in History."
                    : "Nothing was pasted.")
        }
    }
}

/// Turns presses and releases of the two dictation shortcuts into actions.
///
/// A press follows one table, the held dictation below aside. Idle, it starts a dictation in its own mode.
/// During one, the shortcut of the mode it is in stops it and the other shortcut switches
/// it over — so a dictation begun as plain text can still be sent through the AI, and the
/// other way round. Once the audio is closed (transcribing, rewriting) either shortcut
/// cancels, as it always has: there is nothing left to switch.
///
/// Releases matter only with `holdToTalk`. The press that started the dictation *owns* it,
/// and letting go of that shortcut stops it. A release within `tapThreshold` is a tap, not
/// a hold: nothing was said in it, and a lone tap that latched the recording on left an
/// overlay listening that the user had not asked for — so it cancels. Not at once,
/// though: a second press of the same shortcut within `doubleTapWindow` of that release
/// makes it a double tap, which *is* asking, and locks the dictation on hands-free
/// (`.lock`). The first tap never waits — the microphone is already open — and is read
/// retroactively, as `EditHotkeyGesture` reads its own: `AppState` calls
/// `tapWindowExpired` when the window runs out, and that is the cancel. The other
/// shortcut pressed inside the window cancels too; it is not the second half of anything.
///
/// While the owner is held, the other shortcut cannot stop the dictation — only the
/// owner's release does — so each of its presses flips the mode instead: hold ⌃⇧Q, tap
/// ⌃⇧A for AI, tap it again for plain text, let go of Q. The owner itself cannot be pressed
/// again while it is down; a press of it means its release never arrived, and it follows
/// the table, so a missed release costs one extra press rather than a stuck recording.
///
/// Pure logic; `AppState` supplies the phase and performs the action.
public struct DictationHotkeyGesture: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The microphone is not open yet. Nothing has been recorded, so a stop here
        /// is a cancel.
        case starting(ai: Bool)
        case recording(ai: Bool)
        /// Transcribing or rewriting — the audio is closed.
        case busy
    }

    /// Shorter than this, a release is the end of a tap rather than of a hold, and cancels.
    /// Long enough for a deliberate keypress, short enough that no one says a word in it.
    public static let tapThreshold: TimeInterval = 0.3
    /// After a tap's release, how long a second press still makes it a double tap. The
    /// Edit shortcut's window, so the two gestures feel the same.
    public static let doubleTapWindow: TimeInterval = 0.35

    public var holdToTalk = false
    /// The shortcut whose press started the current dictation, while it is still down.
    public private(set) var owner: DictationHotkey?
    private var pressedAt: TimeInterval = 0
    /// The shortcut that was tapped, and when it came up, while the tap may still turn
    /// out to be the first half of a double tap.
    private var tapped: (key: DictationHotkey, releasedAt: TimeInterval)?

    /// A tap is waiting for its second half; `AppState` runs the timer.
    public var awaitsSecondTap: Bool { tapped != nil }

    public init(holdToTalk: Bool = false) {
        self.holdToTalk = holdToTalk
    }

    /// A press of `key`, the same table with or without hold-to-talk.
    static func action(forPressOf key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        switch phase {
        case .idle:
            return .start(ai: key.isAI)
        case .starting(let ai):
            return key.isAI == ai ? .cancel(.shortcut) : .switchTo(ai: key.isAI)
        case .recording(let ai):
            return key.isAI == ai ? .stop : .switchTo(ai: key.isAI)
        case .busy:
            return .cancel(.shortcut)
        }
    }

    public mutating func press(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        if let tap = tapped {
            tapped = nil
            switch phase {
            case .starting, .recording:
                let isSecondTap = key == tap.key && time - tap.releasedAt <= Self.doubleTapWindow
                return isSecondTap ? .lock : .cancel(.tap)
            case .idle, .busy:
                break
            }
        }
        if let owner, key != owner {
            switch phase {
            case .starting(let ai), .recording(let ai):
                return .switchTo(ai: !ai)
            case .idle, .busy:
                break
            }
        }
        let action = Self.action(forPressOf: key, in: phase)
        switch action {
        case .start:
            owner = holdToTalk ? key : nil
            pressedAt = time
        case .stop, .cancel:
            // Its own release, still to come, must not act on whatever follows.
            owner = nil
        case .switchTo, .lock, .ignore:
            break
        }
        return action
    }

    /// A menu item: the press table with no key behind it, so no release will follow. A
    /// dictation it starts or ends has no owner.
    public mutating func click(_ key: DictationHotkey, in phase: Phase) -> DictationHotkeyAction {
        var action = Self.action(forPressOf: key, in: phase)
        if case .cancel = action { action = .cancel(.menu) }
        if case .switchTo = action {} else {
            owner = nil
            tapped = nil
        }
        return action
    }

    public mutating func release(_ key: DictationHotkey, in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        guard key == owner else { return .ignore }
        owner = nil
        switch phase {
        case .starting, .recording:
            if time - pressedAt < Self.tapThreshold {
                tapped = (key, time)
                return .ignore
            }
            // A hold let go before the microphone opened has recorded nothing.
            if case .recording = phase { return .stop }
            return .cancel(.releasedEarly)
        case .idle, .busy:
            return .ignore
        }
    }

    /// `doubleTapWindow` after a tap's release, with no second press: the tap was all
    /// there was, and a lone tap cancels.
    public mutating func tapWindowExpired(in phase: Phase, at time: TimeInterval) -> DictationHotkeyAction {
        guard let tap = tapped, time - tap.releasedAt >= Self.doubleTapWindow * 0.9 else { return .ignore }
        tapped = nil
        switch phase {
        case .starting, .recording: return .cancel(.tap)
        case .idle, .busy: return .ignore
        }
    }

    /// The dictation ended some other way — ⎋, ✕, a menu item — or an edit took the
    /// microphone: a tap still waiting for its second half no longer belongs to anything,
    /// and its window running out must not cancel whatever records next.
    public mutating func reset() {
        owner = nil
        tapped = nil
    }
}

// MARK: - Holding only the letter

/// How a key of a shortcut is drawn.
public enum KeycapState: Equatable, Sendable {
    case up
    case down
    /// A modifier of a held shortcut once its letter is down: with hold to talk the
    /// letter alone keeps the recording going (Carbon reports the hotkey's release only
    /// when the letter comes up), so ⌃ and ⇧ may be let go — and held on, they turn
    /// clicks into ⌃-clicks and ⌘Tab into ⌃⇧⌘Tab.
    case notNeeded
}

/// The hold tip: teaching that a hold recording needs only its letter held.
///
/// Shown beside the overlay for the first hold recordings, and gone once the user has
/// let go of the modifiers mid-recording `lessons` times; then, once, how to switch to
/// the other mode while holding. The count lives in `holdTipFollowedCount`. Pure logic;
/// `AppState` shows the panel and keeps the count.
public enum HoldTip {
    /// Hold recordings in which the tip was *followed* — the modifiers let go with the
    /// letter still down — before it stops appearing.
    static let lessons = 3

    public enum Stage: Equatable, Sendable {
        /// "Keep Q down — you can let go of ⌃⇧."
        case keepHolding
        /// "While holding, ⌃⇧A switches to AI." Shown once, after the lessons.
        case switchHint
        case none
    }

    /// What a hold recording shows. `canSwitch`: a dictation with another mode to switch
    /// to — not an edit, and not the AI shortcut while no AI is set up.
    public static func stage(count: Int, canSwitch: Bool) -> Stage {
        if count < lessons { return .keepHolding }
        if count == lessons, canSwitch { return .switchHint }
        return .none
    }

    /// The count once a hold recording has ended.
    public static func count(after count: Int, stage: Stage, followed: Bool) -> Int {
        switch stage {
        case .keepHolding: return followed ? count + 1 : count
        case .switchHint: return count + 1
        case .none: return count
        }
    }

    /// The caps of a shortcut: `modifiersDown` one per modifier cap, in order.
    public static func keycaps(modifiersDown: [Bool], letterDown: Bool, holdToTalk: Bool)
        -> (modifiers: [KeycapState], letter: KeycapState) {
        let letter: KeycapState = letterDown ? .down : .up
        if holdToTalk, letterDown {
            return (modifiersDown.map { _ in .notNeeded }, letter)
        }
        return (modifiersDown.map { $0 ? .down : .up }, letter)
    }

    /// Whether the tip has been followed: every modifier up, the letter still down.
    public static func isFollowed(modifiersDown: [Bool], letterDown: Bool) -> Bool {
        letterDown && !modifiersDown.isEmpty && !modifiersDown.contains(true)
    }

    /// The tip's words. `letter` and `modifiers` are the held shortcut's ("Q", "⌃⇧");
    /// `other` is the other dictation shortcut, for the switch hint. The panel gives the
    /// text about 210 pt beside the keycaps: the title fits one line, the detail two.
    public static func text(stage: Stage, followed: Bool, isEdit: Bool, letter: String, modifiers: String,
                     other: String, otherIsAI: Bool) -> (title: String, detail: String) {
        switch stage {
        case .switchHint:
            return (otherIsAI ? "Switch to AI" : "Switch to plain text",
                    "While holding \(letter), press \(other). Press it again to switch back.")
        case .keepHolding, .none:
            if followed {
                return ("Just \(letter) — that's it",
                        isEdit ? "Let go of \(letter) to send the instruction." : "Let go of \(letter) when you're done.")
            }
            return ("You can let go of \(modifiers)", "\(letter) alone keeps recording, so clicks and ⌘Tab work as usual.")
        }
    }

    // Settings › Recording plays each gesture as the user's own keys going down one
    // after another and what the dictation does, one frame at a time.

    /// What the dictation is doing in a demo frame.
    public enum DemoState: Equatable, Sendable {
        case idle, recording, locked, ai, pasted
    }

    /// A gesture Settings demonstrates. With hold to talk: the hold, the double tap that
    /// locks it on, and the switch to AI Rewrite and back while the letter is held.
    /// Without: a press to start and a press to paste, and the switch by the other
    /// shortcut.
    public enum DemoGesture: CaseIterable, Sendable {
        case hold, lock, holdSwitch, toggle, toggleSwitch

        /// Whether the gesture uses the other dictation shortcut, whose caps follow this one's.
        public var usesOtherShortcut: Bool { self == .holdSwitch || self == .toggleSwitch }
        var holdsToTalk: Bool { self == .hold || self == .lock || self == .holdSwitch }
    }

    /// Where each key of a demo is drawn. The shortcut's caps come first, its modifiers
    /// then its letter; a switch adds the other shortcut — only its letter when the two
    /// share their modifiers (⌃ ⇧ Q A, the same ⌃⇧ pressed again), all of it otherwise.
    public struct DemoLayout: Equatable, Sendable {
        public let modifiers: Int
        public let otherModifiers: Int
        public let sharesModifiers: Bool

        public init(modifiers: Int, otherModifiers: Int = 0, sharesModifiers: Bool = true) {
            self.modifiers = modifiers
            self.otherModifiers = otherModifiers
            self.sharesModifiers = sharesModifiers
        }

        var letter: Int { modifiers }
        func otherModifier(_ index: Int) -> Int { sharesModifiers ? index : modifiers + 1 + index }
        var otherLetter: Int { sharesModifiers ? modifiers + 1 : modifiers + 1 + otherModifiers }
        var otherModifierCount: Int { sharesModifiers ? modifiers : otherModifiers }

        public func capCount(_ gesture: DemoGesture) -> Int {
            gesture.usesOtherShortcut ? otherLetter + 1 : modifiers + 1
        }
    }

    /// One frame: how each cap is drawn, which caps are ringed (the letter that alone
    /// keeps a hold recording going), and what the dictation is doing.
    public struct DemoFrame: Equatable, Sendable {
        public var caps: [KeycapState]
        public var ringed: Set<Int>
        public var state: DemoState
    }

    /// A gesture as a list of moments, each the keys down from then on and the state.
    struct DemoScript {
        private(set) var moments: [(at: TimeInterval, down: Set<Int>, state: DemoState)] = []
        private(set) var time: TimeInterval = 0
        private var down: Set<Int> = []
        private var state: DemoState = .idle

        /// The gap between two keys of one shortcut going down.
        static let keyGap: TimeInterval = 0.22

        /// `press` go down and `release` come up now, the dictation becomes `state`, and
        /// that holds for `seconds`.
        mutating func step(_ seconds: TimeInterval, press: [Int] = [], release: [Int] = [], state: DemoState? = nil) {
            down.formUnion(press)
            down.subtract(release)
            if let state { self.state = state }
            moments.append((time, down, self.state))
            time += seconds
        }

        /// The modifiers going down one after another; the letter is the caller's step.
        mutating func pressModifiers(_ caps: [Int]) {
            for cap in caps { step(Self.keyGap, press: [cap]) }
        }

        func moment(at time: TimeInterval) -> (down: Set<Int>, state: DemoState) {
            let t = time.truncatingRemainder(dividingBy: self.time)
            let moment = moments.last { $0.at <= t } ?? moments[0]
            return (moment.down, moment.state)
        }
    }

    static func demoScript(_ gesture: DemoGesture, layout: DemoLayout) -> DemoScript {
        var s = DemoScript()
        let modifiers = Array(0..<layout.modifiers)
        let letter = layout.letter
        let otherModifiers = (0..<layout.otherModifierCount).map(layout.otherModifier)
        let other = layout.otherLetter
        let all = Array(0..<layout.capCount(gesture))
        s.step(0.6)
        switch gesture {
        case .hold:
            // ⌃ → ⇧ → Q, then ⌃ and ⇧ let go together: Q alone keeps it recording.
            s.pressModifiers(modifiers)
            s.step(0.6, press: [letter], state: .recording)
            s.step(2.0, release: modifiers)
            s.step(1.4, release: [letter], state: .pasted)
        case .lock:
            // ⌃ → ⇧ → Q → Q, then everything let go: it records with nothing held.
            s.pressModifiers(modifiers)
            s.step(0.18, press: [letter], state: .recording)
            s.step(0.16, release: [letter])
            s.step(0.3, press: [letter])
            s.step(2.0, release: all, state: .locked)
            // The next press stops it.
            s.pressModifiers(modifiers)
            s.step(0.25, press: [letter], state: .pasted)
            s.step(1.3, release: all)
        case .holdSwitch:
            // Q held on its own, ⌃ → ⇧ → A for AI Rewrite and the same again to come back.
            s.pressModifiers(modifiers)
            s.step(0.5, press: [letter], state: .recording)
            s.step(0.7, release: modifiers)
            for state in [DemoState.ai, .recording] {
                s.pressModifiers(otherModifiers)
                s.step(0.25, press: [other], state: state)
                s.step(0.9, release: otherModifiers + [other])
            }
            s.step(1.4, release: [letter], state: .pasted)
        case .toggle:
            // ⌃ → ⇧ → Q, let go: it records with nothing held; the same again pastes.
            s.pressModifiers(modifiers)
            s.step(0.25, press: [letter], state: .recording)
            s.step(1.8, release: all)
            s.pressModifiers(modifiers)
            s.step(0.25, press: [letter], state: .pasted)
            s.step(1.3, release: all)
        case .toggleSwitch:
            // Started with ⌃⇧Q, ⌃⇧A turns it into an AI Rewrite and ⌃⇧Q back, and ⌃⇧Q
            // again pastes.
            let presses: [(modifiers: [Int], letter: Int, state: DemoState)] = [
                (modifiers, letter, .recording), (otherModifiers, other, .ai),
                (modifiers, letter, .recording), (modifiers, letter, .pasted),
            ]
            for press in presses {
                s.pressModifiers(press.modifiers)
                s.step(0.25, press: [press.letter], state: press.state)
                s.step(press.state == .pasted ? 1.3 : 0.8, release: press.modifiers + [press.letter])
            }
        }
        return s
    }

    /// How long a gesture's loop lasts.
    public static func demoPeriod(_ gesture: DemoGesture, layout: DemoLayout) -> TimeInterval {
        demoScript(gesture, layout: layout).time
    }

    /// The gesture `time` seconds in; it loops. In a hold, a modifier of the held
    /// shortcut that is up while its letter is down is *not needed* — faded, as the live
    /// caps draw it — and the letter is ringed; while the modifiers are still down they
    /// are drawn down.
    public static func demoFrame(_ gesture: DemoGesture, layout: DemoLayout, at time: TimeInterval) -> DemoFrame {
        let moment = demoScript(gesture, layout: layout).moment(at: time)
        let letterHeld = gesture.holdsToTalk && moment.down.contains(layout.letter)
        var caps = (0..<layout.capCount(gesture)).map { moment.down.contains($0) ? KeycapState.down : .up }
        var ringed = Set<Int>()
        if letterHeld {
            for modifier in 0..<layout.modifiers where caps[modifier] == .up { caps[modifier] = .notNeeded }
            if caps.contains(.notNeeded) { ringed.insert(layout.letter) }
        }
        return DemoFrame(caps: caps, ringed: ringed, state: moment.state)
    }
}
