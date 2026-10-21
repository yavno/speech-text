// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - First run

/// The steps of the setup window, in order. The raw values are what `onboardingStep`
/// stores, so a window closed half-way opens where it was left.
public enum OnboardingStep: String, CaseIterable, Comparable, Sendable {
    case welcome
    case speech
    case ai
    case permissions
    case tryIt = "try"
    case done

    /// The five the step bar names; Done is the Try it step's second state, not a stop.
    public static let named: [OnboardingStep] = [.welcome, .speech, .ai, .permissions, .tryIt]

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .speech: "Speech"
        case .ai: "AI"
        case .permissions: "Permissions"
        case .tryIt, .done: "Try it"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.index < rhs.index }
}

/// Whether the setup window opens at launch.
///
/// Only new users see it. There was no first-run marker before it existed, so an install
/// that predates it is recognised by what it already stored: a login-item registration,
/// or any setting that crosses a rename (which is also how a renamed install is caught,
/// once `adoptPreRenameDefaults()` has carried its settings over). Such a user is marked
/// done and never shown a flow for a setup they finished long ago.
public enum OnboardingGate: Equatable, Sendable {
    case show
    /// An existing install: record setup as done, show nothing.
    case markCompleted
    case skip

    public static func decide(completed: Bool?, hasUsedTheAppBefore: Bool) -> OnboardingGate {
        switch completed {
        case true?: .skip
        case false?: .show
        case nil: hasUsedTheAppBefore ? .markCompleted : .show
        }
    }
}

// MARK: - The online services setup offers

/// A card on setup's Speech step: the service, the engine choosing it saves, and its words.
public struct SpeechServiceCard: Sendable {
    public let service: Provider
    public let engine: STTProviderType
    public let title: String
    public let subtitle: String
    public let detail: String
    /// The card promises the words while speaking, so choosing it saves the provider's
    /// realtime model; otherwise the stored model is left as it is.
    let promisesLiveWords: Bool

    public init(service: Provider, engine: STTProviderType, title: String, subtitle: String, detail: String,
                promisesLiveWords: Bool) {
        self.service = service
        self.engine = engine
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.promisesLiveWords = promisesLiveWords
    }

    /// The model choosing the card saves, or nil to leave the stored one.
    public var savedModel: String? {
        promisesLiveWords ? offeredSTTModels(of: service).first(where: \.isRealtime)?.id : nil
    }
}

/// A card on setup's AI step: the service, the AI Rewrite pick choosing it saves, and its words.
public struct AIServiceCard: Sendable {
    public let service: Provider
    public let pick: LLMProviderType
    public let title: String
    public let subtitle: String

    public init(service: Provider, pick: LLMProviderType, title: String, subtitle: String) {
        self.service = service
        self.pick = pick
        self.title = title
        self.subtitle = subtitle
    }
}

/// Which online services get a card in setup — the maintainer's choice, not every
/// provider — in card order. Every service setup can hold comes from one of these lists,
/// so the look-ups below find a card; the first card is what a stored value that should
/// never have selected anything else falls back to.
public enum SetupCards {
    public static let speech: [SpeechServiceCard] = [
        SpeechServiceCard(service: .groq, engine: .groq, title: "Groq", subtitle: "Free plan",
                          detail: "The same key also turns on AI text polish.", promisesLiveWords: false),
        SpeechServiceCard(service: .elevenLabs, engine: .elevenlabs, title: "ElevenLabs", subtitle: "Paid",
                          detail: "Shows your words live as you speak.", promisesLiveWords: true),
        SpeechServiceCard(service: .openAI, engine: .openai, title: "OpenAI", subtitle: "Paid",
                          detail: "Shows your words live too. The same key also turns on AI text polish.",
                          promisesLiveWords: true),
    ]

    public static let ai: [AIServiceCard] = [
        AIServiceCard(service: .groq, pick: .groq, title: "Groq", subtitle: "Free plan"),
        AIServiceCard(service: .anthropic, pick: .anthropic, title: "Claude", subtitle: "Anthropic · Paid"),
        AIServiceCard(service: .openAI, pick: .openai, title: "ChatGPT", subtitle: "OpenAI · Paid"),
    ]

    /// The Speech card for a service, else the first.
    public static func speech(for service: Provider) -> SpeechServiceCard {
        speech.first { $0.service == service } ?? speech[0]
    }

    /// The AI card for a service, else the first.
    public static func ai(for service: Provider) -> AIServiceCard {
        ai.first { $0.service == service } ?? ai[0]
    }

