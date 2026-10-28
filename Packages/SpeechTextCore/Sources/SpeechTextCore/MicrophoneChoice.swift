// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A microphone as Core Audio lists it, reduced to what the choice needs. Built by
/// `AudioInputDevices` (app target); the tests build it by hand.
public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    public enum Transport: Equatable, Sendable {
        case builtIn
        /// Classic and LE alike: either turns a headset to call quality while its
        /// microphone is open.
        case bluetooth
        case usb
        /// Continuity (an iPhone), virtual and aggregate devices, anything else.
        case other
    }

    public let uid: String
    public let name: String
    public let transport: Transport
    /// False for a MacBook's own microphone with the lid closed: it stays in the list,
    /// but the hardware is disconnected and records silence.
    public var canHear = true

    public init(uid: String, name: String, transport: Transport, canHear: Bool = true) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.canHear = canHear
    }

    public var id: String { uid }
}

/// Which microphone a dictation records from — the stored `SettingsKeys.microphone`.
public enum MicrophoneChoice: Equatable, Sendable {
    /// The system's input, except that Bluetooth headphones are left to play and the
    /// Mac's own microphone records instead.
    case automatic
    /// Whatever System Settings › Sound › Input names, as before this setting existed.
    case systemDefault
    /// One device, by its Core Audio UID — stable across reconnections and restarts.
    case device(uid: String)

    private static let systemDefaultValue = "system"

    public init(stored: String) {
        switch stored {
        case "": self = .automatic
        case Self.systemDefaultValue: self = .systemDefault
        default: self = .device(uid: stored)
        }
    }

    public var stored: String {
        switch self {
        case .automatic: ""
        case .systemDefault: Self.systemDefaultValue
        case .device(let uid): uid
        }
    }
}

/// What a choice comes to with the devices connected right now.
public struct MicrophoneResolution: Equatable, Sendable {
    /// The device to record from; nil leaves the system's input alone, which is exactly
    /// the path the app took before the setting existed.
    public var device: AudioInputDevice?
    /// The Bluetooth headset Automatic stepped around, to say why another microphone is in use.
    public var avoided: AudioInputDevice?
    /// The device the user picked is not connected, so Automatic decided instead.
    public var pickedIsMissing = false

    public init(device: AudioInputDevice? = nil, avoided: AudioInputDevice? = nil, pickedIsMissing: Bool = false) {
        self.device = device
        self.avoided = avoided
        self.pickedIsMissing = pickedIsMissing
    }

    public static func resolve(_ choice: MicrophoneChoice, devices: [AudioInputDevice],
                        defaultUID: String?) -> MicrophoneResolution {
        switch choice {
        case .systemDefault:
            return MicrophoneResolution()
        case .device(let uid):
            // Pinned even when it is the default today: it should stay the microphone
            // when the default moves, as it does when headphones connect.
            if let picked = devices.first(where: { $0.uid == uid }) {
                return MicrophoneResolution(device: picked)
            }
            var fallback = resolve(.automatic, devices: devices, defaultUID: defaultUID)
            fallback.pickedIsMissing = true
            return fallback
        case .automatic:
            // A Bluetooth headset's microphone turns the whole headset to call quality —
            // music goes mono and muffled — and takes about a second to open, which can
            // cost the first words. Only the Mac's own microphone is put in its place:
            // an iPhone or a virtual device may not be what the user is speaking into.
            guard let current = devices.first(where: { $0.uid == defaultUID }),
                  current.transport == .bluetooth,
                  let builtIn = devices.first(where: { $0.transport == .builtIn && $0.canHear })
            else { return MicrophoneResolution() }
            return MicrophoneResolution(device: builtIn, avoided: current)
        }
    }
}
