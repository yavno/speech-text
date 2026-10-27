// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

/// `CatalogueExport` is a contract with `scripts/check-vendor-models.sh`: these pin what
/// the script reads, so a change to the catalogues' types cannot quietly change it.
final class CatalogueExportTests: XCTestCase {
    private let export = CatalogueExport.current()

    func testEveryCatalogueEntryIsExportedOnce() {
        XCTAssertEqual(export.speech.map { "\($0.vendor)/\($0.id)" },
                       sttModelCatalog.map { "\($0.vendor.rawValue)/\($0.id)" })
        XCTAssertEqual(export.chat.map { "\($0.vendor)/\($0.id)" },
                       chatModelCatalog.map { "\($0.provider.vendor.rawValue)/\($0.id)" })
    }

    func testARealtimeModelNamesItsUploadTwin() throws {
        let scribe = try XCTUnwrap(export.speech.first { $0.id == elevenLabsRealtimeModel })
        XCTAssertEqual(scribe.vendor, "elevenLabs")
        XCTAssertEqual(scribe.delivery, "realtime")
        XCTAssertEqual(scribe.uploadModel, "scribe_v2")
        let openAI = try XCTUnwrap(export.speech.first { $0.id == openAIRealtimeSTTModel })
        XCTAssertEqual(openAI.uploadModel, "gpt-transcribe")
        XCTAssertTrue(export.speech.filter { $0.delivery != "realtime" }.allSatisfy { $0.uploadModel == nil })
    }

    func testPricesAreWrittenInTheVendorsOwnUnits() throws {
        let gptOSS = try XCTUnwrap(export.chat.first { $0.id == "openai/gpt-oss-120b" })
        XCTAssertEqual(gptOSS.vendor, "groq")
        XCTAssertEqual(gptOSS.price, CatalogueExport.ChatPrice(kind: "listed", inputPerMillion: 0.15,
                                                                cachedInputPerMillion: 0.075, outputPerMillion: 0.60))
        let scribe = try XCTUnwrap(export.speech.first { $0.id == "scribe_v2" })
        XCTAssertEqual(scribe.price.kind, "listed")
        XCTAssertEqual(try XCTUnwrap(scribe.price.perMinute) * 60, 0.22, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(scribe.price.keytermSurchargePerMinute) * 60, 0.05, accuracy: 1e-6)
        XCTAssertEqual(export.chat.first { $0.id == "minimaxai/minimax-m2.7" }?.price.kind, "notPriced")
        XCTAssertEqual(export.speech.first { $0.vendor == "local" }?.price.kind, "free")
    }

    func testALocalModelSaysWhereItIsDownloadedFrom() throws {
        let parakeet = try XCTUnwrap(export.speech.first { $0.id == parakeetV3ModelID })
        XCTAssertEqual(parakeet.engine, "parakeet")
        XCTAssertEqual(parakeet.source, CatalogueExport.Source(huggingFace: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                                                               path: nil, requiredFiles: parakeetRequiredBundles))
        for whisper in export.speech where whisper.engine == "whisperKit" {
            XCTAssertEqual(whisper.source, CatalogueExport.Source(huggingFace: "argmaxinc/whisperkit-coreml",
                                                                  path: whisper.id, requiredFiles: []))
        }
        for (id, repository) in [(parakeetUltraModelID, "FluidInference/parakeet-ultra-coreml"),
                                 ("parakeet-redux", "FluidInference/parakeet-redux-coreml"),
                                 ("phonon-2", "FluidInference/phonon-2-coreml")] {
            XCTAssertEqual(export.speech.first { $0.id == id }?.source?.huggingFace, repository, id)
        }
        // Bark's two builds are folders of one repository, their bundles inside the folder.
        for id in ["bark-3.0", "bark-3.0-clean"] {
            XCTAssertEqual(export.speech.first { $0.id == id }?.source,
                           .init(huggingFace: "FluidInference/bark-3.0-coreml", path: id,
                                 requiredFiles: parakeetRequiredBundles), id)
        }
        // Every local model has a source, or the script cannot check it.
        XCTAssertTrue(export.speech.filter { $0.vendor == "local" }.allSatisfy { $0.source != nil })
        XCTAssertTrue(export.chat.filter { $0.vendor == "local" }.allSatisfy { $0.source != nil })
        XCTAssertEqual(export.chat.first { $0.id == "gemma-4-12b-it-qat-q4_0" }?.source,
                       .init(huggingFace: "google/gemma-4-12B-it-qat-q4_0-gguf", path: nil,
                             requiredFiles: ["gemma-4-12b-it-qat-q4_0.gguf"]))
        XCTAssertTrue(export.chat.filter { $0.vendor != "local" }.allSatisfy { $0.source == nil })
    }

