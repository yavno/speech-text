// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A model server the user runs, at the address they wrote: a server that answers OpenAI's
/// request shapes (docs/specs/2026-11-07-own-model-server.md lists which do what).
public struct ServerEndpoint: Equatable, Sendable {
    /// Where the words go, read off the address and said under it in Settings.
    public enum Place: Equatable, Sendable {
        case thisMac, network, internet
    }

    /// The address with no trailing slash, as the servers document it: `http://host:port/v1`.
    public let base: URL

    /// Nil for what cannot be an address. A missing `/v1` is not guessed at: the test
    /// request says what went wrong.
    public init?(address: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        base = url
    }

    public var chatCompletionsURL: URL { base.appendingPathComponent("chat/completions") }
    public var modelsURL: URL { base.appendingPathComponent("models") }
    var transcriptionsURL: URL { base.appendingPathComponent("audio/transcriptions") }

    public var isPlainHTTP: Bool { base.scheme?.lowercased() == "http" }

    /// Plain HTTP off this Mac: anyone on the way can read the words and the key.
    public var isReadableOnTheWay: Bool { isPlainHTTP && place != .thisMac }

    public var place: Place {
        let host = (base.host ?? "").lowercased()
        if host == "localhost" || host == "::1" { return .thisMac }
        // Only four numbers are an IP address: `127.example.com` is a name like any other.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { part in
            // Digits only: `UInt8` would also take a leading `+`.
            part.utf8.allSatisfy { (48...57).contains($0) } ? UInt8(part) : nil
        }
        if octets.count == 4, !octets.contains(nil) {
            switch (octets[0]!, octets[1]!) {
            case (127, _): return .thisMac
            case (10, _), (192, 168), (169, 254), (172, 16...31): return .network
            // The shared range, which Tailscale's addresses come from.
            case (100, 64...127): return .network
            default: return .internet
            }
        }
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") ? .network : .internet
        }
        return host.hasSuffix(".local") || !host.contains(".") ? .network : .internet
    }
}

extension ServerEndpoint {
    /// The same scheme, host and port: where a redirect may go and still be the server
    /// the user addressed, and the one Settings described.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int?) {
            let scheme = url.scheme?.lowercased() ?? ""
            return (scheme, url.host?.lowercased() ?? "", url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil))
        }
        return origin(a) == origin(b)
    }
}

/// Refuses a redirect off the server: without it a server could send the user's words on
/// to a host Settings never named. A refused redirect comes back as the 3xx it was.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url,
              ServerEndpoint.isSameOrigin(from, to) else { return nil }
        return request
    }
}

/// How a test of the server ended, in the words Settings gives it.
public enum ServerTestResult: Equatable, Sendable {
    case answered(seconds: Double)
    case noAnswer
    case wrongPath
    case needsKey
    case noModels
    case noTranscription
    case audioRefused
    case refused(status: Int)
    case badReply

    /// What a status code on the way to the server means. Nil for a success.
    static func forStatus(_ status: Int) -> ServerTestResult? {
        switch status {
        case 200..<300: nil
        case 401, 403: .needsKey
        case 404: .wrongPath
        default: .refused(status: status)
        }
    }
}

