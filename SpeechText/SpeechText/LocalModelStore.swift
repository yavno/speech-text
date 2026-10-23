// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// MARK: - Store

/// Owns the models on disk: what is installed, what is downloading, and where it lives.
///
/// `@MainActor` because the Settings view observes it directly; the actual download runs
/// off it in a `Task`.
@Observable
@MainActor
final class LocalModelStore {
    static let shared = LocalModelStore()

    enum InstallState: Equatable {
        case notInstalled
        /// 0…1. Stays at 0 until the first progress callback, which for a cold start is
        /// the HuggingFace file listing rather than any bytes.
        case downloading(fraction: Double)
        /// On disk, being loaded for the first time. Core ML specialises a model for this
        /// Mac's Neural Engine on its first load, and that is not quick: 45 s for Whisper
        /// Small and **9 minutes** for Turbo on an M1 Pro (measured 2026-09-17). The model
        /// is already usable — a dictation started now simply waits for the same load — but
        /// without this state Settings would say "installed" while nothing seems to happen.
        case optimizing
        case installed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .optimizing: true
            default: false
            }
        }

        /// On disk and selectable — an optimising model already works, it is just slow to
        /// answer until its first load finishes.
        var isUsable: Bool { self == .installed || self == .optimizing }
    }

    private(set) var states: [String: InstallState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// The runtime each engine installs and transcribes through. Injectable as one
    /// closure rather than one property, because the catalogue now holds two families at
    /// once: a download is dispatched per *model*, not once for the store.
    var runtime: (LocalSTTEngine) -> LocalSTTRuntime = defaultRuntime

    /// The real pairing, named once so a test that swaps `runtime` can put it back, and
    /// so the two engines are listed in one place rather than at each call site.
    static let defaultRuntime: (LocalSTTEngine) -> LocalSTTRuntime = { engine in
        switch engine {
        case .whisperKit: WhisperKitRuntime()
        case .parakeet: ParakeetRuntime()
        }
    }

    private init() {
        refresh()
    }

    // MARK: Paths

    /// Paths and the installed test live in `LocalModelCatalog.swift` — they are plain
    /// filesystem logic with no actor and no third-party code, so the recognition tier
    /// can ask from any thread without going through this store.
    static var modelsDirectory: URL { localModelsDirectory() }

    func folder(for modelID: String) -> URL { localModelFolder(for: modelID) }

    func isInstalled(_ modelID: String) -> Bool { isLocalModelInstalled(modelID) }

    func state(for modelID: String) -> InstallState {
        states[modelID] ?? (isInstalled(modelID) ? .installed : .notInstalled)
    }

    /// Read from `states`, which the launch, `refresh`, an install and a remove keep, not
    /// from the disk: Settings asks on every render, and a download renders it often.
    /// `.optimizing` counts — the model is already in its folder.
    var installedModels: [LocalSTTModel] {
        localSTTModels.filter { state(for: $0.id).isUsable }
    }

    /// True when at least one model is ready, which is what the engine picker needs to
    /// know before it offers the local tier as usable.
    var hasAnyModel: Bool { !installedModels.isEmpty }

    /// The local model the settings select, when it is not on this Mac yet — what a
    /// failed dictation's Retry would only fail on again, so it offers Install instead.
    /// Nil for another engine, a cleared choice (`""` asks for a pick, not a download),
    /// an ID the catalogue does not know, a model this macOS cannot run, and a model
    /// already usable.
    func missingSelectedModel(engine: String, modelID: String) -> LocalSTTModel? {
        guard engine == STTProviderType.local.rawValue, !modelID.isEmpty,
              let model = Self.offeredHere.first(where: { $0.id == modelID }),
              !state(for: model.id).isUsable
        else { return nil }
        return model
    }

    /// The models this Mac's macOS can run, read once: a History row asks on every render,
    /// and neither the catalogue nor the macOS version changes while the app runs.
    private static let offeredHere = offeredLocalSTTModels(for: SystemCapabilities.current())

    func refresh() {
        for model in localSTTModels where !(states[model.id]?.isBusy ?? false) {
            states[model.id] = isInstalled(model.id) ? .installed : .notInstalled
        }
    }

    // MARK: Install / remove

    func install(_ model: LocalSTTModel) {
        guard !state(for: model.id).isBusy, !isInstalled(model.id) else { return }

        // Touching the history store first runs its one-shot pre-rename migration, which
        // is skipped if `Application Support/SpeechText/` already exists. Creating the
        // Models directory before that would silently strand an old install's history.
        _ = TranscriptionHistory.shared

        // A failed or cancelled install deletes its staging, so nothing of it is on disk.
        if let shortfall = localModelDiskShortfall(downloadBytes: model.downloadBytes,
                                                   freeDiskBytes: SystemCapabilities.current().freeDiskBytes) {
            states[model.id] = .failed(shortfall.localizedDescription)
            dlog("LocalModel", "install of \(model.id) refused: \(shortfall.localizedDescription)", level: .notice)
            return
        }

        states[model.id] = .downloading(fraction: 0)
        dlog("LocalModel", "installing \(model.id) (\(model.downloadSizeDescription))")

        let destination = folder(for: model.id)
        // Per-model staging, so two models downloading at once never share (or delete)
        // each other's half-written files.
        let staging = Self.modelsDirectory.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
        let runtime = runtime(model.engine)
        let throttle = DownloadProgressThrottle()

        tasks[model.id] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

                let downloaded = try await runtime.download(variant: model.id, into: staging) { [weak self] fraction in
                    guard let fraction = throttle.admit(fraction) else { return }
                    Task { @MainActor [weak self] in
                        // A report that lands after the download ended must not turn
                        // "getting ready" back into a download.
                        guard let self, case .downloading? = self.states[model.id] else { return }
                        self.states[model.id] = .downloading(fraction: fraction)
                    }
                }
                try Task.checkCancellation()

                // Move into our own layout, replacing any half-finished previous attempt.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: downloaded, to: destination)
                try? FileManager.default.removeItem(at: staging)

                await MainActor.run { [weak self] in
                    self?.states[model.id] = .optimizing
                    dlog("LocalModel", "installed \(model.id), optimising for this Mac")
                }
                // Pay the one-time specialisation now, while the user is still in Settings,
                // rather than on their first dictation. A failure here is not an install
                // failure — the model is on disk and the next load will try again.
                // Through the path every prewarm takes, which unloads the other engine's
                // model first: every install is of a model about to be used — setup selects
                // it before the download, Settings once it is usable, which it was from
                // `.optimizing` — so it replaces the one resident rather than joining it.
                do {
                    try await prewarmLocalModel(model, with: runtime)
                } catch {
                    dlog("LocalModel", "prewarm of \(model.id) failed: \(error.localizedDescription)", level: .error)
                }
                // Downloaded and not taken (Settings closed before it was ready): the model
                // dictations use is loaded again, and this one goes.
                prewarmSelectedLocalModel(unlessItIs: model.id)
                await MainActor.run { [weak self] in
                    self?.states[model.id] = .installed
                    self?.tasks[model.id] = nil
                }
            } catch is CancellationError {
                // A cancelled download is hundreds of megabytes the user said they don't want.
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { [weak self] in
                    self?.states[model.id] = .notInstalled
                    self?.tasks[model.id] = nil
                    dlog("LocalModel", "install of \(model.id) cancelled")
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { [weak self] in
                    self?.states[model.id] = .failed(error.localizedDescription)
                    self?.tasks[model.id] = nil
                    dlog("LocalModel", "install of \(model.id) failed: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    func cancelInstall(_ model: LocalSTTModel) {
        tasks[model.id]?.cancel()
    }

    func remove(_ model: LocalSTTModel) {
        cancelInstall(model)
        LocalSTT.releaseModel(model.id)
        try? FileManager.default.removeItem(at: folder(for: model.id))
        states[model.id] = .notInstalled
        dlog("LocalModel", "removed \(model.id)")
    }

    /// Bytes currently occupied by installed models — shown in Settings so the user can
    /// see what a local engine is costing them before they go looking in Finder.
    var installedBytes: Int64 {
        installedModels.reduce(0) { $0 + $1.downloadBytes }
    }
}
