// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AVFoundation
@testable import SpeechTextCore

// MARK: - What counts as "no connection" (NetworkFailure.swift)

final class NetworkFailureTests: XCTestCase {

    /// Wi-Fi off: URLSession gives up at once with -1009, and that is the notice's case.
    func testNoInterfaceIsOffline() {
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.networkConnectionLost)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.cannotFindHost)))
        XCTAssertTrue(NetworkFailure.isOffline(URLError(.cannotConnectToHost)))
    }

    /// A timeout with the network up is a slow provider: it keeps its own wording, and
    /// the network coming back is no reason to retry it.
    func testATimeoutIsNotOffline() {
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.timedOut)))
    }

    /// A provider that answered — however badly — was reached.
    func testAProviderErrorIsNotOffline() {
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.badServerResponse)))
        XCTAssertFalse(NetworkFailure.isOffline(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(NetworkFailure.isOffline(NSError(domain: "GroqError", code: -1009)),
                       "the code alone means nothing outside URLSession's domain")
        XCTAssertFalse(NetworkFailure.isOffline(CancellationError()))
    }

    /// A socket reports the interface going away in POSIX terms, sometimes wrapped.
    func testAWrappedPOSIXNetworkDownIsOffline() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))
        XCTAssertTrue(NetworkFailure.isOffline(posix))
        let wrapped = NSError(domain: "SomeWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(NetworkFailure.isOffline(wrapped))
        XCTAssertFalse(NetworkFailure.isOffline(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
    }
}

// MARK: - Local Network access, not offline (NetworkFailure.swift, #228)

final class LocalNetworkFailureTests: XCTestCase {
    private let lan = ServerEndpoint(address: "http://192.168.1.20:8000/v1")
    private let notConnected = URLError(.notConnectedToInternet)

    /// -1009 to another device while the path is satisfied is the prompt pending or denied.
    func testNotConnectedToAnotherDeviceWhileOnlineIsLocalNetwork() {
        XCTAssertTrue(NetworkFailure.isLocalNetworkDenied(notConnected, endpoint: lan, pathSatisfied: true))
        for address in ["http://mac-mini.local:11434/v1", "http://100.101.102.103:8000/v1", "https://models.example.net/v1"] {
            XCTAssertTrue(NetworkFailure.isLocalNetworkDenied(notConnected, endpoint: ServerEndpoint(address: address),
                                                              pathSatisfied: true), address)
        }
        let wrapped = NSError(domain: "SomeWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: notConnected])
        XCTAssertTrue(NetworkFailure.isLocalNetworkDenied(wrapped, endpoint: lan, pathSatisfied: true))
    }

    /// With the path down it is offline after all.
    func testWithThePathDownItStaysOffline() {
        XCTAssertFalse(NetworkFailure.isLocalNetworkDenied(notConnected, endpoint: lan, pathSatisfied: false))
    }

    /// Loopback needs no Local Network permission.
    func testLoopbackIsNeverLocalNetwork() {
        for address in ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "http://127.1.2.3:8000/v1", "http://[::1]:8000/v1"] {
            XCTAssertFalse(NetworkFailure.isLocalNetworkDenied(notConnected, endpoint: ServerEndpoint(address: address),
                                                               pathSatisfied: true), address)
        }
        XCTAssertFalse(NetworkFailure.isLocalNetworkDenied(notConnected, endpoint: nil, pathSatisfied: true))
    }

    /// Only -1009: nothing answering, or no DNS answer, is not the permission.
    func testOtherCodesAreNotLocalNetwork() {
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut] {
            XCTAssertFalse(NetworkFailure.isLocalNetworkDenied(URLError(code), endpoint: lan, pathSatisfied: true), "\(code)")
        }
        XCTAssertFalse(NetworkFailure.isLocalNetworkDenied(NSError(domain: "GroqError", code: -1009), endpoint: lan,
                                                           pathSatisfied: true))
    }

    /// Not offline, so `OfflineRetry` never queues it.
    func testTheTypedErrorsAreNotOffline() {
        XCTAssertFalse(NetworkFailure.isOffline(TranscriptionError.localNetworkDenied))
        XCTAssertFalse(NetworkFailure.isOffline(LLMError.localNetworkDenied))
        XCTAssertFalse(NetworkFailure.isOffline(LLMError.localNetworkDenied, reachingOwnServer: true))
    }
}

// MARK: - A batch upload with no network

private final class ThrowingBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    func transcribe(audioFileURL: URL, language: String?) async throws -> String { throw error }
}

