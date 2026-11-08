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

    public var isPlainHTTP: Bool { base.scheme?.lowercased() == "http" }

    /// Plain HTTP off this Mac: anyone on the way can read the words and the key.
    public var isReadableOnTheWay: Bool { isPlainHTTP && place != .thisMac }

    public var place: Place {
        let host = (base.host ?? "").lowercased()
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return .thisMac }
        if host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return .network }
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") ? .network : .internet
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return .internet }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return .network
        case (172, 16...31): return .network
        // The shared range, which Tailscale's addresses come from.
        case (100, 64...127): return .network
        default: return .internet
        }
    }
}

/// How a test of the server ended, in the words Settings gives it.
public enum ServerTestResult: Equatable, Sendable {
    case answered(seconds: Double)
    case noAnswer
    case wrongPath
    case needsKey
    case noModels
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
            let (data, response) = try await session.data(for: request)
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

    /// The IDs of an OpenAI `{"data": [{"id": …}]}` list; nil for any other reply.
    static func parseModelIDs(_ data: Data) -> [String]? {
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id)
    }
}

/// `Result` needs an `Error`; this carries a `ServerTestResult` through one.
public struct ServerTestFailure: Error, Equatable, Sendable {
    public let result: ServerTestResult
    init(_ result: ServerTestResult) { self.result = result }
}
