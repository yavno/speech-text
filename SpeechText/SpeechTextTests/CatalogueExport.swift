// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// The catalogues as JSON, for `scripts/check-vendor-models.sh`, which compares them
// with what each vendor serves. Written by `SpeechTextEvaluation --export-catalogue`, so
// the script reads the catalogues the app is built from and keeps no list of its own.
// Pure logic, shared by that tool and `CatalogueExportTests`, which pin the shape: the
// script depends on it.

struct CatalogueExport: Encodable, Equatable {
    /// `UsagePrices.checked`, as `yyyy-MM-dd`: the prices below are the vendors' as of then.
    let pricesChecked: String
    let speech: [SpeechModel]
    let chat: [ChatModel]

    struct SpeechModel: Encodable, Equatable {
        /// `Provider`'s raw value — the one History stores.
        let vendor: String
        let id: String
        let displayName: String
        /// `upload`, `realtime`, `onDevice` or `systemRecognizer`.
        let delivery: String
        /// A realtime model's upload twin, which must exist at the vendor as well.
        let uploadModel: String?
        /// `whisperKit` or `parakeet`, for a model on the Mac.
        let engine: String?
        /// Where a model on the Mac is downloaded from.
        let source: Source?
        let price: SpeechPrice
        let lifecycle: Lifecycle
        /// What the model knows (`LanguageCoverage`), so the script can compare a published
        /// list with the vendor's source.
        let languages: Languages
    }

    /// `listed` (with the codes, the page they were read from, when, and the vendor's own
    /// "90+" where it gives one), `unpublished` or `decidedBySystem`.
    struct Languages: Encodable, Equatable {
        let kind: String
        let codes: [String]?
        let source: String?
        let checked: String?
        let vendorSaysAtLeast: Int?
    }

    struct ChatModel: Encodable, Equatable {
        let vendor: String
        let id: String
        let displayName: String
        /// A model on this Mac: the GGUF file it downloads. Nil for a cloud model.
        let source: Source?
        let price: ChatPrice
        let lifecycle: Lifecycle
    }

    /// A Hugging Face model repository, the folder inside it (nil for the whole
    /// repository) and the files that folder must hold for the model to install.
    struct Source: Encodable, Equatable {
        let huggingFace: String
        let path: String?
        let requiredFiles: [String]
    }

    struct SpeechPrice: Encodable, Equatable {
        /// `free`, `listed` or `notPriced`.
        let kind: String
        let perMinute: Double?
        let keytermSurchargePerMinute: Double?
    }

    struct ChatPrice: Encodable, Equatable {
        let kind: String
        let inputPerMillion: Double?
        let cachedInputPerMillion: Double?
        let outputPerMillion: Double?
    }

    /// Where a model stands with its vendor: `current`, `superseded`, `deprecated` or
    /// `retired`, and the vendor's shutdown date (`yyyy-MM-dd`) once one is announced.
    struct Lifecycle: Encodable, Equatable {
        let state: String
        let shutdownDate: String?

        static let current = Lifecycle(state: "current", shutdownDate: nil)
    }
}

