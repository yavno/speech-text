// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

/// How much of what is behind them the minimal skin's surfaces let through — Settings ›
/// Appearance › Transparency, named as macOS names the property (Reduce transparency).
///
/// A scale of stops rather than a number, because only a few points of it can be drawn
/// the same way on every macOS the app runs on. The values were measured on macOS 27 in a
/// panel that is never key, which is what the overlay is (docs/design/liquid-glass.md):
/// there Liquid Glass shows its inactive look, in which `.clear` is frosted rather than
/// clear and a tint on `.regular` only greys it. So the scale is built from `.clear` with
/// a growing tint, which does reach from frosted to nearly solid in a window that is not
/// key, and `.regular` untinted at the default stop — the glass nearest the material the
/// skin wore before, and the one that follows the system's own Liquid Glass setting.
public enum GlassTransparency: String, CaseIterable, Sendable {
    case most
    case more
    /// What an install that never moved the slider gets, and what an unreadable stored
    /// value reads as: as close as Liquid Glass comes to the material the skin wore
    /// before, so nobody's overlay changes under them.
    case standard
    case less
    case least

    public static let `default` = GlassTransparency.standard

    /// The stored value, or the default for anything else.
    public init(stored: String?) {
        self = stored.flatMap(GlassTransparency.init(rawValue:)) ?? .default
    }

    /// The stop's name under the slider and to VoiceOver.
    public var title: String {
        switch self {
        case .most: "Most"
        case .more: "More"
        case .standard: "Default"
        case .less: "Less"
        case .least: "Least"
        }
    }

    /// What the stop is on macOS 26 and later.
    public var glass: GlassFill {
        switch self {
        case .most: .clear(tint: 0)
        case .more: .clear(tint: 0.2)
        case .standard: .regular
        case .less: .clear(tint: 0.5)
        case .least: .clear(tint: 0.8)
        }
    }

    /// What the stop is on macOS 14 and 15, which have only the material: the material
    /// thinned below the default, and the window's background laid over it above.
    public var material: MaterialFill {
        switch self {
        case .most: MaterialFill(materialOpacity: 0.45, backgroundOpacity: 0)
        case .more: MaterialFill(materialOpacity: 0.75, backgroundOpacity: 0)
        case .standard: MaterialFill(materialOpacity: 1, backgroundOpacity: 0)
        case .less: MaterialFill(materialOpacity: 1, backgroundOpacity: 0.35)
        case .least: MaterialFill(materialOpacity: 1, backgroundOpacity: 0.7)
        }
    }

    /// The glass to draw, with Reduce transparency taken into account. The system makes
    /// every glass solid then, but `.clear` turns a dark grey even in light mode (measured),
    /// so the stop is set aside for `.regular`, which turns the window's own colour.
    public func glass(reduceTransparency: Bool) -> GlassFill {
        reduceTransparency ? .regular : glass
    }

    /// The material to draw, with Reduce transparency taken into account: the system
    /// makes the material solid, and thinning it would let the desktop back in.
    public func material(reduceTransparency: Bool) -> MaterialFill {
        reduceTransparency ? GlassTransparency.standard.material : material
    }
}

/// Liquid Glass as a stop draws it: `.regular`, or `.clear` tinted towards the window's
/// background colour by `tint` (0 for none).
public enum GlassFill: Equatable, Sendable {
    case regular
    case clear(tint: Double)
}

/// The material as a stop draws it on macOS 14 and 15.
public struct MaterialFill: Equatable, Sendable {
    /// The `.ultraThinMaterial`'s own opacity: 1 is the material as it is.
    public let materialOpacity: Double
    /// The window's background colour laid over the material: 0 is none.
    public let backgroundOpacity: Double

    public init(materialOpacity: Double, backgroundOpacity: Double) {
        self.materialOpacity = materialOpacity
        self.backgroundOpacity = backgroundOpacity
    }
}
