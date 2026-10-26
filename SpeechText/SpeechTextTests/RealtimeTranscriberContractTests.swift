// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

// The contract of the two realtime transcribers, held against a fake socket and a clock
// advanced by hand: what goes on the wire, in what order, and what comes back as events.
// `DictationReplay` drives a scripted `StreamingTranscriber` with no socket, so it tests
// everything after the transcriber; these test the transcriber itself.

// MARK: - The fake socket

/// A `RealtimeWebSocket` that records what is sent, in the order the sends *returned* —
/// the order the messages are on the wire — and hands `receive()` the messages a test
/// delivers, when it delivers them.
final class FakeWebSocket: RealtimeWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentMessages: [String] = []
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false
    private var openedRequest: URLRequest?
    private var sendHook: (@Sendable (String) -> Void)?
    private var failure: (@Sendable (String) -> Bool)?

    var request: URLRequest? { lock.withLock { openedRequest } }
    /// Runs inside `send`, before the message is recorded — on the sending thread, with
    /// whatever locks the transcriber holds there. A test blocks in it to hold a send open.
    var duringSend: (@Sendable (String) -> Void)? {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
    }
    /// A send this says yes to completes with an error, inside the call — as URLSession may
    /// complete one synchronously — and is not recorded.
    var failsSend: (@Sendable (String) -> Bool)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var sent: [String] { lock.withLock { sentMessages } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    /// Everything delivered has been handled: the receive loop has come back for more, or
    /// the stream has closed.
    var isIdle: Bool { lock.withLock { inbox.isEmpty && (waiter != nil || cancelled) } }

    func opened(with request: URLRequest) -> FakeWebSocket {
        lock.withLock { openedRequest = request }
        return self
    }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        guard case .string(let text) = message else { return completionHandler(nil) }
        let (during, fails) = lock.withLock { (sendHook, failure) }
        during?(text)
        if fails?(text) == true {
            // Outside the fake's lock: the completion runs the transcriber's close, which
            // cancels this socket.
            completionHandler(URLError(.networkConnectionLost))
            return
        }
        lock.withLock { sentMessages.append(text) }
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if cancelled {
                lock.unlock()
                cont.resume(throwing: URLError(.cancelled))
            } else if !inbox.isEmpty {
                let message = inbox.removeFirst()
                lock.unlock()
                cont.resume(returning: message)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: URLError(.cancelled))
    }

    /// A message from the server.
    func deliver(_ text: String) {
        lock.lock()
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: .string(text))
        } else {
            inbox.append(.string(text))
            lock.unlock()
        }
    }
}

// MARK: - The clock

/// A `RealtimeSleep` whose time moves only when a test advances it. A sleep returns early
/// when its task is cancelled, as `Task.sleep` does — `finish()` waits for the timer it
/// cancels.
final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: TimeInterval
        let duration: TimeInterval
        let cont: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeSleeping: Set<UUID> = []

    var sleep: RealtimeSleep { { [self] seconds in await self.wait(seconds) } }

    private func wait(_ seconds: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if cancelledBeforeSleeping.remove(id) != nil { return true }
                    sleepers[id] = Sleeper(deadline: now + seconds, duration: seconds, cont: cont)
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock {
                let sleeper = sleepers.removeValue(forKey: id)
                if sleeper == nil { cancelledBeforeSleeping.insert(id) }
                return sleeper
            }
            sleeper?.cont.resume()
        }
    }

    /// Someone is waiting out exactly this long.
    func isSleeping(for seconds: TimeInterval) -> Bool {
        lock.withLock { sleepers.values.contains { $0.duration == seconds } }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock {
            now += seconds
            let due = sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { sleepers[id] = nil }
            return due.values.map(\.cont)
        }
        for cont in due { cont.resume() }
    }
}