final class OfflineOutcomeTests: XCTestCase {

    /// Half a second of a sine at 48 kHz: long enough to be uploaded, loud enough to be heard.
    private func audibleWriter() -> AudioBufferWriter {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: format)
        for _ in 0 ..< 5 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for frame in 0 ..< 4_800 {
                buffer.floatChannelData![0][frame] = 0.5 * Float(sin(2.0 * .pi * 440 * Double(frame) / 48_000))
            }
            writer.append(buffer)
        }
        return writer
    }

    /// The audio is handed back for the archive, and the outcome says why it failed —
    /// which is what turns "Transcription failed" into "saved to History".
    func testAnUploadWithNoNetworkIsOfflineAndKeepsItsAudio() async throws {
        let session = BatchRecognitionSession(provider: ThrowingBatchTranscriber(URLError(.notConnectedToInternet)),
                                              writer: audibleWriter(), language: nil, languages: [])
        let outcome = await session.finish()
        let file = try XCTUnwrap(outcome.audioFileURL)
        defer { AudioBufferWriter.cleanup(fileURL: file) }

        XCTAssertTrue(outcome.offline)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.text, "")
    }

    func testAProviderErrorIsNotOffline() async throws {
        let session = BatchRecognitionSession(provider: ThrowingBatchTranscriber(URLError(.timedOut)),
                                              writer: audibleWriter(), language: nil, languages: [])
        let outcome = await session.finish()
        outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))

        XCTAssertFalse(outcome.offline)
        XCTAssertNotNil(outcome.error)
    }

    /// Kept in History with its audio, said as Local Network, and not offline, so it is
    /// not queued for the back-online retry.
    func testALocalNetworkDenialKeepsItsAudioAndIsNotOffline() async throws {
        let session = BatchRecognitionSession(provider: ThrowingBatchTranscriber(TranscriptionError.localNetworkDenied),
                                              writer: audibleWriter(), language: nil, languages: [])
        let outcome = await session.finish()
        let file = try XCTUnwrap(outcome.audioFileURL)
        defer { AudioBufferWriter.cleanup(fileURL: file) }

        XCTAssertTrue(outcome.localNetworkDenied)
        XCTAssertFalse(outcome.offline)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.usage, [])
    }
}

// MARK: - When saved dictations are retried (OfflineRetryQueue.swift)