    /// Each kind of coverage, as the script tells them apart.
    func testLanguagesAreExportedByKind() {
        let byID = Dictionary(uniqueKeysWithValues: export.speech.map { ("\($0.vendor)/\($0.id)", $0.languages) })
        XCTAssertEqual(byID["apple/\(appleSpeechModelID)"]?.kind, "decidedBySystem")
        XCTAssertEqual(byID["openAI/gpt-transcribe"]?.kind, "unpublished")
        XCTAssertEqual(byID["elevenLabs/scribe_v2"]?.vendorSaysAtLeast, 90)
        XCTAssertEqual(byID["local/phonon-2"]?.codes, ["en"])
        XCTAssertTrue(export.speech.filter { $0.languages.kind == "listed" }
            .allSatisfy { $0.languages.source?.hasPrefix("https://") == true && $0.languages.codes?.isEmpty == false })
    }

    /// Each model's lifecycle, as the script reads it — the catalogue's own state, not a
    /// placeholder: a deprecated model before its shutdown, the same model retired after it.
    func testTheLifecycleIsTheCataloguesOwn() throws {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { ModelRetirement.day(y, m, d).date! }
        let before = CatalogueExport.current(on: day(2026, 10, 17))
        let mini = try XCTUnwrap(before.speech.first { $0.id == "gpt-4o-mini-transcribe" })
        XCTAssertEqual(mini.lifecycle, CatalogueExport.Lifecycle(state: "deprecated", shutdownDate: "2027-02-26"))
        let after = CatalogueExport.current(on: day(2027, 3, 1))
        XCTAssertEqual(after.speech.first { $0.id == "gpt-4o-mini-transcribe" }?.lifecycle,
                       CatalogueExport.Lifecycle(state: "retired", shutdownDate: "2027-02-26"))
        // Every entry the catalogue calls current is exported current.
        for model in sttModelCatalog where model.lifecycle == .current {
            XCTAssertEqual(before.speech.first { $0.vendor == model.vendor.rawValue && $0.id == model.id }?.lifecycle,
                           .current, model.id)
        }
        XCTAssertEqual(CatalogueExport.lifecycle(.superseded(by: "x"), on: day(2026, 10, 17)),
                       CatalogueExport.Lifecycle(state: "superseded", shutdownDate: nil))
        XCTAssertEqual(CatalogueExport.lifecycle(.deprecated(.archived(replacement: nil)), on: day(2026, 10, 17)),
                       CatalogueExport.Lifecycle(state: "retired", shutdownDate: nil))
    }

    /// The whole shape of one entry of each kind, written out as the script reads it.
    func testTheJSONShapeIsTheOneTheScriptReads() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: export.json()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["pricesChecked", "speech", "chat"])
        XCTAssertEqual(json["pricesChecked"] as? String, CatalogueExport.day(UsagePrices.checked))
        let speech = try XCTUnwrap(json["speech"] as? [[String: Any]])
        let realtime = try XCTUnwrap(speech.first { $0["id"] as? String == openAIRealtimeSTTModel })
        XCTAssertEqual(Set(realtime.keys), ["vendor", "id", "displayName", "delivery", "uploadModel", "price", "lifecycle", "languages"])
        XCTAssertEqual(realtime["vendor"] as? String, "openAI")
        XCTAssertEqual(Set(try XCTUnwrap(realtime["price"] as? [String: Any]).keys),
                       ["kind", "perMinute", "keytermSurchargePerMinute"])
        XCTAssertEqual(try XCTUnwrap(realtime["lifecycle"] as? [String: Any])["state"] as? String, "current")
        XCTAssertEqual(try XCTUnwrap(realtime["languages"] as? [String: Any]) as NSDictionary,
                       ["kind": "unpublished"] as NSDictionary)
        let local = try XCTUnwrap(speech.first { $0["id"] as? String == parakeetV3ModelID })
        XCTAssertEqual(Set(local.keys), ["vendor", "id", "displayName", "delivery", "engine", "source", "price", "lifecycle", "languages"])
        XCTAssertEqual(Set(try XCTUnwrap(local["source"] as? [String: Any]).keys), ["huggingFace", "requiredFiles"])
        let languages = try XCTUnwrap(local["languages"] as? [String: Any])
        XCTAssertEqual(Set(languages.keys), ["kind", "codes", "source", "checked"])
        XCTAssertEqual(languages["kind"] as? String, "listed")
        XCTAssertEqual(languages["source"] as? String, "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(languages["checked"] as? String, "2026-10-17")
        XCTAssertEqual((languages["codes"] as? [String])?.count, 25)
        let chat = try XCTUnwrap(json["chat"] as? [[String: Any]])
        let sonnet = try XCTUnwrap(chat.first { $0["id"] as? String == "claude-sonnet-5" })
        XCTAssertEqual(Set(sonnet.keys), ["vendor", "id", "displayName", "price", "lifecycle"])
        XCTAssertEqual(sonnet["vendor"] as? String, "anthropic")
        XCTAssertEqual(Set(try XCTUnwrap(sonnet["price"] as? [String: Any]).keys),
                       ["kind", "inputPerMillion", "cachedInputPerMillion", "outputPerMillion"])
    }
}
