// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What this Mac can be expected to run a local speech model on.
///
/// A plain value, never a singleton: `recommendedLocalSTTModel(for:)` takes one as a
/// *parameter* so the recommendation is a pure function of hardware rather than a
/// function of the machine the test happens to run on. `current()` is the only part
/// that touches sysctl, and nothing else in the app calls sysctl directly.
public struct SystemCapabilities: Equatable, Sendable {
    /// `machdep.cpu.brand_string` — "Apple M1 Pro", "Intel(R) Core(TM) i7-9750H…".
    public let chipName: String
    /// Apple Silicon has a Neural Engine; Core ML puts the Whisper encoder on it, which
    /// is the whole reason a 600 MB model is usable for dictation. Intel has no ANE and
    /// falls back to CPU/GPU, where the large models stop being interactive.
    public let isAppleSilicon: Bool
    /// Physical cores across every performance level. Only a total: the levels are not
    /// a fixed pair — an M1 reports Performance + Efficiency, an M5 reports Super +
    /// Performance — so splitting them into two named fields mislabels one generation or
    /// the other, and nothing here needs the split anyway.
    let cores: Int
    public let memoryBytes: UInt64
    /// Free space on the volume the model store writes to — a download that fills the
    /// disk is the one failure the user cannot undo from inside the app.
    public let freeDiskBytes: UInt64
    /// The running macOS's major version (14 for Sonoma, 15 for Sequoia, 26 for Tahoe):
    /// some local models need a newer Core ML than the app's own minimum (`isOffered(on:)`).
    public let systemMajorVersion: Int

    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }

    /// A one-line description for the Settings row, so the recommendation can say what
    /// it based itself on rather than asking the user to trust it.
    var summary: String {
        let ram = memoryGB.rounded()
        return "\(chipName) · \(Int(ram)) GB RAM · \(cores) cores"
    }

    /// `storageURL` is where models would be written. It is a parameter rather than a
    /// reference to `LocalModelStore` so this file stays free of app-graph dependencies
    /// and can be compiled into the test target.
    public static func current(storageURL: URL? = defaultStorageProbe) -> SystemCapabilities {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        let arm = sysctlUInt64("hw.optional.arm64") == 1

        // Sum every performance level rather than assuming two: `hw.nperflevels` is 2 on
        // an M1 (Performance, Efficiency) and names them differently on an M5 (Super,
        // Performance). Intel has no perflevels at all, so fall back to the plain count.
        let levels = Int(sysctlUInt64("hw.nperflevels") ?? 0)
        let perLevel = (0 ..< levels).compactMap { sysctlUInt64("hw.perflevel\($0).physicalcpu") }
        let cores = perLevel.isEmpty
            ? Int(sysctlUInt64("hw.physicalcpu") ?? 1)
            : Int(perLevel.reduce(0, +))

        return SystemCapabilities(
            chipName: brand,
            isAppleSilicon: arm,
            cores: cores,
            memoryBytes: sysctlUInt64("hw.memsize") ?? 0,
            freeDiskBytes: freeSpace(at: storageURL),
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    /// The volume free space is measured on. Deliberately the Application Support
    /// *root* and not `SpeechText/`: creating that folder early would make
    /// `TranscriptionHistory.adoptPreRenameStore()` skip its one-shot migration, which
    /// only runs when the folder does not yet exist.
    @usableFromInline static let defaultStorageProbe: URL? =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

    /// `volumeAvailableCapacityForImportantUsage` rather than the plain free-space key:
    /// it reports what the system would actually free up (purgeable caches included) for
    /// a download the user asked for, which is the number that decides whether a model fits.
    private static func freeSpace(at url: URL?) -> UInt64 {
        guard let url else { return 0 }
        // The directory may not exist yet on a first run — ask its nearest existing parent.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

// MARK: - sysctl

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Reads an integer sysctl whose width is not known up front — `hw.memsize` is 64-bit
/// while `hw.perflevel0.physicalcpu` is 32-bit, and reading either at the wrong width
/// returns garbage rather than an error. Ask for the size first, then match it.
private func sysctlUInt64(_ name: String) -> UInt64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    switch size {
    case 8:
        var value: UInt64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    case 4:
        var value: UInt32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return UInt64(value)
    default:
        return nil
    }
}

// MARK: - Tier

/// Which class of Mac this is, for choosing local models.
///
/// Decided by **memory**, never by model name: unified memory is what bounds the model a
/// Mac can hold, and a rule keyed on names would put every Mac released after this file
/// was written into the wrong class. The chip only matters in one way — Intel has no
/// Neural Engine — so it is its own tier whatever its RAM.
///
/// Boundaries sit between the configurations Apple actually sells (Sept 2026): 8 GB
/// (MacBook Neo), 16 GB (MacBook Air M5, iMac M4, Mac mini M6), 24–32 GB (upper M5
/// configurations, M5 Pro 24 GB), 36–64 GB (M5 Pro / M5 Max), 96–128 GB (M5 Max 128 GB,
/// Mac Studio M5 Ultra 96 GB), 256–512 GB (Mac Studio M5 Ultra). Each boundary is midway
/// to the next configuration, so an odd older size (an 18 GB M3 Pro) lands in the tier
/// it can actually run.
public enum MacTier: Int, CaseIterable, Comparable, Sendable {
    case intel
    case entry        // 8 GB
    case standard     // 16 GB
    case plus         // 24–32 GB
    case pro          // 36–64 GB
    case max          // 96–128 GB
    case ultra        // 256 GB and up

    public init(_ capabilities: SystemCapabilities) {
        guard capabilities.isAppleSilicon else { self = .intel; return }
        switch capabilities.memoryGB {
        case ..<12: self = .entry
        case ..<20: self = .standard
        case ..<34: self = .plus
        case ..<80: self = .pro
        case ..<192: self = .max
        default: self = .ultra
        }
    }

    public static func < (lhs: MacTier, rhs: MacTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Shown in Settings so the user can see which class the recommendation was made for.
    /// Memory only, never a model name: the label sits beside the real chip, and naming a
    /// Mac there read as the app deciding which Mac this is — an M2 Air was told it was a
    /// MacBook Neo.
    public var displayName: String {
        switch self {
        case .intel: "Intel Mac"
        case .entry: "8 GB class"
        case .standard: "16 GB class"
        case .plus: "24–32 GB class"
        case .pro: "36–64 GB class"
        case .max: "96–128 GB class"
        case .ultra: "256 GB+ class"
        }
    }
}
