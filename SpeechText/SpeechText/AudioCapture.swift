// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import SpeechTextCore

/// Where `SpeechEngine` takes the microphone's audio from. Two sources behind one shape,
/// so the tap, the writer and the session see no difference:
///
/// - `EngineCapture`, `AVAudioEngine`'s input node on the system's input — the path the
///   app always took, kept for System Default and for Automatic when it substitutes
///   nothing.
/// - `DeviceCapture`, a bare AUHAL bound to one device, for every resolution that names
///   one. `AVAudioEngine` cannot be pointed at a device without first opening the
///   system's: touching `inputNode` builds `CADefaultDeviceAggregate` from the default
///   input and output and binds the I/O unit to it, and with Bluetooth headphones that
///   input is the headset's microphone — the headset dropped to its call profile and the
///   music stopped for seconds, though `setDeviceID` moved the unit to the Mac's own
///   microphone a moment later. The move also left the tap holding the headset's 48 kHz
///   format against the microphone's 44.1 kHz, and the start failed with -10868.
///
/// `start`, `stop` and `removeTap` run on `SpeechEngine`'s `engineQueue`; `format`,
/// `installTap` and `onConfigurationChange` are used from main. Each capture is
/// `@unchecked Sendable` on that discipline: whatever else two threads share is under a
/// lock, or is the system object the queue serialises.
protocol AudioCapture: AnyObject, Sendable {
    /// The hardware format the tap delivers.
    var format: AVAudioFormat { get }
    var isRunning: Bool { get }
    /// The device changed under the capture (it went away, or its format changed),
    /// delivered on main. A change that leaves `isRunning` true needs nothing.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
    /// `@Sendable`: the block runs on the tap's thread, never main.
    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    /// Returns once no tap callback is running or can run again.
    func removeTap()
    func start() throws
    func stop()
}

// MARK: - The system's input

final class EngineCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (@MainActor () -> Void)?

    init() {
        // Device plugged or unplugged, AirPods switching: AVAudioEngine stops itself and
        // says so here.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        // nil: the hardware's own format, which avoids "format mismatch" ObjC exceptions
        // that Swift cannot catch.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            block(buffer)
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}

// MARK: - One device

enum DeviceCaptureError: LocalizedError {
    case noInput

    var errorDescription: String? { "The microphone offers no input" }
}

final class DeviceCapture: AudioCapture, @unchecked Sendable {
    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    var onConfigurationChange: (@MainActor () -> Void)?

    private let unit: AUAudioUnit
    /// Tap callbacks run here, in order, off the HAL's real-time I/O thread: the tap
    /// converts audio and takes the writer's and the stream's locks, none of which may
    /// hold up the device. `AVAudioEngine`'s tap is off that thread too.
    private let tapQueue = DispatchQueue(label: "SpeechText.DeviceCapture.tap", qos: .userInitiated)
    private let lock = NSLock()
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var running = false
    private var reportedRenderFailure = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// The AUHAL's input element. Element 0 is the output side, unused here.
    private static let inputBus = 1

    init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        unit = try AUAudioUnit(componentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        // Input only: with output enabled the unit would open the default output device too.
        unit.isInputEnabled = true
        unit.isOutputEnabled = false
        try unit.setDeviceID(deviceID)

        // The device side of the input element is the hardware's format; the client side
        // takes the same rate and channel count, so the AUHAL converts nothing — a rate
        // it resampled to would reach the writer as a speed-up or a slow-down.
        let hardware = unit.inputBusses[Self.inputBus].format
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              let client = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount)
        else { throw DeviceCaptureError.noInput }
        try unit.outputBusses[Self.inputBus].setFormat(client)
        format = client
        // The default (512) is the built-in microphone's I/O buffer; a device running a
        // larger one would fail every render with -10874 and record silence.
        unit.maximumFramesToRender = 4096