extension CatalogueExport {
    /// The catalogues as they are compiled into this build, their lifecycle states read on
    /// `day` (a deprecated model past its shutdown is retired).
    static func current(on day: Date = Date()) -> CatalogueExport {
        CatalogueExport(
            pricesChecked: Self.day(UsagePrices.checked),
            speech: sttModelCatalog.map { speechModel($0, on: day) },
            chat: chatModelCatalog.map { chatModel($0, on: day) }
        )
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// A descriptor's `ModelLifecycle` as the script reads it. *Retired* is not a state of
    /// its own in the catalogue: it is how a deprecated model reads once its shutdown date
    /// has passed (`ModelLifecycle.status(on:)`), and an archived one, whose dates are not
    /// kept, is retired with no date.
    static func lifecycle(_ lifecycle: ModelLifecycle, on day: Date) -> Lifecycle {
        switch lifecycle {
        case .current:
            return .current
        case .superseded:
            return Lifecycle(state: "superseded", shutdownDate: nil)
        case .deprecated(let deprecation):
            guard let shutdown = deprecation.shutdown.date else { return Lifecycle(state: "retired", shutdownDate: nil) }
            return Lifecycle(state: day < shutdown ? "deprecated" : "retired",
                             shutdownDate: Self.day(deprecation.shutdown))
        }
    }

    static func speechModel(_ model: STTModelDescriptor, on day: Date = Date()) -> SpeechModel {
        var delivery = ""
        var engine: LocalSTTEngine?
        switch model.delivery {
        case .upload: delivery = "upload"
        case .realtime: delivery = "realtime"
        case .onDevice(let local): delivery = "onDevice"; engine = local
        case .systemRecognizer: delivery = "systemRecognizer"
        }
        var uploadModel: String?
        if case .model(let id) = model.batchUpload { uploadModel = id }
        let price: SpeechPrice = switch model.price {
        case .free: SpeechPrice(kind: "free", perMinute: nil, keytermSurchargePerMinute: nil)
        case .notPriced: SpeechPrice(kind: "notPriced", perMinute: nil, keytermSurchargePerMinute: nil)
        case .listed(let rates):
            SpeechPrice(kind: "listed", perMinute: rounded(rates.perMinute),
                        keytermSurchargePerMinute: rounded(rates.keytermSurchargePerMinute))
        }
        return SpeechModel(vendor: model.vendor.rawValue, id: model.id, displayName: model.displayName,
                           delivery: delivery, uploadModel: uploadModel, engine: engine?.rawValue,
                           source: engine.flatMap { source(of: model.id, engine: $0) },
                           price: price, lifecycle: lifecycle(model.lifecycle, on: day), languages: languages(model.languages))
    }

    static func languages(_ coverage: LanguageCoverage) -> Languages {
        switch coverage {
        case .listed(let list):
            Languages(kind: "listed", codes: list.codes, source: list.source.absoluteString,
                      checked: day(list.checked), vendorSaysAtLeast: list.vendorSaysAtLeast)
        case .unpublished:
            Languages(kind: "unpublished", codes: nil, source: nil, checked: nil, vendorSaysAtLeast: nil)
        case .decidedBySystem:
            Languages(kind: "decidedBySystem", codes: nil, source: nil, checked: nil, vendorSaysAtLeast: nil)
        }
    }

    static func chatModel(_ model: ChatModelDescriptor, on day: Date = Date()) -> ChatModel {
        let price: ChatPrice = switch model.price {
        case .free: ChatPrice(kind: "free", inputPerMillion: nil, cachedInputPerMillion: nil, outputPerMillion: nil)
        case .notPriced: ChatPrice(kind: "notPriced", inputPerMillion: nil, cachedInputPerMillion: nil, outputPerMillion: nil)
        case .listed(let rates):
            ChatPrice(kind: "listed", inputPerMillion: rounded(rates.inputPerToken * 1e6),
                      cachedInputPerMillion: rounded(rates.cachedInputPerToken * 1e6),
                      outputPerMillion: rounded(rates.outputPerToken * 1e6))
        }
        // The pinned file of a model on this Mac (`LocalChatCatalog.swift`), checked by
        // the script like a speech model's folder.
        let source = model.provider == .local ? localChatModel(id: model.id).map {
            Source(huggingFace: $0.repository, path: nil, requiredFiles: [$0.file])
        } : nil
        return ChatModel(vendor: model.provider.vendor.rawValue, id: model.id, displayName: model.displayName,
                         source: source, price: price, lifecycle: lifecycle(model.lifecycle, on: day))
    }

    /// Where each local engine's models come from: WhisperKit's are folders of
    /// `argmaxinc/whisperkit-coreml` named by the catalogue ID (`LocalWhisperRuntime.swift`),
    /// each Parakeet build is FluidAudio's repository for its `ParakeetVersion`
    /// (`ParakeetBuild`, `LocalParakeetRuntime.swift`). A Parakeet model added without a
    /// repository here exports none, and the script says so rather than checking the wrong one.
    static func source(of id: String, engine: LocalSTTEngine) -> Source? {
        switch engine {
        case .whisperKit:
            Source(huggingFace: "argmaxinc/whisperkit-coreml", path: id, requiredFiles: [])
        case .parakeet:
            parakeetRepository(localSTTModel(id: id)?.parakeetVersion).map {
                Source(huggingFace: $0.repository, path: $0.folder, requiredFiles: parakeetRequiredBundles)
            }
        }
    }

    /// The repository, and for a build that shares one with another, its folder in it —
    /// Bark 3.0 and Bark 3.0 Clean are the two folders of one repository, whose required
    /// bundles are then inside that folder.
    static func parakeetRepository(_ version: ParakeetVersion?) -> (repository: String, folder: String?)? {
        switch version {
        case .v3: ("FluidInference/parakeet-tdt-0.6b-v3-coreml", nil)
        case .ultra: ("FluidInference/parakeet-ultra-coreml", nil)
        case .redux: ("FluidInference/parakeet-redux-coreml", nil)
        case .phonon2: ("FluidInference/phonon-2-coreml", nil)
        case .bark3: ("FluidInference/bark-3.0-coreml", "bark-3.0")
        case .bark3Clean: ("FluidInference/bark-3.0-coreml", "bark-3.0-clean")
        case nil: nil
        }
    }

    /// Prices are stored per token or per minute; written back per million or per minute
    /// they would carry binary noise (0.15000000000000002) into the comparison.
    static func rounded(_ value: Double) -> Double {
        (value * 1e9).rounded() / 1e9
    }

    static func day(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
