// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates
import SpeechTextCore

/// AI Rewrite on this Mac: a `ChatClient` that sends the request to the SpeechTextLLM
/// service over XPC. App target only — the test bundle has no service to talk to, and
/// reaches this through the `LocalChat` box.
struct LocalChatClient: ChatClient {
    let model: LocalChatModel

    /// Long enough for a cold load of the largest model and a long reply on a slow Mac;
    /// past it the rewrite is cancelled and the transcript pasted instead.
    static let timeoutSeconds: UInt64 = 180

    func complete(system: String, user: String) async throws -> ChatReply {
        let path = localChatModelFile(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { throw LocalChatError.notInstalled(model) }
        let request = LocalChatRequest.rewrite(model: model, path: path, system: system, user: user)
        let body = try JSONEncoder().encode(request)
        let response: LocalChatResponse = try await LocalChatConnection.shared.call(cancelling: request.id) { service, finish in
            service.complete(body) { data, error in
                if let data, let response = try? JSONDecoder().decode(LocalChatResponse.self, from: data) {
                    finish(.success(response))
                } else {
                    finish(.failure(LocalChatError.service(error ?? "no reply")))
                }
            }
        }
        dlog("LLM", String(format: "local %@: load %.1fs, prompt %d tok %.1fs, reply %d tok %.1fs%@",
                           model.id, response.loadSeconds, response.promptTokens, response.promptSeconds,
                           response.outputTokens, response.generationSeconds, response.finished ? "" : ", cut off"))
        // A reply that ran out of room is only the start of one: pasted, it would end a
        // dictation mid-sentence, and an edit would put it in place of the whole
        // selection. Thrown, the dictation is pasted as said and the selection put back.
        // Out of room in the context, the text was too long for the model; out of the
        // reply's own budget, the model ran on.
        guard response.finished else {
            if response.promptTokens + response.outputTokens + 1 >= request.contextLength {
                throw LocalChatError.tooLong
            }
            throw LLMError.cutOff
        }
        guard !response.reply.isEmpty else { throw LLMError.emptyResponse }
        return ChatReply(text: response.reply,
                         usage: ChatUsage(inputTokens: response.promptTokens, outputTokens: response.outputTokens))
    }
}

enum LocalChatError: LocalizedError {
    case notInstalled(LocalChatModel)
    case service(String)
    case interrupted
    case timedOut
    /// The reply filled the model's context before it ended.
    case tooLong

    var errorDescription: String? {
        switch self {
        case .notInstalled(let model): "\(model.displayName) isn't downloaded — download it in Settings › AI Rewrite."
        case .service(let message): message
        case .interrupted: "The local model stopped unexpectedly. The next rewrite starts it again."
        case .timedOut: "The local model took too long to answer."
        case .tooLong: "The text is too long for the model on this Mac to rewrite in full."
        }
    }
}

/// The one connection to the service. launchd starts the service on the first message
/// and again after it exits (idle, or a crash): an interrupted connection stays usable, so
/// only an invalidated one is replaced. `@unchecked Sendable`: `connection` and
/// `serviceMayBeRunning` are held under `lock`.
final class LocalChatConnection: @unchecked Sendable {
    static let shared = LocalChatConnection()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Something was sent since the service last exited, so it may hold a model. Its idle
    /// exit interrupts the connection, which then stays open: a message would start it again.
    private var serviceMayBeRunning = false