        let render = unit.renderBlock
        unit.inputHandler = { [weak self] flags, timestamp, frames, _ in
            guard let self, let block = self.currentTap() else { return }
            // A fresh buffer each time: Apple's recognition request keeps the buffers it
            // is fed, as it keeps AVAudioEngine's.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let status = render(flags, timestamp, frames, Self.inputBus, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                // Said once: a render that fails keeps failing, and the recording would
                // otherwise be silent with nothing in the Debug Log.
                if !self.lock.withLock({ defer { self.reportedRenderFailure = true }; return self.reportedRenderFailure }) {
                    dlog("Engine", "⚠ microphone render failed: \(status) (\(frames) frames)", level: .error)
                }
                return
            }
            // Handed over whole: made for this callback and never touched here again,
            // which is what makes the unchecked hand-off safe.
            nonisolated(unsafe) let rendered = buffer
            self.tapQueue.async { block(rendered) }
        }
        watchDevice()
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
    }

    var isRunning: Bool { lock.withLock { running } }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.withLock { tap = block }
    }

    func removeTap() {
        lock.withLock { tap = nil }
        // Whatever was queued before the tap went has run once this returns.
        tapQueue.sync {}
    }

    func start() throws {
        try unit.allocateRenderResources()
        try unit.startHardware()
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        unit.stopHardware()
    }

    private func currentTap() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        lock.withLock { tap }
    }

    /// AVAudioEngine's configuration-change notification, rebuilt for one device: it
    /// went away (unplugged, the lid closed), or its rate or channels changed. The
    /// capture counts as stopped from then on, as AVAudioEngine does, so `isRunning`
    /// tells the owner the change was real; the hardware itself is stopped by the owner's
    /// teardown, on its own queue.
    private func watchDevice() {
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceChanged()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func deviceChanged() {
        let alive = AudioInputDevices.isAlive(deviceID)
        let rate = AudioInputDevices.nominalSampleRate(of: deviceID)
        let changed = !alive || (rate.map { $0 != format.sampleRate } ?? true)
            || unit.inputBusses[Self.inputBus].format.channelCount != format.channelCount
        guard changed else { return }
        dlog("Engine", "microphone changed under the capture (alive: \(alive), rate: \(rate.map { "\(Int($0)) Hz" } ?? "?"))")
        lock.withLock { running = false }
        // The listeners are registered on the main queue.
        MainActor.assumeIsolated { onConfigurationChange?() }
    }
}

// MARK: - A file, for end-to-end runs

#if DEBUG
/// Debug builds only: plays a file through the tap in real time, as a microphone would
/// deliver it, so `scripts/e2e.sh` can drive a whole dictation with no person speaking
/// (`-SPTAudioInput`, see `E2EMode`). The tap gets the file's own format — the corpus is
/// 48 kHz Float32 mono, what a Mac's microphone hands `AVAudioEngine` — so the writer's
/// downsampler and the stream's converter run exactly as they do on a microphone. Once
/// the file has played, or with no file at all, it delivers silence until stopped: a
/// hold that outlasts the clip keeps recording, as it would in a quiet room.
final class FileCapture: AudioCapture, @unchecked Sendable {
    let format: AVAudioFormat
    var onConfigurationChange: (@MainActor () -> Void)?

    private let samples: AVAudioPCMBuffer?
    /// Frames per tap callback: 100 ms at 48 kHz, about what `AVAudioEngine`'s input
    /// tap delivers on a Mac.
    private let chunkFrames: AVAudioFrameCount
    private let queue = DispatchQueue(label: "SpeechText.FileCapture.tap", qos: .userInitiated)
    private let lock = NSLock()
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var timer: DispatchSourceTimer?
    private var startedAt: TimeInterval = 0
    private var delivered: AVAudioFramePosition = 0

    init(url: URL?) throws {
        if let url {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { throw DeviceCaptureError.noInput }
            try file.read(into: buffer)
            samples = buffer
            format = file.processingFormat
        } else {
            samples = nil
            format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        }
        chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
    }

    var isRunning: Bool { lock.withLock { timer != nil } }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.withLock { tap = block }
    }

    func removeTap() {
        lock.withLock { tap = nil }
        queue.sync {}
    }

    func start() throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.deliverDue() }
        lock.withLock {
            startedAt = ProcessInfo.processInfo.systemUptime
            delivered = 0
            self.timer = timer
        }
        timer.resume()
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    /// Everything the clock says is due, in whole chunks — the pace is the wall clock's,
    /// never the timer's, so a late firing catches up instead of slowing the clip down.
    private func deliverDue() {
        let (block, due) = lock.withLock { () -> ((@Sendable (AVAudioPCMBuffer) -> Void)?, AVAudioFramePosition) in
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            return (tap, AVAudioFramePosition(elapsed * format.sampleRate))
        }
        while due - delivered >= AVAudioFramePosition(chunkFrames) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
            buffer.frameLength = chunkFrames
            fill(buffer, from: delivered)
            delivered += AVAudioFramePosition(chunkFrames)
            block?(buffer)
        }
    }

    /// The file's frames from `position` on, zeros past its end.
    private func fill(_ buffer: AVAudioPCMBuffer, from position: AVAudioFramePosition) {
        let channels = Int(format.channelCount)
        let count = Int(buffer.frameLength)
        guard let out = buffer.floatChannelData else { return }
        for channel in 0..<channels {
            out[channel].update(repeating: 0, count: count)
        }
        guard let samples, let source = samples.floatChannelData,
              position < AVAudioFramePosition(samples.frameLength) else { return }
        let available = min(count, Int(AVAudioFramePosition(samples.frameLength) - position))
        for channel in 0..<channels {
            out[channel].update(from: source[channel].advanced(by: Int(position)), count: available)
        }
    }
}
#endif