    /// The card setup opens on when run again with this engine stored; nil for an engine
    /// with no card (Apple, the Mac).
    public static func speechCard(reopening engine: STTProviderType) -> SpeechServiceCard? {
        speech.first { $0.engine == engine }
    }

    /// The AI card setup opens on when run again with this AI Rewrite pick stored; nil for
    /// a pick with no card (Ollama, which opens on the Mac's card instead).
    public static func aiCard(reopening pick: LLMProviderType) -> AIServiceCard? {
        ai.first { $0.pick == pick }
    }
}

/// The order Settings › API Keys lists the providers with a key in: the speech step's
/// first, as a dictation runs, then AI Rewrite's only.
public enum APIKeyPage {
    public static var order: [Provider] {
        Provider.allCases.filter { $0.descriptor.roles.contains(.speech) }
            + Provider.allCases.filter { !$0.descriptor.roles.contains(.speech) }
    }
}

public enum KeyVerdict: Equatable, Sendable {
    case valid
    case invalid
    /// No answer about the key: offline, or the service is down. The user may go on.
    case unreachable
}

// MARK: - The disk image it came in

/// A disk image macOS has mounted, as `hdiutil info -plist` describes it: the `.dmg` file
/// and where its volume is.
public struct MountedDiskImage: Equatable, Sendable {
    public let imagePath: String
    let mountPoint: String

    /// Every mounted image that has a volume. An image attached without one (a raw
    /// device, a partition map) has no mount point and is left out.
    public static func parse(hdiutilInfo data: Data) -> [MountedDiskImage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
            else { return nil }
            return MountedDiskImage(imagePath: path, mountPoint: mount)
        }
    }
}

/// Where the running copy of the app is, relative to the disk image it was downloaded in.
///
/// A drag into Applications is a Finder copy, and nothing runs when it finishes — so the
/// app cannot launch itself after one. What it can do is recognise the two states around
/// that copy: opened straight from the image, where it has to move itself first or it
/// stops working the moment the image is ejected. The image, once the app is installed,
/// is the user's to eject and throw away.
public enum InstallLocation: Equatable, Sendable {
    /// Running from inside a mounted image. `image` is nil when that is known only from
    /// App Translocation's path and no mounted image carries the app.
    case inDiskImage(MountedDiskImage?)
    case installed

    /// `appName` is the bundle's name without `.app`. An image counts as this app's when
    /// its file or its volume is named for it ("SpeechText-0.9.0.dmg", "SpeechText 0.9.0"):
    /// looking inside the volume for the app would be a file read on a mounted volume,
    /// which macOS may answer with a privacy prompt — at launch.
    ///
    /// A quarantined app opened from an image does not run from `/Volumes/…`: macOS
    /// translocates it to a random read-only path under `AppTranslocation`, and that path
    /// names no volume. So a translocated app is matched to the image that carries it.
    /// An app run from anywhere else (Xcode's build folder, `~/Applications`) counts as
    /// installed — a development build must never be asked to move.
    public static func decide(bundlePath: String, appName: String, images: [MountedDiskImage]) -> InstallLocation {
        func carriesThisApp(_ image: MountedDiskImage) -> Bool {
            [image.imagePath, image.mountPoint].contains {
                ($0 as NSString).lastPathComponent.lowercased().hasPrefix(appName.lowercased())
            }
        }
        func isInside(_ image: MountedDiskImage) -> Bool {
            let mount = image.mountPoint.hasSuffix("/") ? image.mountPoint : image.mountPoint + "/"
            return bundlePath.hasPrefix(mount)
        }
        if let image = images.first(where: isInside) {
            return .inDiskImage(image)
        }
        if bundlePath.contains("/AppTranslocation/") {
            return .inDiskImage(images.first(where: carriesThisApp))
        }
        return .installed
    }
}

// MARK: - A key, shown

/// How a stored API key is shown: enough of each end to tell two keys apart, never the
/// middle. The vendor's prefix ("gsk_", "sk-ant-") is the same for every key it issues,
/// so four characters after it and the last four are what tells one key from another.
public enum APIKeyDisplay {
    public static func masked(_ key: String, prefix: String? = nil) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = prefix.flatMap { key.hasPrefix($0) ? $0.count : nil } ?? 0
        // Less than eight characters past the prefix would show most of the key.
        guard key.count >= lead + 12 else { return String(repeating: "•", count: min(key.count, 12)) }
        return String(key.prefix(lead + 4)) + "…" + String(key.suffix(4))
    }
}
