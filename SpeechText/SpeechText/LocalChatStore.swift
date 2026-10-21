// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import SpeechTextCore

/// The chat models on disk: what is downloaded, what is downloading, and removing them.
/// The speech models' `LocalModelStore` with the same states, apart because a chat model
/// is one GGUF file from a pinned URL rather than an engine's own download — so the
/// download, its resume and its hash check are ours.
///
/// A download goes to `Models/.downloads/llm-<id>/`, keeps URLSession's resume data there
/// when it is interrupted (a 12 GB file over a train's Wi-Fi), is checked against the
/// catalogue's SHA-256, and only then is moved to `Models/llm/<id>/` — so a file under its
/// final name is always a whole, verified one, which is all `isLocalChatModelInstalled` asks.
@Observable
@MainActor
final class LocalChatStore {
    static let shared = LocalChatStore()

    typealias InstallState = LocalModelStore.InstallState

    private(set) var states: [String: InstallState] = [:]
    private var downloads: [String: GGUFDownload] = [:]

    private init() { refresh() }

    func state(for model: LocalChatModel) -> InstallState {
        states[model.id] ?? (isLocalChatModelInstalled(model) ? .installed : .notInstalled)
    }

    /// Read from `states` rather than the disk, as the speech store's is: Settings asks on
    /// every render. Only `.installed` — a chat model's `.optimizing` is the hash check,
    /// before the file is under its final name.
    var installedModels: [LocalChatModel] { localChatModels.filter { state(for: $0) == .installed } }

    var installedBytes: Int64 { installedModels.reduce(0) { $0 + $1.downloadBytes } }

    func refresh() {
        for model in localChatModels where !(states[model.id]?.isBusy ?? false) {
            states[model.id] = isLocalChatModelInstalled(model) ? .installed : .notInstalled
        }
    }

    private func staging(for model: LocalChatModel) -> URL {
        localModelsDirectory().appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("llm-\(model.id)", isDirectory: true)
    }

    func install(_ model: LocalChatModel) {
        guard !state(for: model).isBusy, !isLocalChatModelInstalled(model) else { return }
        // The history store's pre-rename migration runs only while `SpeechText/` does not
        // exist yet; creating `Models/` first would strand an old install's history.
        _ = TranscriptionHistory.shared

        let staging = staging(for: model)
        // An interrupted download's partial file is already on the disk, so only the rest
        // of it has to fit — otherwise a cancelled download could never be resumed.
        if let shortfall = localModelDiskShortfall(downloadBytes: model.downloadBytes,
                                                   alreadyOnDisk: GGUFDownload.bytesOnDisk(in: staging),
                                                   freeDiskBytes: SystemCapabilities.current().freeDiskBytes) {
            states[model.id] = .failed(shortfall.localizedDescription)
            dlog("LocalModel", "download of \(model.id) refused: \(shortfall.localizedDescription)", level: .notice)
            return
        }
        let destination = localChatModelFile(for: model)
        states[model.id] = .downloading(fraction: 0)
        dlog("LocalModel", "downloading \(model.id) (\(model.downloadSizeDescription))")

        let throttle = DownloadProgressThrottle()
        let download = GGUFDownload(staging: staging, expectedBytes: model.downloadBytes) { [weak self] fraction in
            guard let fraction = throttle.admit(fraction) else { return }
            Task { @MainActor [weak self] in
                // Not once the hash check began: a late report would turn it back into a download.
                guard let self, case .downloading? = self.states[model.id] else { return }
                self.states[model.id] = .downloading(fraction: fraction)
            }
        }
        downloads[model.id] = download
        Task { [weak self] in
            do {
                let file = try await download.run(url: model.downloadURL)
                await MainActor.run { [weak self] in self?.states[model.id] = .optimizing }
                // Checked off the main actor: hashing 19 GB takes some seconds.
                let digest = try await Task.detached(priority: .utility) { try sha256Hex(of: file) }.value
                guard digest == model.sha256 else {
                    try? FileManager.default.removeItem(at: staging)
                    throw LocalChatStoreError.checksumMismatch
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                try? FileManager.default.removeItem(at: staging)
                dlog("LocalModel", "installed \(model.id)")
                // Loaded once now, in the service, so the first rewrite does not pay for it.
                LocalChat.prewarm(model)
                await MainActor.run { [weak self] in
                    self?.states[model.id] = .installed
                    self?.downloads[model.id] = nil
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run { [weak self] in
                    self?.states[model.id] = cancelled ? .notInstalled : .failed(error.localizedDescription)
                    self?.downloads[model.id] = nil
                    dlog("LocalModel", "download of \(model.id) \(cancelled ? "cancelled" : "failed: \(error.localizedDescription)")")
                }
            }
        }
    }

    /// Stops the download. What arrived is kept with its resume data, so the next
    /// download of the same model carries on from there instead of starting again.
    func cancelInstall(_ model: LocalChatModel) {
        downloads[model.id]?.cancel()
    }

    func remove(_ model: LocalChatModel) {
        cancelInstall(model)
        LocalChat.release(model)
        try? FileManager.default.removeItem(at: localChatModelFile(for: model).deletingLastPathComponent())
        try? FileManager.default.removeItem(at: staging(for: model))
        states[model.id] = .notInstalled
        dlog("LocalModel", "removed \(model.id)")
    }
}

enum LocalChatStoreError: LocalizedError {
    case checksumMismatch
    case incomplete

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: "The download was damaged. Try again."
        case .incomplete: "The download ended early. Try again to continue it."
        }
    }
}

