// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which windows a snapshot run draws: `scripts/window-snapshots.sh --only`, passed to the
/// app as `-SPTSnapshotsOnly`, so a pull request's screenshot takes one window rather than
/// every window in every language. Each word is a snapshot's name, the `<name>.png` a run
/// writes (`settings-general`), or, ending in `-`, the start of several (`setup-` for every
/// step of Setup). Only a word ending in `-` is a prefix: `settings-a` names no window
/// rather than every category that happens to begin with an a. No words means every
/// window, as a run without `--only` draws.
public struct WindowSnapshotSelection: Equatable, Sendable {
    public let words: [String]

    /// Words split on spaces and commas, as the script's `--only "a b"` gives them.
    public init(_ text: String?) {
        words = (text ?? "").split { $0.isWhitespace || $0 == "," }.map(String.init)
    }

    public func includes(_ name: String) -> Bool {
        words.isEmpty || words.contains { Self.word($0, matches: name) }
    }

    /// The words that name none of `names`, in the order given: the run draws nothing and
    /// the script lists the names there are.
    public func unmatched(in names: [String]) -> [String] {
        words.filter { word in !names.contains { Self.word(word, matches: $0) } }
    }

    private static func word(_ word: String, matches name: String) -> Bool {
        word.hasSuffix("-") ? name.hasPrefix(word) : name == word
    }
}
