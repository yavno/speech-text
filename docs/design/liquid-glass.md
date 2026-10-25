# Liquid Glass in the minimal skin

On macOS 26 and later the minimal skin's surfaces — the overlay strip and its transcript,
the status notice, the hold tip and the Record Window — are Liquid Glass; on 14 and 15
they keep `.ultraThinMaterial`. Settings › Appearance › Transparency (`GlassTransparency`,
SpeechTextCore) picks how much they let through; `minimalGlass(in:)` (MinimalChrome.swift)
is the one place that draws either. The techno skin is untouched: its colours are drawn to
the design.

This page records what the choice was made from: a measurement on macOS 27.0.1 (26A434),
Xcode 27.1, MacBook Air M2, 2026-10-25, in a test app run as an `.accessory` agent, with
panels over a striped backdrop and the screen captured. Two numbers per surface: its
brightness (0–255) and how much of the backdrop's detail survives under it (1 = all of it,
0 = a solid fill).

## What the SDK offers

- SwiftUI `Glass` (26): `.regular`, `.clear`, `.identity`, `tint(_:)`, `interactive(_:)`;
  `glassEffect(_:in:)`, `GlassEffectContainer`, `glassEffectID` / `Union` / `Transition`.
- AppKit `NSGlassEffectView` (26): `contentView`, `cornerRadius`, `tintColor`, `style`
  (regular / clear); `effectIsInteractive` (27). `NSGlassEffectContainerView`.
- No glass level or opacity, and no way to read or observe the system's Liquid Glass
  setting. It is stored under a private key, which the app does not read.

## What was measured

**A panel that is never key looks inactive, and the overlay is never key.** In a window
that is not key, `.clear` is frosted — barely more see-through than `.regular` (0.14 of the
backdrop against 0.10; in a key window `.clear` keeps 0.63) — and a tint on `.regular` only
greys it (0.2 / 0.5 / 0.8 → brightness 184 / 173 / 167 in light mode; in a key window 211 /
231 / 250, up to solid). Whether the app is active does not matter, only whether the window
is key; overriding `isKeyWindow` and `.environment(\.appearsActive, true)` change nothing.

**Only `.clear` with a tint makes a scale there.** `.clear.tint(windowBackground.opacity(x))`
at 0.2 / 0.5 / 0.8 measured 181 / 217 / 253 in light mode and 94 / 62 / 30 in dark, in a
window that is not key; the backdrop kept 0.11 / 0.07 / 0.02. With untinted `.clear` (0.14)
and `.regular` (0.10) the five stops are in order, which is the scale `GlassTransparency`
uses. `.regular` is the default because it is nearest the old material (189 against 179 in
light mode, 106 and 106 in dark).

**The system's Liquid Glass setting** (System Settings › Appearance) changes `.regular`, in
key and non-key windows alike, at once — the app need not restart. It changes `.clear` only
in a key window, and the material never. So the default stop follows it and the others do
not; the caption under the slider says so.

**Reduce transparency** applies at once and makes every surface solid: `.regular` the
window's colour, the material a grey, but `.clear` a dark grey (about 70) even in light
mode. So under it `GlassTransparency` draws `.regular` whatever the stop, and the slider is
dimmed with a caption saying there is nothing to adjust.

**Readability.** In a window that is not key, `.primary` text reads over light and dark
backdrops on every stop; `.secondary` is faint on any glass. A key window's `.clear` is a
lens, and white text on it is unreadable in dark mode — which only the Record Window, when
it has the keyboard, can show.

**Edges.** Glass draws its own thin light rim and no shadow; the panel's `hasShadow` adds a
shadow and a one-pixel dark outline. They do not conflict.

## Why SwiftUI and not `NSGlassEffectView`

They draw the same glass, number for number. But `NSGlassEffectView.tintColor` set from
`NSColor.windowBackgroundColor.withAlphaComponent(_:)` kept the light colour in dark mode — a
white panel with white text — unless it is set again from `viewDidMoveToWindow` and
`viewDidChangeEffectiveAppearance` under `performAsCurrentDrawingAppearance`. A SwiftUI
`Color(nsColor:)` follows the appearance by itself.

## Not measured

The `.clear.tint` stops at the system setting's two ends (`.clear` without a tint was, and
did not move); macOS 14 and 15, where the material path runs; other Macs and displays.
