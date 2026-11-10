// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Setup's "Your server" panel, for one role: what is typed there, until Continue writes it.
///
/// Continue waits for a passed test of exactly what it would save, so a half-typed address
/// never takes over dictation. What an earlier run of setup or Settings stored has passed
/// already: setup run again with the server switched off still keeps it.
public struct ServerDraft: Equatable, Sendable {
    private struct Choice: Equatable, Sendable {
        var address: String
        var key: String
        var model: String
    }

    public let role: ServerRole
    private let stored: Choice
    private let storedHasPassed: Bool
    private var current: Choice
    private var passed: Choice?
    /// What the server listed; empty until it has answered.
    public private(set) var models: [String] = []
    /// The server answered with no models, or has no list at all (whisper.cpp's): the
    /// model is typed.
    public private(set) var listsNoModels = false
    public private(set) var result: ServerTestResult?
    public private(set) var isTesting = false
    private var serverAskedForKey = false

    public init(role: ServerRole, address: String, model: String, key: String) {
        self.role = role
        stored = Choice(address: address, key: key, model: model)
        current = stored
        storedHasPassed = ServerEndpoint(address: address) != nil && !model.isEmpty
        passed = storedHasPassed ? stored : nil
    }

    public var address: String { current.address }
    public var key: String { current.key }
    public var model: String { current.model }
    public var endpoint: ServerEndpoint? { ServerEndpoint(address: current.address) }

    /// The key field: only once the server has asked for one, or when one is held.
    public var showsKey: Bool { serverAskedForKey || !current.key.isEmpty }

    /// A pass at another address does not take the stored server's away: typed back in,
    /// it can still be kept with the server switched off.
    public var canContinue: Bool {
        !isTesting && (passed == current || (storedHasPassed && current == stored))
    }

    /// The address the other role's panel may offer: one that has answered.
    public var verifiedAddress: String? { passed?.address }

    /// The rows of the model list: what the server listed, else the model already chosen.
    public var modelRows: [String] {
        if !models.isEmpty { return models }
        return listsNoModels || current.model.isEmpty ? [] : [current.model]
    }

    /// What Continue writes; nil until a test has passed for it.
    public var saved: (address: String, model: String, key: String)? {
        guard canContinue else { return nil }
        return (current.address.trimmingCharacters(in: .whitespacesAndNewlines), current.model, current.key)
    }

    /// A key is for the server it was given to: another address starts with none, and
    /// the stored key and model come back only with the stored address.
    public mutating func setAddress(_ text: String) {
        guard !isTesting, text != current.address else { return }
        let isStored = text == stored.address
        current = Choice(address: text, key: isStored ? stored.key : "", model: isStored ? stored.model : "")
        models = []
        listsNoModels = false
        result = nil
        serverAskedForKey = false
    }

    public mutating func setKey(_ text: String) {
        guard !isTesting, text != current.key else { return }
        current.key = text
        result = nil
    }

    public mutating func setModel(_ id: String) {
        guard !isTesting, id != current.model else { return }
        current.model = id
        result = nil
    }

    /// False when there is nothing to test, or a test is running.
    public mutating func beginTest() -> Bool {
        guard !isTesting, endpoint != nil else { return false }
        isTesting = true
        result = nil
        return true
    }

    public mutating func finishTest(_ run: ServerTestRun) {
        isTesting = false
        result = run.result
        if run.result == .needsKey { serverAskedForKey = true }
        if let listed = run.listed {
            models = listed
            listsNoModels = listed.isEmpty
        } else {
            models = []
        }
        if let model = run.model { current.model = model }
        if case .answered = run.result { passed = current }
    }

    /// What a server already chosen lists now, when setup opens on it.
    public mutating func refreshModels(_ ids: [String], from address: String) {
        guard !isTesting, address == current.address else { return }
        models = ids
    }
}