    /// The connection every request and prewarm goes over; whatever is sent over it starts
    /// the service.
    private func current() -> NSXPCConnection {
        lock.withLock {
            serviceMayBeRunning = true
            if let connection { return connection }
            let connection = NSXPCConnection(serviceName: localChatServiceName)
            connection.remoteObjectInterface = NSXPCInterface(with: LocalChatServiceProtocol.self)
            connection.interruptionHandler = { [weak self] in
                self?.lock.withLock { self?.serviceMayBeRunning = false }
            }
            connection.invalidationHandler = { [weak self] in
                self?.lock.withLock {
                    self?.connection = nil
                    self?.serviceMayBeRunning = false
                }
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    /// The service over the connection already open, or nil — never a connection opened for
    /// this: a cancel for a request that was never sent has nothing to stop, and launching
    /// the service for it would only start a process that holds nothing. `onlyIfRunning`:
    /// nil too once the service has exited, for a message that has nothing to do there.
    private func existingService(onlyIfRunning: Bool = false) -> LocalChatServiceProtocol? {
        let connection = lock.withLock { onlyIfRunning && !serviceMayBeRunning ? nil : self.connection }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? LocalChatServiceProtocol
    }

    /// One request: the reply, or the error the connection ended with. A cancelled task
    /// or a reply that never comes (a timeout) stops the completion named `requestID` in
    /// the service, and only that one; a task already cancelled sends nothing.
    func call<T: Sendable>(cancelling requestID: String? = nil,
                           _ body: @escaping @Sendable (LocalChatServiceProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.store(continuation)
                // A task cancelled before this point ran its cancel handler while there was
                // no continuation to end — so it ends here, and the request is never sent.
                guard !Task.isCancelled else { once.finish(.failure(CancellationError())); return }
                let proxy = current().remoteObjectProxyWithErrorHandler { error in
                    let nsError = error as NSError
                    once.finish(.failure(nsError.code == NSXPCConnectionInterrupted ? LocalChatError.interrupted : error))
                }
                guard let service = proxy as? LocalChatServiceProtocol else {
                    once.finish(.failure(LocalChatError.interrupted)); return
                }
                Task {
                    try? await Task.sleep(nanoseconds: LocalChatClient.timeoutSeconds * 1_000_000_000)
                    if once.finish(.failure(LocalChatError.timedOut)), let requestID { service.cancel(requestID) }
                }
                body(service, { once.finish($0) })
            }
        } onCancel: {
            if once.finish(.failure(CancellationError())), let requestID { self.existingService()?.cancel(requestID) }
        }
    }

    /// Loads the model and reads both system prompts in the service: the user is speaking
    /// meanwhile, and the rewrite at the stop then starts from them (14 s cold for Gemma 4
    /// 12B on an M1 Pro, 3 s warm). Fire and forget — a failure here is the request's own.
    func prewarm(_ model: LocalChatModel) {
        let path = localChatModelFile(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let presets = PromptPresetStore.load()
        var request = LocalChatRequest.rewrite(model: model, path: path, system: "", user: "")
        request.prefixes = [
            TextRefinementService.buildSystemPrompt(presets: presets,
                                                    defaultPresetID: PromptPresetStore.storedDefaultPresetID()),
            TextRefinementService.buildEditSystemPrompt(presets: presets),
        ]
        guard let body = try? JSONEncoder().encode(request) else { return }
        (current().remoteObjectProxyWithErrorHandler { _ in } as? LocalChatServiceProtocol)?.prewarm(body) { error in
            if let error { dlog("LLM", "prewarm \(model.id) failed: \(error)", level: .error) }
        }
    }

    #if DEBUG
    func proxy() -> Any { current().remoteObjectProxyWithErrorHandler { _ in } }
    #endif

    /// Unloads a removed model if the service holds it. A service that is not running holds
    /// nothing, and is not started to be told so.
    func release(_ model: LocalChatModel) {
        existingService(onlyIfRunning: true)?.unload(localChatModelFile(for: model).path) {}
    }
}

/// Resumes a continuation exactly once, whichever of the reply, the error handler, the
/// timeout or the cancel gets there first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    /// Under the lock, as `finish` reads it: a cancel handler runs on another thread.
    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

extension LocalChatRequest {
    /// What AI Rewrite asks of a local model: 8K tokens of context (the prompt is about
    /// 1–2K, the reply rarely more), and a reply budget well past any dictation — the
    /// least it gets: the service gives a longer message room for its own length
    /// (`ChatTemplates.replyTokens`), as far as the context goes.
    static func rewrite(model: LocalChatModel, path: URL, system: String, user: String) -> LocalChatRequest {
        LocalChatRequest(modelPath: path.path, family: model.family, system: system, user: user,
                         maxTokens: 2048, contextLength: 8192)
    }
}

/// Points the `LocalChat` box at the service. Called at launch, beside `registerLocalSTT()`.
func registerLocalChat() {
    LocalChat.clientFactory = { LocalChatClient(model: $0) }
    LocalChat.prewarm = { LocalChatConnection.shared.prewarm($0) }
    LocalChat.release = { LocalChatConnection.shared.release($0) }
}

#if DEBUG
/// `-SPTLocalChatSmoke <file.gguf> <family>`: a debug build sends two rewrites through the
/// real SpeechTextLLM service — the first reads the system prompt, the second restores
/// it — prints both, and quits. The one way to run the XPC path without opening the app's
/// windows; the model file is named directly, so no download and no setting is touched.
enum LocalChatSmoke {
    @MainActor
    static func runIfAsked() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-SPTLocalChatSmoke"), arguments.count > flag + 2,
              let family = ChatTemplateFamily(rawValue: arguments[flag + 2]) else { return false }
        let path = arguments[flag + 1]
        let system = TextRefinementService.buildSystemPrompt(presets: PromptPresetStore.builtInDefaults,
                                                             defaultPresetID: nil)
        let transcripts = ["е-е ну завтра зустріч переноситься на третю годину бо Олена ще не повернулась",
                           "напиши лист Андрію що звіт я надішлю в понеділок"]
        Task {
            // As at the start of an AI dictation: the model and the system prompt are read
            // while the user speaks.
            let warming = Date()
            var warm = LocalChatRequest(modelPath: path, family: family, system: "", user: "", maxTokens: 0, contextLength: 8192)
            warm.prefixes = [system]
            // A fourth argument is how long the user speaks: the request then goes that many
            // seconds after the prewarm starts, whether or not it has finished.
            let speaking = arguments.count > flag + 3 ? Double(arguments[flag + 3]) : nil
            if let body = try? JSONEncoder().encode(warm) {
                if let speaking {
                    (LocalChatConnection.shared.proxy() as? LocalChatServiceProtocol)?.prewarm(body) { _ in }
                    try? await Task.sleep(nanoseconds: UInt64(speaking * 1e9))
                    print(String(format: "SMOKE spoke %.1fs, request sent", speaking))
                } else {
                    let error: String? = try? await LocalChatConnection.shared.call { service, finish in
                        service.prewarm(body) { finish(.success($0)) }
                    }
                    print(String(format: "SMOKE prewarm %.2fs %@", Date().timeIntervalSince(warming), error ?? "ok"))
                }
            }
            for transcript in transcripts {
                let request = LocalChatRequest(modelPath: path, family: family, system: system,
                                               user: TextRefinementService.userMessage(transcript: transcript, context: nil),
                                               maxTokens: 512, contextLength: 8192)
                let started = Date()
                do {
                    let body = try JSONEncoder().encode(request)
                    let response: LocalChatResponse = try await LocalChatConnection.shared.call { service, finish in
                        service.complete(body) { data, error in
                            if let data, let response = try? JSONDecoder().decode(LocalChatResponse.self, from: data) {
                                finish(.success(response))
                            } else {
                                finish(.failure(LocalChatError.service(error ?? "no reply")))
                            }
                        }
                    }
                    print(String(format: "SMOKE ok %.2fs (load %.2f, prompt %d tok %.2fs, reply %d tok %.2fs): %@",
                                 Date().timeIntervalSince(started), response.loadSeconds, response.promptTokens,
                                 response.promptSeconds, response.outputTokens, response.generationSeconds,
                                 response.reply.replacingOccurrences(of: "\n", with: " ⏎ ")))
                } catch {
                    print("SMOKE failed after \(Date().timeIntervalSince(started))s: \(error.localizedDescription)")
                }
            }
            fflush(stdout)
            exit(0)
        }
        return true
    }
}
#endif
