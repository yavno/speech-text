// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two models a dictation can pass through, in the order it reaches them. Settings ›
/// Models draws one frame for each, and an API key is tagged with the ones it serves.
public enum ModelRole: String, CaseIterable, Hashable, Sendable {
    case speech, aiRewrite
}

/// A shortcut as the Models page draws it (#247): what it starts from, and which models it
/// passes through on the way to the paste. The Record Window has no tab: its ✨ runs the
/// same two models as AI Rewrite.
public enum ModelChainShortcut: String, CaseIterable, Hashable, Sendable {
    case dictate, aiRewrite, edit

    /// The shortcut's own name for its keys.
    public var action: ShortcutAction {
        switch self {
        case .dictate: .inline
        case .aiRewrite: .ai
        case .edit: .edit
        }
    }

    /// The models it passes through. Edit's instruction is spoken, so it is transcribed too.
    public var roles: [ModelRole] {
        self == .dictate ? [.speech] : [.speech, .aiRewrite]
    }

    /// Edit starts from the selected text as well as the voice.
    public var startsFromSelection: Bool { self == .edit }
}

/// Which tab and frame Settings › Models shows, from what was stored the last time it was
/// left. Both are remembered (`SettingsKeys.modelsPageShortcut`, `.modelsPageRole`); a
/// link that asks for one frame stores it before the page opens (`opening(_:)`).
public struct ModelsPageSelection: Equatable, Sendable {
    public var shortcut: ModelChainShortcut
    public var role: ModelRole

    /// Nothing stored yet: AI Rewrite, whose chain has both frames, on the first of them.
    public static let initial = ModelsPageSelection(shortcut: .aiRewrite, role: .speech)

    public init(shortcut: ModelChainShortcut, role: ModelRole) {
        self.shortcut = shortcut
        self.role = role
    }

    /// The stored values, read so that the open frame is always one the tab draws: Dictate
    /// has no AI Rewrite frame, so it opens on Speech to text.
    public init(storedShortcut: String, storedRole: String) {
        let shortcut = ModelChainShortcut(rawValue: storedShortcut) ?? Self.initial.shortcut
        let role = ModelRole(rawValue: storedRole) ?? Self.initial.role
        self.init(shortcut: shortcut, role: shortcut.roles.contains(role) ? role : .speech)
    }

    /// A link to `role`'s frame: a tab without it turns to AI Rewrite, any other stays.
    public func opening(_ role: ModelRole) -> ModelsPageSelection {
        ModelsPageSelection(shortcut: shortcut.roles.contains(role) ? shortcut : .aiRewrite, role: role)
    }
}