final class OfflineRetryQueueTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    /// The monitor's first report is the current state, not the network coming back.
    func testTheFirstReportIsNoEdge() {
        var fresh = OfflineRetryQueue()
        XCTAssertFalse(fresh.enqueue(a), "nothing is known about the network yet")
        XCTAssertFalse(fresh.networkChanged(isUp: true), "a first report of 'up' is not a return")
    }

    /// Wi-Fi off, dictate twice, Wi-Fi on: one drain, oldest first.
    func testTheNetworkComingBackDrainsOldestFirst() {
        var queue = OfflineRetryQueue()
        XCTAssertFalse(queue.networkChanged(isUp: false))
        XCTAssertFalse(queue.enqueue(a))
        XCTAssertFalse(queue.enqueue(b))
        XCTAssertTrue(queue.networkChanged(isUp: true))

        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertNil(queue.beginDrain(), "one drain at a time")
        XCTAssertEqual(queue.finished(a, .succeeded), b)
        XCTAssertNil(queue.finished(b, .succeeded))
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertFalse(queue.isDraining)
    }

    /// Nothing waiting: the network coming back does nothing.
    func testAnEmptyQueueIgnoresTheNetwork() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        XCTAssertFalse(queue.networkChanged(isUp: true))
    }

    /// Still no network for the first: it and everything behind it wait for the next return.
    func testFindingNoNetworkAgainStopsTheDrainAndKeepsEverything() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertNil(queue.finished(a, .offline))
        XCTAssertEqual(queue.pending, [a, b])
        XCTAssertFalse(queue.isDraining)

        _ = queue.networkChanged(isUp: false)
        XCTAssertTrue(queue.networkChanged(isUp: true))
        XCTAssertEqual(queue.beginDrain(), a)
    }

    /// Any other failure — or a record the user retried or deleted — leaves the queue,
    /// and the drain goes on to the next.
    func testADroppedRecordLeavesAndTheDrainGoesOn() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertEqual(queue.finished(a, .dropped), b)
        XCTAssertEqual(queue.pending, [b])
    }

    /// The link dropped mid-upload and was back before the failure was written: no edge
    /// will come, so the record is tried at once.
    func testARecordQueuedWhileTheNetworkIsUpIsTriedAtOnce() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: true)
        XCTAssertTrue(queue.enqueue(a))
        XCTAssertFalse(queue.enqueue(a), "queued once")
    }

    /// One the user is retrying right now is passed over, not dropped: should their
    /// retry find no network, the next return still owes it one.
    func testARecordTheUserIsRetryingIsPassedOverAndKept() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertEqual(queue.finished(a, .busy), b)
        XCTAssertNil(queue.finished(b, .succeeded), "the busy one is not retried again in this drain")
        XCTAssertEqual(queue.pending, [a])
        XCTAssertFalse(queue.isDraining)
        XCTAssertEqual(queue.beginDrain(), a, "a later drain takes it")
    }

    /// A dictation saved during a drain joins it rather than starting another.
    func testARecordQueuedDuringADrainJoinsIt() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertFalse(queue.enqueue(c), "the running drain picks it up")
        XCTAssertEqual(queue.finished(a, .succeeded), c)
    }

    /// A fast Wi-Fi roam: the network went and came back while a retry was out, and that
    /// retry then reported no network — its error was from before the return. No edge is
    /// left to start the next drain, so the one that ended owes one.
    func testANetworkReturnDuringADrainIsNotLost() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertFalse(queue.networkChanged(isUp: false))
        XCTAssertFalse(queue.networkChanged(isUp: true), "a drain is running")

        XCTAssertNil(queue.finished(a, .offline))
        XCTAssertEqual(queue.pending, [a, b])
        XCTAssertTrue(queue.drainOwed)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertFalse(queue.drainOwed, "the drain it was owed has begun")
    }

    /// Only a return during the drain is owed one. No network with no return — a portal
    /// whose path reports satisfied, say — waits for the next edge, as it always did; a
    /// return followed by another loss before the drain ended has an edge still to come.
    func testFindingNoNetworkOwesADrainOnlyForAReturnDuringIt() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        XCTAssertNil(queue.finished(a, .offline))
        XCTAssertFalse(queue.drainOwed, "no return during the drain")

        _ = queue.networkChanged(isUp: false)
        XCTAssertTrue(queue.networkChanged(isUp: true))
        XCTAssertEqual(queue.beginDrain(), a)
        _ = queue.networkChanged(isUp: false)
        _ = queue.networkChanged(isUp: true)
        _ = queue.networkChanged(isUp: false)
        XCTAssertNil(queue.finished(a, .offline))
        XCTAssertFalse(queue.drainOwed, "the network is down: its return will start the drain")
        XCTAssertTrue(queue.networkChanged(isUp: true))
    }

    /// A return during a drain that then went well owes nothing.
    func testAReturnDuringADrainThatEndsWellOwesNothing() {
        var queue = OfflineRetryQueue()
        _ = queue.networkChanged(isUp: false)
        _ = queue.enqueue(a); _ = queue.enqueue(b)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), a)
        _ = queue.networkChanged(isUp: false)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.finished(a, .succeeded), b)
        XCTAssertNil(queue.finished(b, .succeeded))
        XCTAssertFalse(queue.drainOwed)

        _ = queue.enqueue(c)
        _ = queue.networkChanged(isUp: false)
        _ = queue.networkChanged(isUp: true)
        XCTAssertEqual(queue.beginDrain(), c)
        XCTAssertNil(queue.finished(c, .offline))
        XCTAssertFalse(queue.drainOwed, "the return before this drain was its own edge")
    }
}

// MARK: - When a stream is reopened (NetworkFailure.swift › StreamReconnectPolicy)

final class StreamReconnectPolicyTests: XCTestCase {

    func testANetworkDropIsReopened() {
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.networkConnectionLost)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(URLError(.timedOut)))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))))
    }

    /// Held audio filled up with no session to send it to: the server never answered.
    func testNoSessionIsReopened() {
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "no_session", "…")))
        XCTAssertTrue(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "no_session", "…")))
    }

    /// A refusal would only be heard again from a new socket.
    func testARefusalIsNotReopened() {
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "auth_error", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.elevenLabs, "quota_exceeded", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "invalid_api_key", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(TranscriptionError.realtime(.openAI, "transcription_failed", "…")))
        XCTAssertFalse(StreamReconnectPolicy.isReconnectable(URLError(.userAuthenticationRequired)))
    }

    /// About 26 s of trying per outage, and three outages per segment.
    func testTheAttemptsAndOutagesAreBounded() {
        let policy = StreamReconnectPolicy()
        XCTAssertEqual(policy.delay(attempt: 0, outage: 1), 0.5)
        XCTAssertNotNil(policy.delay(attempt: 7, outage: 1))
        XCTAssertNil(policy.delay(attempt: 8, outage: 1))
        XCTAssertNotNil(policy.delay(attempt: 0, outage: 3))
        XCTAssertNil(policy.delay(attempt: 0, outage: 4))
        XCTAssertEqual(policy.delays.reduce(0, +), 26.5, accuracy: 0.01)
    }
}

