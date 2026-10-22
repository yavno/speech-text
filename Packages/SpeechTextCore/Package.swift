// swift-tools-version:6.4
// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

/// The app's logic that needs neither a view nor an engine, which the app, the unit tests
/// and the SpeechTextEvaluation tool link — once compiled three times from one hand-kept
/// list of Sources phases. A file placed under `Sources/` is compiled with no project edit.
///
/// It depends on no other package, so `import WhisperKit`, `FluidAudio`, `Sparkle` or
/// `llama` here is a build error rather than a rule for review. `ChatTemplates` is a
/// product of its own because the SpeechTextLLM service links it and nothing else.
///
/// Swift 6 language mode, with none of the later opt-in isolation defaults: no default
/// main-actor isolation and no `NonisolatedNonsendingByDefault`, which would move every
/// session's `finish()` onto its caller's actor. Isolation is written out on each type
/// instead (docs/development.md › Concurrency). Xcode passes none of the project's build
/// settings into a package, so `SPT_WARNINGS_AS_ERRORS` does not reach it; CI builds it on
/// its own with `swift build -Xswiftc -warnings-as-errors` instead (docs/development.md ›
/// Compiler warnings).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "SpeechTextCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeechTextCore", targets: ["SpeechTextCore"]),
        .library(name: "ChatTemplates", targets: ["ChatTemplates"]),
    ],
    targets: [
        .target(name: "SpeechTextCore", dependencies: ["ChatTemplates"], swiftSettings: swiftSettings),
        .target(name: "ChatTemplates", swiftSettings: swiftSettings),
    ]
)
