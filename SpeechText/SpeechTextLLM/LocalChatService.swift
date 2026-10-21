// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates

/// The SpeechTextLLM service: llama.cpp in a process of its own, answering the app over
/// XPC (`LocalChatServiceProtocol`). One model in memory, one completion at a time —
/// `LocalLlamaRuntime` is an actor and runs its jobs in order.
///
/// Idle, the service exits: the weights are mapped from disk and the KV cache is
/// gigabytes, which a menu bar app has no business holding between dictations. launchd
/// starts it again on the next message, and the next rewrite pays the load.
/// `@unchecked Sendable`: XPC calls it on any thread; `activity` and `idleTimer` are held
/// under `lock`, and the runtime serialises its own jobs.
final class LocalChatService: NSObject, LocalChatServiceProtocol, @unchecked Sendable {
    static let shared = LocalChatService()

    /// As long as Ollama kept a model loaded by default.
    static let idleExitSeconds: TimeInterval = 300

    private let runtime = LocalLlamaRuntime()
    private let lock = NSLock()
    private var activity = LocalChatActivity()
    private var idleTimer: DispatchSourceTimer?

    func complete(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let request = try? JSONDecoder().decode(LocalChatRequest.self, from: request) else {
            reply(nil, "The request could not be read."); return
        }
        let id = request.id
        begin()
        Task {
            defer { self.end(id) }
            do {
                // Asked at every step, since a cancel can come while this request waits behind
                // a prewarm or while its model loads: the reply nobody wants is never
                // generated, and the next rewrite does not wait behind it.
                try self.stopIfCancelled(id)
                let load = try await self.load(request)
                try self.stopIfCancelled(id)
                // A rewrite is about as long as what it rewrites: a long selection is given
                // room for its own length, not the floor alone, and the context bounds it.
                let input = try await runtime.tokenize(request.user).count
                let completion = try await runtime.complete(
                    system: request.system, user: request.user,
                    maxTokens: ChatTemplates.replyTokens(atLeast: request.maxTokens, forInputTokens: input),
                    shouldCancel: { self.isCancelled(id) })
                let response = LocalChatResponse(
                    reply: completion.reply, promptTokens: completion.promptTokens,
                    outputTokens: completion.outputTokens, loadSeconds: load,
                    promptSeconds: completion.promptSeconds, generationSeconds: completion.generationSeconds,
                    finished: completion.finished)
                reply(try JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func prewarm(_ request: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let request = try? JSONDecoder().decode(LocalChatRequest.self, from: request) else {
            reply("The request could not be read."); return
        }
        begin()
        Task {
            defer { self.end(nil) }
            do {
                _ = try await self.load(request)
                try await runtime.cache(systems: request.prefixes ?? [])
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func cancel(_ requestID: String) { lock.withLock { activity.cancel(requestID) } }

    private func isCancelled(_ requestID: String) -> Bool { lock.withLock { activity.isCancelled(requestID) } }

    private func stopIfCancelled(_ requestID: String) throws {
        if isCancelled(requestID) { throw LlamaError.cancelled }
    }

    /// A job like any other, so a service that this message started arms its idle exit
    /// rather than staying up holding nothing.
    func unload(_ modelPath: String, reply: @escaping @Sendable () -> Void) {
        begin()
        Task {
            defer { self.end(nil) }
            await runtime.unload(ifLoaded: modelPath)
            reply()
        }
    }

    /// Refuses a model the Mac cannot hold: the weights plus room for the context and
    /// macOS. A load past that does not fail — it pages, and the rewrite takes minutes.
    private func load(_ request: LocalChatRequest) async throws -> Double {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: request.modelPath))?[.size] as? UInt64 ?? 0
        guard bytes > 0 else { throw LlamaError.loadFailed(request.modelPath) }
        let headroom: UInt64 = 3 * 1_073_741_824
        guard ProcessInfo.processInfo.physicalMemory >= bytes + headroom else { throw LocalChatServiceError.notEnoughMemory }
        return try await runtime.load(path: request.modelPath, family: request.family,
                                      contextLength: request.contextLength)
    }

    // MARK: - Idle exit

    private func begin() {
        lock.withLock {
            activity.begin()
            idleTimer?.cancel()
            idleTimer = nil
        }
    }

    private func end(_ requestID: String?) {
        lock.withLock {
            activity.end(requestID)
            guard activity.running == 0 else { return }
            let mark = activity.started
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Self.idleExitSeconds)
            timer.setEventHandler { [weak self] in self?.exitIfIdle(armedAt: mark) }
            idleTimer = timer
            timer.resume()
        }
    }

    /// Freeing the model takes hundreds of milliseconds, and a request can come in during
    /// them. So idleness is asked again once it is the runtime queue's turn, before the
    /// model goes, and again under the lock before the exit: a request that began keeps the
    /// service and the model it loads, and its own end arms the timer again. Never with the
    /// lock held across the unload — the queue's jobs take it to read their cancels.
    private func exitIfIdle(armedAt mark: Int) {
        let idle = { self.lock.withLock { self.activity.mayExit(armedAt: mark) } }
        guard idle() else { return }
        // Freed first: ggml asserts at exit while Metal still holds a model.
        runtime.unloadNow(if: idle)
        lock.withLock {
            guard activity.mayExit(armedAt: mark) else { return }
            exit(0)
        }
    }
}

enum LocalChatServiceError: LocalizedError {
    case notEnoughMemory

    var errorDescription: String? {
        "This Mac doesn't have the memory for this model. Choose a smaller one in Settings › AI Rewrite."
    }
}

final class LocalChatServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LocalChatServiceProtocol.self)
        connection.exportedObject = LocalChatService.shared
        connection.resume()
        return true
    }
}