// MARK: - What the transcriber says

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamingSTTEvent] = []
    private var finished = false

    init(_ transcriber: any StreamingTranscriber) {
        let stream = transcriber.events
        Task { [self] in
            for await event in stream { lock.withLock { events.append(event) } }
            lock.withLock { finished = true }
        }
    }

    var partials: [String] {
        lock.withLock { events.compactMap { if case .partial(let text) = $0 { text } else { nil } } }
    }
    var committed: [String] {
        lock.withLock { events.compactMap { if case .committed(let text) = $0 { text } else { nil } } }
    }
    var failures: [Error] {
        lock.withLock { events.compactMap { if case .failed(let error) = $0 { error } else { nil } } }
    }
    var hasEnded: Bool { lock.withLock { finished } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Polls until `condition` holds; a failure, not a hang, when it never does.
@discardableResult
func eventually(_ what: String, seconds: TimeInterval = 2,
                file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("timed out waiting for: \(what)", file: file, line: line)
            return false
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// Delivers a server message and waits until the receive loop has handled it.
func deliver(_ text: String, to socket: FakeWebSocket,
             file: StaticString = #filePath, line: UInt = #line) async {
    socket.deliver(text)
    await eventually("the receive loop to handle \(text.prefix(60))", file: file, line: line) { socket.isIdle }
}

/// `finish()` started on a task of its own; `done` is set when it returns.
func startFinish(_ transcriber: any StreamingTranscriber) -> Flag {
    let done = Flag()
    Task {
        await transcriber.finish()
        done.set()
    }
    return done
}

func isNoSession(_ error: Error, from provider: Provider) -> Bool {
    guard case TranscriptionError.realtime(let reported, let code, _) = error else { return false }
    return reported == provider && code == "no_session"
}

// MARK: - The two vendors, one contract

/// A message the transcriber put on the socket, read back.
enum Wire: Equatable {
    case audio(Data)
    /// Scribe's commit carries the tail's audio; OpenAI's carries none, its tail is the
    /// `append` before it.
    case commit(Data)
    case sessionUpdate
    case other
}

enum Vendor: CaseIterable {
    case scribe, openAI

    var provider: Provider { self == .scribe ? .elevenLabs : .openAI }
    var sampleRate: Double { self == .scribe ? 16_000 : 24_000 }
    func bytes(forSeconds seconds: Double) -> Int { Int(sampleRate * seconds) * 2 }
    var chunkBytes: Int { bytes(forSeconds: STTTuning.streamChunkSeconds) }
    func chunk(_ fill: UInt8) -> Data { Data(repeating: fill, count: chunkBytes) }

    func make(socket: FakeWebSocket, clock: ManualClock) -> any StreamingTranscriber {
        switch self {
        case .scribe:
            ElevenLabsRealtimeTranscriber(apiKey: "sk_test", model: elevenLabsRealtimeModel,
                                          openSocket: { socket.opened(with: $0) }, sleep: clock.sleep)
        case .openAI:
            OpenAIRealtimeTranscriber(apiKey: "sk-test", model: openAIRealtimeSTTModel,
                                      openSocket: { socket.opened(with: $0) }, sleep: clock.sleep)
        }
    }

    /// What the server sends to say it will take audio.
    var ready: [String] {
        switch self {
        case .scribe: [#"{"message_type":"session_started","config":{}}"#]
        case .openAI: [#"{"type":"session.created"}"#, #"{"type":"session.updated"}"#]
        }
    }

    /// The transcript that answers the stop's commit.
    func commitReply(_ text: String) -> String {
        switch self {
        case .scribe: #"{"message_type":"committed_transcript","text":"\#(text)"}"#
        case .openAI: #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"\#(text)"}"#
        }
    }

    func wire(_ raw: String) -> Wire {
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return .other }
        switch self {
        case .scribe:
            guard json["message_type"] as? String == "input_audio_chunk",
                  let audio = (json["audio_base_64"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return .other }
            return json["commit"] as? Bool == true ? .commit(audio) : .audio(audio)
        case .openAI:
            switch json["type"] as? String {
            case "input_audio_buffer.append":
                return (json["audio"] as? String).flatMap { Data(base64Encoded: $0) }.map(Wire.audio) ?? .other
            case "input_audio_buffer.commit": return .commit(Data())
            case "session.update": return .sessionUpdate
            default: return .other
            }
        }
    }

    func wire(of socket: FakeWebSocket) -> [Wire] { socket.sent.map(wire) }

    func audio(of socket: FakeWebSocket) -> [Data] {
        wire(of: socket).compactMap { if case .audio(let data) = $0 { data } else { nil } }
    }

    func commitIndex(in socket: FakeWebSocket) -> Int? {
        wire(of: socket).firstIndex { if case .commit = $0 { true } else { false } }
    }

    /// The audio the stop committed: the commit's own for Scribe, the `append` right
    /// before it for OpenAI.
    func committedTail(of socket: FakeWebSocket) -> Data? {
        let wire = wire(of: socket)
        guard let index = commitIndex(in: socket) else { return nil }
        switch self {
        case .scribe:
            if case .commit(let audio) = wire[index] { return audio }
            return nil
        case .openAI:
            guard index > 0, case .audio(let audio) = wire[index - 1] else { return nil }
            return audio
        }
    }
}

/// One transcriber on a fake socket, connected.
struct Rig {
    let vendor: Vendor
    let socket = FakeWebSocket()
    let clock = ManualClock()
    let transcriber: any StreamingTranscriber
    let log: EventLog

    init(_ vendor: Vendor) {
        self.vendor = vendor
        transcriber = vendor.make(socket: socket, clock: clock)
        log = EventLog(transcriber)
        transcriber.connect(languages: [])
    }

    func becomeReady() async {
        for message in vendor.ready { await deliver(message, to: socket) }
    }
}

// MARK: - The contract both keep

final class RealtimeTranscriberContractTests: XCTestCase {
    /// The socket opens at the vendor's address with its key, and nothing is sent before
    /// the server speaks.
    func testTheSocketOpensWithTheVendorsAddressAndKey() throws {
        let scribe = Rig(.scribe)
        let request = try XCTUnwrap(scribe.socket.request)
        XCTAssertEqual(request.url, ElevenLabsRealtimeTranscriber.realtimeURL(
            model: elevenLabsRealtimeModel, languages: [], keyterms: []))
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "sk_test")
        scribe.transcriber.cancel()

        let openAI = Rig(.openAI)
        let openAIRequest = try XCTUnwrap(openAI.socket.request)
        XCTAssertEqual(openAIRequest.url?.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(openAIRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        openAI.transcriber.cancel()
    }

    /// Audio recorded before the server is ready is held — sending it would lose it — and
    /// released in order once it is, ahead of anything recorded after.
    func testAudioHeldForTheSessionIsSentInOrderOnceItIsReady() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            for fill in UInt8(1)...3 { rig.transcriber.send(pcm16: vendor.chunk(fill)) }
            XCTAssertEqual(vendor.audio(of: rig.socket), [], "\(vendor): nothing before the session")

            await rig.becomeReady()
            rig.transcriber.send(pcm16: vendor.chunk(4))

            XCTAssertEqual(vendor.audio(of: rig.socket), (UInt8(1)...4).map(vendor.chunk), "\(vendor)")
            if vendor == .openAI {
                XCTAssertEqual(vendor.wire(of: rig.socket).first, .sessionUpdate,
                               "the session is configured before any audio")
            }
            XCTAssertTrue(rig.log.failures.isEmpty, "\(vendor)")
            rig.transcriber.cancel()
        }
    }

    /// A server that never answers fills the bound: the stream fails with `no_session` —
    /// which the reconnect reopens — and never sends a buffer with its opening cut off.
    func testAFullPreSessionBufferFailsWithNoSessionAndTrimsNothing() async {
        let fits = Int(STTTuning.streamPreSessionBufferSeconds / STTTuning.streamChunkSeconds)
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            for index in 0..<fits { rig.transcriber.send(pcm16: vendor.chunk(UInt8(index % 250 + 1))) }
            XCTAssertTrue(rig.log.failures.isEmpty, "\(vendor): \(fits) chunks fit")

            rig.transcriber.send(pcm16: vendor.chunk(0xFF))
            await eventually("\(vendor) to fail") { !rig.log.failures.isEmpty }
            let error = rig.log.failures.first
            XCTAssertTrue(error.map { isNoSession($0, from: vendor.provider) } ?? false, "\(vendor): \(String(describing: error))")
            XCTAssertTrue(error.map(StreamReconnectPolicy.isReconnectable) ?? false, "\(vendor)")
            XCTAssertEqual(vendor.audio(of: rig.socket), [], "\(vendor): no audio was sent, trimmed or not")
            XCTAssertTrue(rig.socket.isCancelled, "\(vendor)")
            await eventually("\(vendor)'s events to end") { rig.log.hasEnded }
        }
    }

    // MARK: Lock order

    /// A send whose completion URLSession runs inside the call, with an error, re-enters
    /// the close path, which takes `lock`. That only returns because no send is made under
    /// `lock` — each site, driven off the cooperative pool where it can be, must come back.
    func testAChunkSendCompletedInsideTheCallDoesNotDeadlock() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            await rig.becomeReady()
            rig.socket.failsSend = { if case .audio = vendor.wire($0) { true } else { false } }

            let returned = expectation(description: "\(vendor): send returned")
            let transcriber = rig.transcriber
            let chunk = vendor.chunk(1)
            DispatchQueue(label: "audio").async {
                transcriber.send(pcm16: chunk)
                returned.fulfill()
            }
            await fulfillment(of: [returned], timeout: 2)
            await eventually("\(vendor) to fail") { !rig.log.failures.isEmpty }
            XCTAssertTrue(rig.socket.isCancelled, "\(vendor)")
        }
    }

    func testAFlushCompletedInsideTheCallDoesNotDeadlock() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            rig.transcriber.send(pcm16: vendor.chunk(1))
            rig.socket.failsSend = { if case .audio = vendor.wire($0) { true } else { false } }
            for message in vendor.ready { rig.socket.deliver(message) }
            await eventually("\(vendor)'s flush to fail and close") { !rig.log.failures.isEmpty && rig.log.hasEnded }
        }
    }

    func testOpenAIsSessionUpdateCompletedInsideTheCallDoesNotDeadlock() async {
        let rig = Rig(.openAI)
        rig.socket.failsSend = { Vendor.openAI.wire($0) == .sessionUpdate }
        rig.socket.deliver(Vendor.openAI.ready[0])
        await eventually("the configure to fail and close") { !rig.log.failures.isEmpty && rig.log.hasEnded }
    }

    func testTheCommitCompletedInsideTheCallDoesNotDeadlock() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            await rig.becomeReady()
            rig.socket.failsSend = { if case .commit = vendor.wire($0) { true } else { false } }
            let done = startFinish(rig.transcriber)
            await eventually("\(vendor)'s finish to return") { done.isSet }
            XCTAssertFalse(rig.log.failures.isEmpty, "\(vendor)")
        }
    }

    /// A chunk taken from `pendingAudio` reaches the socket before the stop's commit, and
    /// none after it: after the commit it would open a segment nothing closes. Chunk A is
    /// held open on the socket, chunk B queues behind it, and the stop comes in between:
    /// the commit must wait for A — `sendLock` is held across the socket call — and B,
    /// which reaches the socket after the stop took its audio, must not be sent. It cannot
    /// force the old order's window, `pendingAudio` taken before `sendLock`: NSLock hands
    /// the lock to B, the first waiter, which then lands before the commit. Which of B and
    /// the commit wins is the scheduler's, so it is run a few times.
    func testNoChunkReachesTheSocketAfterTheStopsCommit() async {
        for vendor in Vendor.allCases {
            for run in 0..<5 {
                let rig = Rig(vendor)
                await rig.becomeReady()

                let entered = DispatchSemaphore(value: 0)
                let gate = DispatchSemaphore(value: 0)
                let firstAudio = Flag()
                rig.socket.duringSend = { text in
                    guard case .audio = vendor.wire(text), !firstAudio.isSet else { return }
                    firstAudio.set()
                    entered.signal()
                    gate.wait()
                }
                let transcriber = rig.transcriber
                let (a, b) = (vendor.chunk(0xA), vendor.chunk(0xB))
                DispatchQueue(label: "audio A").async { transcriber.send(pcm16: a) }
                await withCheckedContinuation { cont in
                    DispatchQueue.global().async { entered.wait(); cont.resume() }
                }
                DispatchQueue(label: "audio B").async { transcriber.send(pcm16: b) }
                try? await Task.sleep(nanoseconds: 10_000_000)

                let done = startFinish(transcriber)
                try? await Task.sleep(nanoseconds: 10_000_000)
                XCTAssertNil(vendor.commitIndex(in: rig.socket), "\(vendor) run \(run): the commit waits for A")

                gate.signal()
                await eventually("\(vendor)'s commit") { vendor.commitIndex(in: rig.socket) != nil }
                try? await Task.sleep(nanoseconds: 5_000_000)

                let wire = vendor.wire(of: rig.socket)
                let commit = vendor.commitIndex(in: rig.socket) ?? 0
                XCTAssertEqual(wire.firstIndex(of: .audio(a)).map { $0 < commit }, true, "\(vendor) run \(run): A before the commit")
                let after = wire[(commit + 1)...].filter { if case .audio = $0 { true } else { false } }
                XCTAssertEqual(after, [], "\(vendor) run \(run): audio after the commit")

                transcriber.cancel()
                await eventually("\(vendor)'s finish to return") { done.isSet }
            }
        }
    }

    // MARK: The stop

    /// The stop commits what is pending padded with silence — a commit of under 100 ms is
    /// refused — and a reply to it ends the wait.
    func testTheStopCommitsTheTailPaddedWithSilence() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            await rig.becomeReady()
            let pending = Data(repeating: 7, count: vendor.chunkBytes / 2)
            rig.transcriber.send(pcm16: pending)

            let done = startFinish(rig.transcriber)
            await eventually("\(vendor)'s commit") { vendor.commitIndex(in: rig.socket) != nil }
            XCTAssertEqual(vendor.committedTail(of: rig.socket),
                           pending + Data(count: vendor.bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)),
                           "\(vendor)")

            await deliver(vendor.commitReply("Готово."), to: rig.socket)
            if vendor == .scribe {
                await eventually("Scribe's commit grace") { rig.clock.isSleeping(for: STTTuning.streamCommitGraceSeconds) }
                XCTAssertFalse(done.isSet, "Scribe waits out the grace")
                rig.clock.advance(by: STTTuning.streamCommitGraceSeconds)
            }
            await eventually("\(vendor)'s finish to return") { done.isSet }
            XCTAssertEqual(rig.log.committed, ["Готово."], "\(vendor)")
            XCTAssertTrue(rig.log.failures.isEmpty, "\(vendor)")
            await eventually("\(vendor)'s events to end") { rig.log.hasEnded }
            XCTAssertTrue(rig.socket.isCancelled, "\(vendor)")
        }
    }

    /// No reply never hangs the paste: the wait ends at its bound, with the stream's text
    /// as it is and no failure.
    func testTheStopsWaitIsBounded() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            await rig.becomeReady()
            let done = startFinish(rig.transcriber)
            await eventually("\(vendor)'s finish timeout") { rig.clock.isSleeping(for: STTTuning.streamFinishTimeoutSeconds) }
            XCTAssertFalse(done.isSet, "\(vendor)")

            rig.clock.advance(by: STTTuning.streamFinishTimeoutSeconds)
            await eventually("\(vendor)'s finish to return") { done.isSet }
            XCTAssertTrue(rig.log.failures.isEmpty, "\(vendor)")
            await eventually("\(vendor)'s events to end") { rig.log.hasEnded }
        }
    }

    /// Nothing is sent once the stop has taken the audio it commits.
    func testAudioAfterTheStopIsNotSent() async {
        for vendor in Vendor.allCases {
            let rig = Rig(vendor)
            await rig.becomeReady()
            let done = startFinish(rig.transcriber)
            await eventually("\(vendor)'s commit") { vendor.commitIndex(in: rig.socket) != nil }
            rig.transcriber.send(pcm16: vendor.chunk(9))
            rig.transcriber.send(pcm16: vendor.chunk(9))
            XCTAssertEqual(vendor.audio(of: rig.socket).filter { $0 == vendor.chunk(9) }, [], "\(vendor)")
            rig.transcriber.cancel()
            await eventually("\(vendor)'s finish to return") { done.isSet }
        }
    }
}