/// SHA-256 of a file as lowercase hex, read in 8 MB pieces so a 19 GB model is never in
/// memory whole.
func sha256Hex(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// One file's download, resumable. URLSession hands the finished file over in a temporary
/// location that is deleted when its delegate call returns, so it is moved into `staging`
/// there; an interrupted download leaves its resume data in `staging/resume.data`, and
/// beside it in `resume.bytes` how much of the file that partial download holds.
/// `@unchecked Sendable`: URLSession calls it on its own queue, and what that shares with
/// `run` and `cancel` — the continuation, the task, `onDisk` — is held under `lock`;
/// `session` is set once, before the task starts.
final class GGUFDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let staging: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    /// What the partial file holds: the offset a resume started at, plus every write since.
    /// Counted from `bytesWritten` rather than read off `totalBytesWritten`, which leaves
    /// unsaid whether a resumed download's earlier bytes are in it.
    private var onDisk: Int64 = 0

    private var resumeFile: URL { staging.appendingPathComponent("resume.data") }
    private var resumeBytesFile: URL { staging.appendingPathComponent("resume.bytes") }
    private var partFile: URL { staging.appendingPathComponent("model.gguf") }

    /// The bytes an interrupted download in `staging` holds on disk, which its resume does
    /// not fetch again; 0 with no resume data.
    static func bytesOnDisk(in staging: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent("resume.data").path),
              let text = try? String(contentsOf: staging.appendingPathComponent("resume.bytes"), encoding: .utf8)
        else { return 0 }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    init(staging: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.staging = staging
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func run(url: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                if let data = try? Data(contentsOf: resumeFile) {
                    try? FileManager.default.removeItem(at: resumeFile)
                    try? FileManager.default.removeItem(at: resumeBytesFile)
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: url)
                }
                task?.resume()
            }
        }
    }

    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel(byProducingResumeData: { [weak self] data in self?.keep(data) })
    }

    private func keep(_ resumeData: Data?) {
        guard let resumeData else { return }
        let onDisk = lock.withLock { self.onDisk }
        try? resumeData.write(to: resumeFile, options: .atomic)
        try? String(onDisk).write(to: resumeBytesFile, atomically: true, encoding: .utf8)
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.withLock { onDisk = fileOffset }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { onDisk += bytesWritten }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        progress(min(1, max(0, Double(totalBytesWritten) / Double(max(total, 1)))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: partFile)
            try FileManager.default.moveItem(at: location, to: partFile)
            let size = (try? FileManager.default.attributesOfItem(atPath: partFile.path))?[.size] as? Int64 ?? 0
            finish(size == expectedBytes ? .success(partFile) : .failure(LocalChatStoreError.incomplete))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        keep((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        finish(.failure(error))
    }
}