// MARK: - One socket at a time (StreamingRecognitionSession.swift)

/// A socket the test drives by hand, counting what the session asks of it.
private final class CountingStreamingTranscriber: StreamingTranscriber, @unchecked Sendable {
    let sampleRate = AudioBufferWriter.uploadSampleRate
    let events: AsyncStream<StreamingSTTEvent>
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation
    private let lock = NSLock()
    private var sent = 0
    private var sentAfterFinish = 0
    private var cancelled = 0
    private var finishing = false
    private var finishHook: (() -> Void)?
    /// Run inside `finish()` once it has begun — where a tap buffer that arrives after
    /// the stop lands, behind the commit. Held under `lock` like the counts: the test
    /// sets it on main and `finish()` reads it off main.
    var duringFinish: (() -> Void)? {
        get { lock.withLock { finishHook } }
        set { lock.withLock { finishHook = newValue } }
    }

    init() {
        (events, continuation) = AsyncStream<StreamingSTTEvent>.makeStream()
    }

    var sends: Int { lock.withLock { sent } }
    var sendsAfterFinish: Int { lock.withLock { sentAfterFinish } }
    var cancels: Int { lock.withLock { cancelled } }

    func emit(_ event: StreamingSTTEvent) { continuation.yield(event) }

    func connect(languages: [String]) {}
    func send(pcm16: Data) {
        lock.withLock {
            sent += 1
            if finishing { sentAfterFinish += 1 }
        }
    }
    func finish() async {
        // Taken under `lock` and run outside it: the hook feeds the session, whose
        // `send` takes the same lock.
        let hook = lock.withLock { () -> (() -> Void)? in
            finishing = true
            return finishHook
        }
        hook?()
        continuation.finish()
    }
    func cancel() {
        lock.withLock { cancelled += 1 }
        continuation.finish()
    }
}

@MainActor
final class StreamingSessionSocketTests: XCTestCase {
    private var opened: [CountingStreamingTranscriber] = []

    private static let tapBuffer = AVAudioPCMBuffer(
        pcmFormat: AVAudioFormat(standardFormatWithSampleRate: AudioBufferWriter.uploadSampleRate, channels: 1)!,
        frameCapacity: 1)!

    /// Long enough that a second report of the same drop is handled before the reconnect
    /// fires, as it is with the app's half-second first wait.
    private let wait: TimeInterval = 0.15