/// Asks a server what it serves and whether it answers. Sends a fixed sentence, never the
/// user's words.
public enum ServerProbe {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // A server loads its model on the first request, which takes a while on some.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// `GET /models`: the IDs it lists, or how asking failed.
    public static func models(endpoint: ServerEndpoint, apiKey: String) async -> Result<[String], ServerTestFailure> {
        var request = URLRequest(url: endpoint.modelsURL)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects())
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failure(.init(.badReply)) }
            if let failure = ServerTestResult.forStatus(status) { return .failure(.init(failure)) }
            guard let ids = parseModelIDs(data) else { return .failure(.init(.badReply)) }
            return .success(ids)
        } catch {
            return .failure(.init(.noAnswer))
        }
    }

    /// One short chat request through the client a rewrite uses.
    public static func chat(endpoint: ServerEndpoint, model: String, apiKey: String) async -> ServerTestResult {
        let client = LLMConfiguration.makeServerChatClient(endpoint: endpoint, model: model, apiKey: apiKey)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await client.complete(system: "Reply with the single word OK.", user: "Are you there?")
            return .answered(seconds: CFAbsoluteTimeGetCurrent() - start)
        } catch LLMError.httpError(let status, _) {
            return ServerTestResult.forStatus(status) ?? .badReply
        } catch is LLMError {
            return .badReply
        } catch {
            return .noAnswer
        }
    }

    /// One transcription of a second of silence, through the transcriber a dictation uses.
    public static func transcription(endpoint: ServerEndpoint, model: String, apiKey: String) async -> ServerTestResult {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: clip) }
        do {
            try silentWAV().write(to: clip)
        } catch {
            return .badReply
        }
        let transcriber = ServerTranscriber(endpoint: endpoint, apiKey: apiKey, model: model, prompt: nil)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await transcriber.transcribe(audioFileURL: clip, language: nil)
            return .answered(seconds: CFAbsoluteTimeGetCurrent() - start)
        } catch TranscriptionError.httpError(_, let status, _) {
            return speechResult(forStatus: status)
        } catch TranscriptionError.serverNoAnswer {
            return .noAnswer
        } catch is URLError {
            return .noAnswer
        } catch {
            return .badReply
        }
    }

    /// What a status on the transcription request means: the list of models has already
    /// answered, so a 404 here is a server that does not transcribe.
    static func speechResult(forStatus status: Int) -> ServerTestResult {
        switch status {
        case 404: .noTranscription
        case 400, 413, 415, 422: .audioRefused
        default: ServerTestResult.forStatus(status) ?? .badReply
        }
    }

    /// A second of 16 kHz mono 16-bit silence, as a WAV file.
    static func silentWAV(seconds: Int = 1) -> Data {
        let rate: UInt32 = 16_000
        let bytes = UInt32(seconds) * rate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }

    /// The IDs of an OpenAI `{"data": [{"id": …}]}` list; nil for any other reply.
    static func parseModelIDs(_ data: Data) -> [String]? {
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id)
    }
}

/// Dictation through the user's server: the upload every cloud provider's OpenAI-shaped
/// transcription uses, at an address that is a setting.
struct ServerTranscriber: BatchTranscriber {
    let endpoint: ServerEndpoint?
    let apiKey: String
    let model: String
    /// The Dictionary as Whisper's free-text prompt (the spec's D3).
    let prompt: String?

    var meter: UsageMeter? { UsageMeter(vendor: .server, model: model) }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        try await transcribeMetered(audioFileURL: audioFileURL, language: language).text
    }

    func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription {
        guard let endpoint else { throw TranscriptionError.noServerAddress }
        // `response_format` is always asked for: mlx-audio answers NDJSON without it, and
        // llama.cpp answers only JSON (their sources, 2026-11-07; the spec's table).
        let upload = OpenAICompatibleUpload(url: endpoint.transcriptionsURL,
                                            fixedFields: [(name: "response_format", value: "json")], vocabulary: .prompt)
        var transcriber = OpenAICompatibleTranscriber(provider: .server, upload: upload,
                                                      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      model: model, prompt: prompt)
        transcriber.staysOnOrigin = true
        let isWAV = audioFileURL.pathExtension.lowercased() == "wav"
        let file = isWAV ? audioFileURL : try AudioBufferWriter.temporaryWAVCopy(of: audioFileURL)
        defer { if !isWAV { try? FileManager.default.removeItem(at: file) } }
        do {
            return try await transcriber.transcribeMetered(audioFileURL: file, language: language)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw TranscriptionError.serverNoAnswer
        }
    }
}

/// `Result` needs an `Error`; this carries a `ServerTestResult` through one.
public struct ServerTestFailure: Error, Equatable, Sendable {
    public let result: ServerTestResult
    init(_ result: ServerTestResult) { self.result = result }
}
