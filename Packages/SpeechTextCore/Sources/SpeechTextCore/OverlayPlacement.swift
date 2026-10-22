// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

/// The inline overlay's shape, as far as placing it is concerned: the strip, and the
/// transcript that grows out of it (from nothing, line by line, up to `maxTranscriptHeight`).
public struct OverlayGeometry: Equatable, Sendable {
    public var strip: CGSize
    /// Width of the transcript area; 0 when the recording shows none.
    public var transcriptWidth: CGFloat = 0
    public var maxTranscriptHeight: CGFloat = 0
    /// Between the strip and the transcript, once there is one.
    public var gap: CGFloat = 0

    public init(strip: CGSize, transcriptWidth: CGFloat = 0, maxTranscriptHeight: CGFloat = 0, gap: CGFloat = 0) {
        self.strip = strip
        self.transcriptWidth = transcriptWidth
        self.maxTranscriptHeight = maxTranscriptHeight
        self.gap = gap
    }

    public var showsTranscript: Bool { maxTranscriptHeight > 0 }

    /// The panel's size with the transcript at `transcriptHeight`. The strip sits at the
    /// right-hand end: a transcript wider than the strip reaches out to the left.
    func size(transcriptHeight: CGFloat) -> CGSize {
        guard transcriptHeight > 0 else { return strip }
        return CGSize(width: max(strip.width, transcriptWidth),
                      height: strip.height + gap + transcriptHeight)
    }

    /// The panel at its largest — what placement keeps on screen, so the transcript can
    /// always grow to its full height without leaving it.
    public var fullSize: CGSize { size(transcriptHeight: maxTranscriptHeight) }
}

/// Which way the transcript grows from the strip: away from the nearer edge of the screen,
/// so a strip parked at the top can sit at the top.
public enum OverlayGrowth: Equatable, Sendable {
    case up, down
}

/// Where the inline overlay sits on screen. Pure geometry: the panel
/// hands in its shape and the screens' visible frames, so a monitor that went away can be
/// tested without one.
///
/// A position is the *strip's* bottom-left corner. The strip is what the user places; the
/// transcript grows out of it, so anchoring anything else would move the strip every time
/// a line of text lands.
public enum OverlayPlacement {
    /// How far the default corner is inset from the screen's edges.
    static let margin: CGFloat = 20

    public struct Placement: Equatable, Sendable {
        /// The strip's bottom-left corner.
        public var strip: CGPoint
        public var growth: OverlayGrowth

        public init(strip: CGPoint, growth: OverlayGrowth) {
            self.strip = strip
            self.growth = growth
        }
    }

    /// The panel's frame for a strip at `strip`, with the transcript at `transcriptHeight`.
    public static func frame(strip: CGPoint, _ geometry: OverlayGeometry, growth: OverlayGrowth,
                      transcriptHeight: CGFloat) -> CGRect {
        let size = geometry.size(transcriptHeight: transcriptHeight)
        let x = strip.x + geometry.strip.width - size.width
        let y = growth == .up ? strip.y : strip.y - (size.height - geometry.strip.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The default spot: the bottom-right corner of `screen`.
    static func defaultPlacement(_ geometry: OverlayGeometry, in screen: CGRect) -> Placement {
        settled(strip: CGPoint(x: screen.maxX - margin - geometry.strip.width, y: screen.minY + margin),
                geometry, in: screen)
    }

    /// Where the panel opens. `saved` — where the user left the strip — settled onto the
    /// screen holding most of it; the default corner of `main` when nothing was saved, or
    /// when the saved spot is on no screen at all (the monitor it was on is unplugged). Nil
    /// only when there are no screens.
    public static func placement(saved: CGPoint?, _ geometry: OverlayGeometry,
                          screens: [CGRect], main: CGRect?) -> Placement? {
        guard let fallback = main ?? screens.first else { return nil }
        guard let saved else { return defaultPlacement(geometry, in: fallback) }

        let strip = CGRect(origin: saved, size: geometry.strip)
        let host = screens
            .map { (screen: $0, overlap: area($0.intersection(strip))) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .screen
        guard let host else { return defaultPlacement(geometry, in: fallback) }
        return settled(strip: saved, geometry, in: host)
    }

    /// The strip proposed at `strip` — by a drag, or a saved spot — made valid on `screen`:
    /// the transcript grows away from the nearer edge, and the whole panel, at its largest,
    /// is kept on the screen.
    public static func settled(strip: CGPoint, _ geometry: OverlayGeometry, in screen: CGRect) -> Placement {
        let growth: OverlayGrowth = strip.y + geometry.strip.height / 2 <= screen.midY ? .up : .down
        var full = frame(strip: strip, geometry, growth: growth, transcriptHeight: geometry.maxTranscriptHeight)
        full.origin = clamped(full.origin, size: full.size, in: screen)

        let size = geometry.fullSize
        let settledStrip = CGPoint(x: full.maxX - geometry.strip.width,
                                   y: growth == .up ? full.minY : full.minY + size.height - geometry.strip.height)
        return Placement(strip: settledStrip, growth: growth)
    }

    /// Between a notice and the overlay it sits beside.
    static let noticeGap: CGFloat = 8

    /// Where a notice (or the hold tip) of `size` opens beside `overlay` — the overlay's
    /// frame, or the strip's when it is gone: right-aligned with it, on the side facing the
    /// middle of the screen (above an overlay in the bottom half, below one in the top
    /// half), which is always the side with more room, and kept on the screen.
    public static func noticeOrigin(_ size: CGSize, beside overlay: CGRect, in screen: CGRect) -> CGPoint {
        let y = overlay.midY <= screen.midY
            ? overlay.maxY + noticeGap
            : overlay.minY - noticeGap - size.height
        return clamped(CGPoint(x: overlay.maxX - size.width, y: y), size: size, in: screen)
    }

    /// `origin` moved inside `screen`. A panel bigger than the screen keeps its bottom-left
    /// corner on it.
    static func clamped(_ origin: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    // MARK: Storing it

    /// `"x,y"`, whole points — `SettingsKeys.overlayOrigin`.
    public static func encode(_ origin: CGPoint) -> String {
        "\(Int(origin.x.rounded())),\(Int(origin.y.rounded()))"
    }

    /// Nil for an empty or unreadable value, which means the default corner.
    public static func decode(_ stored: String) -> CGPoint? {
        let parts = stored.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