    private func session(_ first: CountingStreamingTranscriber) -> StreamingRecognitionSession {
        StreamingRecognitionSession(
            provider: first, writer: AudioBufferWriter(), languages: [],
            fallback: ScriptedSegment(text: ""),
            reconnect: { [unowned self] in
                MainActor.assumeIsolated {
                    let next = CountingStreamingTranscriber()
                    self.opened.append(next)
                    return next
                }
            },
            policy: StreamReconnectPolicy(delays: Array(repeating: wait, count: 8), maxOutages: 2))
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A socket that drops reports it from more than one thread — the receive loop's error
    /// and a send's completion — and a report each used to open a socket of its own: the
    /// first never got audio, was never closed, and the drop counted as two outages. One
    /// drop is one reconnect, the socket it replaces is closed, and a later drop of the new
    /// socket is still ridden out.
    func testOneDropReportedTwiceOpensOneSocket() async throws {
        let first = CountingStreamingTranscriber()
        let session = session(first)
        try session.start()
        defer { session.cancel() }

        first.emit(.partial("Кілька слів"))
        first.emit(.failed(URLError(.networkConnectionLost)))
        first.emit(.failed(URLError(.networkConnectionLost)))
        await waitUntil { !opened.isEmpty }
        await settle(wait * 3)

        XCTAssertEqual(opened.count, 1, "one drop, one new socket")
        XCTAssertGreaterThanOrEqual(first.cancels, 1, "the socket replaced is closed")
        let second = try XCTUnwrap(opened.first)
        XCTAssertEqual(second.cancels, 0)

        // The second outage of the segment — the first counted once — is ridden out too.
        second.emit(.partial("ще кілька"))
        second.emit(.failed(URLError(.networkConnectionLost)))
        await waitUntil { opened.count > 1 }
        XCTAssertEqual(opened.count, 2, "a drop of the new socket is a drop of its own")
        XCTAssertGreaterThanOrEqual(second.cancels, 1)
    }

    /// A tap buffer that arrives once the stop has begun — the engine stops its tap
    /// asynchronously — is not sent: on the socket it would land behind the stop's commit,
    /// in a segment that never closes.
    func testAFeedAfterTheStopBeganIsNotSent() async throws {
        let provider = CountingStreamingTranscriber()
        let session = session(provider)
        try session.start()

        session.feed(native: Self.tapBuffer, pcm16: Data(count: 3_200))
        XCTAssertEqual(provider.sends, 1)

        provider.duringFinish = { [weak session] in
            session?.feed(native: Self.tapBuffer, pcm16: Data(count: 3_200))
        }
        _ = await session.finish()
        provider.duringFinish = nil

        XCTAssertEqual(provider.sendsAfterFinish, 0)
        XCTAssertEqual(provider.sends, 1)
    }
}

/// The rate-limit headers each vendor answers with, read into what is left of each window.
final class RateLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroqsAndOpenAIsHeadersAreReadWithTheirDurations() throws {
        let snapshot = try XCTUnwrap(RateLimits.parse(vendor: .groq, model: "openai/gpt-oss-120b", headers: [
            "x-ratelimit-limit-requests": "14400", "x-ratelimit-remaining-requests": "14370",
            "x-ratelimit-reset-requests": "2m59.56s",
            "X-RateLimit-Limit-Tokens": "18000", "x-ratelimit-remaining-tokens": "17997",
            "x-ratelimit-reset-tokens": "7.66s", "content-type": "application/json",
        ], now: now))
        XCTAssertEqual(snapshot.windows.map(\.name), ["requests", "tokens"])
        let requests = snapshot.windows[0]
        XCTAssertEqual(requests.limit, 14400)
        XCTAssertEqual(requests.remaining, 14370)
        XCTAssertEqual(try XCTUnwrap(requests.resetsAt).timeIntervalSince(now), 179.56, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(requests.used), 30.0 / 14400, accuracy: 1e-9)
        XCTAssertEqual(snapshot.windows[1].resetsAt?.timeIntervalSince(now) ?? 0, 7.66, accuracy: 0.001)
        XCTAssertEqual(RateLimits.logLine(snapshot), "requests 14370 of 14400 · tokens 17997 of 18000")
    }

    func testAnthropicsHeadersAreReadWithTheirTimes() throws {
        let snapshot = try XCTUnwrap(RateLimits.parse(vendor: .anthropic, model: "claude-sonnet-5", headers: [
            "anthropic-ratelimit-requests-limit": "50", "anthropic-ratelimit-requests-remaining": "49",
            "anthropic-ratelimit-requests-reset": "2027-01-15T08:00:30Z",
            "anthropic-ratelimit-input-tokens-limit": "30000", "anthropic-ratelimit-input-tokens-remaining": "27000",
        ], now: now))
        XCTAssertEqual(snapshot.windows.map(\.name), ["input-tokens", "requests"])
        XCTAssertEqual(snapshot.windows[1].remaining, 49)
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
    }

    func testAWindowAVendorAddsLaterIsKeptAndAReplyWithNoneHasNoSnapshot() {
        let audio = RateLimits.parse(vendor: .groq, model: "whisper-large-v3-turbo",
                                     headers: ["x-ratelimit-remaining-audio-seconds": "7100"], now: now)
        XCTAssertEqual(audio?.windows, [RateLimitWindow(name: "audio-seconds", remaining: 7100)])
        XCTAssertNil(RateLimits.parse(vendor: .elevenLabs, model: "scribe_v2", headers: ["request-id": "x"], now: now))
    }

    func testResetDurationsInGosNotation() {
        XCTAssertEqual(RateLimits.duration("1h2m3.5s"), 3723.5)
        XCTAssertEqual(RateLimits.duration("120ms"), 0.12)
        XCTAssertEqual(RateLimits.duration("6m0s"), 360)
        XCTAssertNil(RateLimits.duration("soon"))
        XCTAssertNil(RateLimits.duration(""))
    }
}