// MARK: - Scribe

final class ScribeRealtimeContractTests: XCTestCase {
    /// A commit reply may be an earlier VAD segment's, landing late. A new partial in the
    /// grace shows the final segment is still coming: it is held, not shown, and the
    /// commit after it carries its words.
    func testAPartialInTheGraceIsHeldUntilTheNextCommitCarriesIt() async {
        let rig = Rig(.scribe)
        await rig.becomeReady()
        let done = startFinish(rig.transcriber)
        await eventually("the commit") { Vendor.scribe.commitIndex(in: rig.socket) != nil }

        await deliver(Vendor.scribe.commitReply("Перше речення."), to: rig.socket)
        await eventually("the grace") { rig.clock.isSleeping(for: STTTuning.streamCommitGraceSeconds) }
        await deliver(#"{"message_type":"partial_transcript","text":"Друге"}"#, to: rig.socket)
        XCTAssertFalse(rig.clock.isSleeping(for: STTTuning.streamCommitGraceSeconds), "the partial cancels the grace")
        XCTAssertEqual(rig.log.partials, [], "a partial after a commit reply is held, not shown")

        await deliver(Vendor.scribe.commitReply("Друге речення."), to: rig.socket)
        await eventually("the grace again") { rig.clock.isSleeping(for: STTTuning.streamCommitGraceSeconds) }
        XCTAssertFalse(done.isSet)
        rig.clock.advance(by: STTTuning.streamCommitGraceSeconds)

        await eventually("finish to return") { done.isSet }
        XCTAssertEqual(rig.log.committed, ["Перше речення.", "Друге речення."])
        XCTAssertTrue(rig.log.failures.isEmpty)
    }

    /// A held partial no commit carries is either the committed segment decoded again or
    /// a tail whose commit never came; guessing either way loses, so the stream fails and
    /// the stop uploads the segment.
    func testAHeldPartialNoCommitCarriesFailsTheStream() async {
        let rig = Rig(.scribe)
        await rig.becomeReady()
        let done = startFinish(rig.transcriber)
        await eventually("the commit") { Vendor.scribe.commitIndex(in: rig.socket) != nil }

        await deliver(Vendor.scribe.commitReply("Все так, як ми домовились."), to: rig.socket)
        await deliver(#"{"message_type":"partial_transcript","text":"Всі так раптом домовились"}"#, to: rig.socket)
        await eventually("the hold's deadline") { rig.clock.isSleeping(for: STTTuning.streamCommitAfterPartialSeconds) }
        rig.clock.advance(by: STTTuning.streamCommitAfterPartialSeconds)

        await eventually("finish to return") { done.isSet }
        guard case TranscriptionError.realtime(.elevenLabs, "unresolved_tail", _)? = rig.log.failures.first else {
            return XCTFail("expected unresolved_tail, got \(rig.log.failures)")
        }
        XCTAssertEqual(rig.log.partials, [])
    }

    /// Scribe re-sends a segment it has just committed as one more partial; joined on, it
    /// pasted the dictation twice. A partial that is the committed text, whitespace aside,
    /// is dropped; the next segment growing past it is not.
    func testAPartialEchoingTheCommittedSegmentIsDropped() async {
        let rig = Rig(.scribe)
        await rig.becomeReady()
        await deliver(#"{"message_type":"partial_transcript","text":"Привіт"}"#, to: rig.socket)
        await deliver(Vendor.scribe.commitReply("Привіт, світе."), to: rig.socket)
        await deliver(#"{"message_type":"partial_transcript","text":" Привіт, світе. "}"#, to: rig.socket)
        await deliver(#"{"message_type":"partial_transcript","text":"Як справи"}"#, to: rig.socket)

        XCTAssertEqual(rig.log.partials, ["Привіт", "Як справи"])
        XCTAssertEqual(rig.log.committed, ["Привіт, світе."])
        rig.transcriber.cancel()
    }

    /// A throttled commit gets no reply: the wait ends at once, the stream intact.
    func testAThrottledCommitEndsTheWait() async {
        let rig = Rig(.scribe)
        await rig.becomeReady()
        let done = startFinish(rig.transcriber)
        await eventually("the commit") { Vendor.scribe.commitIndex(in: rig.socket) != nil }
        await deliver(#"{"message_type":"commit_throttled","error":"too little audio"}"#, to: rig.socket)
        await eventually("finish to return") { done.isSet }
        XCTAssertTrue(rig.log.failures.isEmpty)
    }
}

// MARK: - OpenAI

final class OpenAIRealtimeContractTests: XCTestCase {
    /// Transcripts arrive as increments; each item's are accumulated on their own, a
    /// partial is the whole text so far, and `.completed` replaces the item's deltas with
    /// its own transcript — the deltas stop a word short of it.
    func testDeltasAccumulatePerItemAndTheCompletedTranscriptReplacesThem() async {
        let rig = Rig(.openAI)
        await rig.becomeReady()
        func delta(_ item: String, _ text: String) -> String {
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"\#(item)","delta":"\#(text)"}"#
        }
        await deliver(delta("a", " Hel"), to: rig.socket)
        await deliver(delta("a", "lo wor"), to: rig.socket)
        await deliver(delta("b", " Next"), to: rig.socket)
        await deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":" Hello world."}"#,
                      to: rig.socket)
        await deliver(delta("b", " one"), to: rig.socket)
        await deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b"}"#, to: rig.socket)

        XCTAssertEqual(rig.log.partials, ["Hel", "Hello wor", "Next", "Hello world. Next one"])
        XCTAssertEqual(rig.log.committed, ["Hello world.", "Hello world. Next one"],
                       "cumulative, and an item completed with no transcript keeps its deltas")
        rig.transcriber.cancel()
    }

    /// A stop that beats `session.updated` waits for it, and commits behind the audio held
    /// for it — sent ahead of the session, the commit was refused as empty.
    func testAStopBeforeTheSessionIsReadyCommitsBehindTheHeldAudio() async {
        let vendor = Vendor.openAI
        let rig = Rig(vendor)
        rig.transcriber.send(pcm16: vendor.chunk(1))
        rig.transcriber.send(pcm16: vendor.chunk(2))
        let pending = Data(repeating: 3, count: vendor.chunkBytes / 2)
        rig.transcriber.send(pcm16: pending)

        let done = startFinish(rig.transcriber)
        await eventually("the ready wait") { rig.clock.isSleeping(for: STTTuning.streamSessionReadyTimeoutSeconds) }
        await deliver(vendor.ready[0], to: rig.socket)
        XCTAssertEqual(vendor.wire(of: rig.socket), [.sessionUpdate], "configured, nothing else yet")

        await deliver(vendor.ready[1], to: rig.socket)
        await eventually("the commit") { vendor.commitIndex(in: rig.socket) != nil }
        let padding = Data(count: vendor.bytes(forSeconds: STTTuning.streamCommitPaddingSeconds))
        XCTAssertEqual(vendor.wire(of: rig.socket),
                       [.sessionUpdate, .audio(vendor.chunk(1)), .audio(vendor.chunk(2)), .audio(pending + padding), .commit(Data())])

        await deliver(vendor.commitReply("Готово."), to: rig.socket)
        await eventually("finish to return") { done.isSet }
        XCTAssertEqual(rig.log.committed, ["Готово."])
        XCTAssertTrue(rig.log.failures.isEmpty)
    }

    /// A session that never becomes ready fails the stream with `no_session` at the
    /// bound, commits nothing, and leaves the segment to the upload.
    func testAStopTheSessionNeverAnswersFailsWithNoSession() async {
        let rig = Rig(.openAI)
        rig.transcriber.send(pcm16: Vendor.openAI.chunk(1))
        let done = startFinish(rig.transcriber)
        await eventually("the ready wait") { rig.clock.isSleeping(for: STTTuning.streamSessionReadyTimeoutSeconds) }
        XCTAssertFalse(done.isSet)
        rig.clock.advance(by: STTTuning.streamSessionReadyTimeoutSeconds)

        await eventually("finish to return") { done.isSet }
        let error = rig.log.failures.first
        XCTAssertTrue(error.map { isNoSession($0, from: .openAI) } ?? false, String(describing: error))
        XCTAssertTrue(error.map(StreamReconnectPolicy.isReconnectable) ?? false)
        XCTAssertNil(Vendor.openAI.commitIndex(in: rig.socket))
        XCTAssertEqual(rig.socket.sent, [])
    }

    /// A commit refused as empty gets no transcript: the wait ends, the stream intact.
    func testAnEmptyCommitEndsTheWait() async {
        let rig = Rig(.openAI)
        await rig.becomeReady()
        let done = startFinish(rig.transcriber)
        await eventually("the commit") { Vendor.openAI.commitIndex(in: rig.socket) != nil }
        await deliver(#"{"type":"error","error":{"code":"input_audio_buffer_commit_empty","message":"buffer too small"}}"#,
                      to: rig.socket)
        await eventually("finish to return") { done.isSet }
        XCTAssertTrue(rig.log.failures.isEmpty)
    }
}
