// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Colour literals

extension Color {
    /// The design file quotes colours as `#RRGGBB`; keeping that notation here makes
    /// every value greppable back to Figma instead of a floating-point guess.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - TechnoSkin

/// The `techno` skin: a moulded plastic handset with a dark-green LCD set into it.
///
/// Both surfaces that wear this skin — the inline overlay and the record window — are
/// built from this palette, which is what makes them read as one device. Every value
/// was matched against the design file, so this skin ignores the user's free accent
/// colour (`AppSkin.supportsAccent`); its display colour is a whole `TechnoPalette`
/// instead — a curated `TechnoPhosphor` preset, or one derived from any colour. The statics here are the design's green — the
/// setup window borrows them as its own palette, so they never follow the user's pick.
/// A skin surface reads its glass and phosphor from `\.technoPalette`.
enum TechnoSkin {

    // The glass

    /// LCD background.
    static let screen = Color(hex: 0x16231C)
    /// Recesses milled into the shell: the language badge's ring, the button rail.
    static let recess = Color(hex: 0x0C130F)
    /// An unlit pixel — the dot mask showing against the glass.
    static let pixelOff = Color.white.opacity(0.03)
    /// A lit pixel, and the white the loudest ones burn to.
    static let phosphor = Color(hex: 0x61C58C)
    static let peak = Color.white
    /// Text printed on the glass.
    static let phosphorText = Color(hex: 0x59B381)

    /// AI mode swaps the phosphor colour so a rewritten dictation never looks like a
    /// plain one — the two flows share every other pixel of the UI.
    static let aiPhosphor = Color(hex: 0xB49CFF)
    /// What a loud dot burns to in AI mode. Not the plain white the green phosphor
    /// uses: a display whose peaks go white loses the violet exactly when it is
    /// loudest, which is when the user is looking at it.
    static let aiPeak = Color(hex: 0xEAE2FF)
    static let aiText = Color(hex: 0x9C85F0)
    /// The glass itself goes violet for an edit of selected text — AI mode only
    /// recolours the phosphor, so the two stay apart at a glance.
    static let editScreen = Color(hex: 0x1F1834)

    static let danger = Color(hex: 0xE2564D)

    // The shell

    /// Lit edge of a moulded part.
    static let plasticEdge = Color(hex: 0x474849)

    /// Face of the moulded round buttons. The design lights them from 224°, i.e. from
    /// the bottom-left, so the highlight lands opposite the drop shadow.
    static let plasticFace = LinearGradient(
        colors: [Color(hex: 0x1C1C1C), Color(hex: 0x303030)],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )

    // Geometry shared by the panels

    /// Corner radius of the shell. Continuous (squircle) corners — matched against the
    /// design's own corner profile, not read off the Figma radius field, because Figma
    /// and SwiftUI parameterise smoothed corners differently.
    static let shellRadius: CGFloat = 50
    /// Dot pitch of the LCD: a 5pt pixel every 7pt.
    static let pixel: CGFloat = 5
    static let pixelGap: CGFloat = 2
    static var pixelPitch: CGFloat { pixel + pixelGap }
}

// MARK: - Display colour

/// The inks one display colour is drawn with: the glass, the recesses milled into the
/// shell, the lit dot, the text printed on the glass and the white a loud dot burns to.
///
/// A colour is always a whole set, never a single tint applied to the design: the
/// design's glass is a very dark green, and amber dots on it look like a fault. Each
/// set keeps the design's relationships — text a shade darker than the dots, glass and
/// recess the same hue as the phosphor at almost no brightness.
struct TechnoPalette: Equatable {
    let screen: Color
    let recess: Color
    let phosphor: Color
    let phosphorText: Color
    let peak: Color
    /// The shell's texture is printed in the design's green; it is turned to the
    /// display's hue (and drained for white) so the dots on the plastic match the glass.
    let shellHue: Angle
    let shellSaturation: Double

    /// The design file, exactly.
    static let green = TechnoPalette(
        screen: TechnoSkin.screen, recess: TechnoSkin.recess,
        phosphor: TechnoSkin.phosphor, phosphorText: TechnoSkin.phosphorText, peak: TechnoSkin.peak,
        shellHue: .zero, shellSaturation: 1
    )
    static let amber = TechnoPalette(
        screen: Color(hex: 0x251C12), recess: Color(hex: 0x130E09),
        phosphor: Color(hex: 0xF2AA4C), phosphorText: Color(hex: 0xD9973F), peak: Color(hex: 0xFFF3DE),
        shellHue: .degrees(-112), shellSaturation: 1
    )
    static let cyan = TechnoPalette(
        screen: Color(hex: 0x122223), recess: Color(hex: 0x0A1314),
        phosphor: Color(hex: 0x4FD2D6), phosphorText: Color(hex: 0x47BDC0), peak: .white,
        shellHue: .degrees(36), shellSaturation: 1
    )
    static let white = TechnoPalette(
        screen: Color(hex: 0x1A1D1F), recess: Color(hex: 0x0E1011),
        phosphor: Color(hex: 0xD5DEE3), phosphorText: Color(hex: 0xB9C3C9), peak: .white,
        shellHue: .zero, shellSaturation: 0
    )
}

extension TechnoPalette {
    /// The palette a stored `SettingsKeys.technoPhosphor` value names: a preset's
    /// hand-matched set, a set derived from a `#RRGGBB` colour, or — for anything else —
    /// the design's green, so the display never draws in a colour nobody chose.
    init(stored: String) {
        if let preset = TechnoPhosphor(rawValue: stored) {
            self = preset.palette
        } else if let hex = TechnoPhosphor.customHex(stored) {
            self = TechnoPalette(deriving: hex)
        } else {
            self = .green
        }
    }

    /// A whole set from one colour, keeping the design's proportions: the design's
    /// glass is its phosphor's hue at 14% brightness and ~70% of its saturation, the
    /// recess the same at half that brightness, the text 90% of the dot's brightness.
    init(deriving hex: UInt32) {
        let base = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .white
        let hue = base.hueComponent
        let saturation = base.saturationComponent
        // A dark pick would print dark dots on dark glass; the dots stay lit.
        let brightness = max(base.brightnessComponent, 0.55)
        func ink(_ s: CGFloat, _ b: CGFloat) -> Color {
            Color(hue: Double(hue), saturation: Double(min(max(s, 0), 1)), brightness: Double(b))
        }
        let glassSaturation = min(saturation * 0.7, 0.45)
        self.init(
            screen: ink(glassSaturation, 0.14),
            recess: ink(glassSaturation, 0.075),
            phosphor: ink(saturation, brightness),
            phosphorText: ink(saturation, brightness * 0.9),
            peak: .white,
            // The texture is printed at the design phosphor's hue (146°) and saturation.
            shellHue: .degrees(Double(hue) * 360 - Self.designHue),
            shellSaturation: Double(min(saturation / Self.designSaturation, 1))
        )
    }

    private static let designHue = 146.0
    private static let designSaturation: CGFloat = 0.51

    /// How close a colour's hue is to AI mode's violet phosphor. Techno's AI mode
    /// recolours only the dots, so a display near it would make a plain dictation look
    /// like an AI one; Settings warns rather than refuses.
    static func isCloseToAI(_ hex: UInt32) -> Bool {
        guard let color = NSColor(Color(hex: hex)).usingColorSpace(.sRGB),
              let ai = NSColor(TechnoSkin.aiPhosphor).usingColorSpace(.sRGB),
              color.saturationComponent > 0.2 else { return false }
        let distance = abs(color.hueComponent - ai.hueComponent)
        return min(distance, 1 - distance) * 360 < 30
    }
}

/// The techno display's colour, as stored.
///
/// The field's name for it is the *phosphor colour* — green (P1), amber (P3) and white
/// (P4) are the classic monochrome-monitor phosphors, cyan the vacuum-fluorescent
/// display's. These are the recommended sets, each matched as a whole (see
/// `TechnoPalette`); any other colour is stored as `#RRGGBB` and its set derived. None
/// of them is violet, which is AI mode's phosphor, or red, the error text on the glass.
enum TechnoPhosphor: String, CaseIterable, Identifiable {
    case green, amber, cyan, white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .green: return "Green"
        case .amber: return "Amber"
        case .cyan: return "Cyan"
        case .white: return "White"
        }
    }

    var palette: TechnoPalette {
        switch self {
        case .green: return .green
        case .amber: return .amber
        case .cyan: return .cyan
        case .white: return .white
        }
    }

    /// The colour of a stored `#RRGGBB` value; nil for a preset or anything unreadable.
    static func customHex(_ stored: String) -> UInt32? {
        var text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }
}

private struct TechnoPaletteKey: EnvironmentKey {
    static let defaultValue = TechnoPalette.green
}

extension EnvironmentValues {
    /// The display colour the techno parts draw with. Set by each surface's root view
    /// from `SettingsKeys.technoPhosphor`.
    var technoPalette: TechnoPalette {
        get { self[TechnoPaletteKey.self] }
        set { self[TechnoPaletteKey.self] = newValue }
    }
}

// MARK: - SVG path data

/// Reads the absolute-command subset of SVG path data (`M L H V C Z`) that Figma
/// exports.
///
/// Shapes traced from the design keep their raw `d` string, so re-exporting a tweaked
/// vector is a copy-paste rather than a hand translation into `Path` calls — which is
/// what usually rots when a design changes.
enum SVGPathData {

    /// Appends `d` to `path`, mapping the design-space box `designSize` onto `rect`.
    static func append(_ d: String, designSize: CGSize, in rect: CGRect, to path: inout Path) {
        guard designSize.width > 0, designSize.height > 0 else { return }
        var reader = Reader(d)
        let sx = rect.width / designSize.width
        let sy = rect.height / designSize.height

        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var command: Character = " "
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        while true {
            reader.skipSeparators()
            if reader.isAtEnd { return }
            if let c = reader.commandIfPresent() { command = c }

            switch command {
            case "M", "L":
                guard let x = reader.number(), let y = reader.number() else { return }
                current = CGPoint(x: x, y: y)
                if command == "M" {
                    path.move(to: map(x, y))
                    subpathStart = current
                    // Repeated coordinate pairs after a move-to are line-tos.
                    command = "L"
                } else {
                    path.addLine(to: map(x, y))
                }

            case "H":
                guard let x = reader.number() else { return }
                current.x = x
                path.addLine(to: map(current.x, current.y))

            case "V":
                guard let y = reader.number() else { return }
                current.y = y
                path.addLine(to: map(current.x, current.y))

            case "C":
                guard let x1 = reader.number(), let y1 = reader.number(),
                      let x2 = reader.number(), let y2 = reader.number(),
                      let x = reader.number(), let y = reader.number()
                else { return }
                current = CGPoint(x: x, y: y)
                path.addCurve(
                    to: map(x, y),
                    control1: map(x1, y1),
                    control2: map(x2, y2)
                )

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                // An unsupported command means the rest of the data can't be trusted.
                return
            }
        }
    }

    private struct Reader {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) { chars = Array(string) }

        var isAtEnd: Bool { index >= chars.count }

        mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == ","
                    || chars[index] == "\n" || chars[index] == "\t" {
                index += 1
            }
        }

        /// A letter here is always a command: exponents only ever appear after digits,
        /// which `number()` has already consumed.
        mutating func commandIfPresent() -> Character? {
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index]); index += 1
            }
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                text.append(chars[index]); index += 1
            }
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                text.append(chars[index]); index += 1
                if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                    text.append(chars[index]); index += 1
                }
                while index < chars.count, chars[index].isNumber {
                    text.append(chars[index]); index += 1
                }
            }
            guard let value = Double(text) else { return nil }
            return CGFloat(value)
        }
    }
}

// MARK: - The glass

/// The LCD cut-out: a rounded rectangle with a bite taken out of the top-right where
/// the transport knob is set into the shell. Traced from the design's vector.
struct LCDScreenShape: Shape {
    /// Size the path was authored at — everything scales from here.
    static let designSize = CGSize(width: 338, height: 259.108)

    func path(in rect: CGRect) -> Path {
        // Parsed and unioned once, at the design size, then scaled onto the rect: the
        // mapping is affine, so it commutes with the union, and the shape is asked for
        // several times per body at 30Hz.
        Self.designPath.applying(
            CGAffineTransform(scaleX: rect.width / Self.designSize.width,
                              y: rect.height / Self.designSize.height)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        )
    }

    /// Unioned rather than merely overlaid: the two halves share an internal edge at
    /// the knob's waistline, and anything that strokes the shape — the inner shadow —
    /// would otherwise draw a seam straight across the glass.
    private static let designPath: Path = subpaths.reduce(into: Path()) { result, d in
        var part = Path()
        SVGPathData.append(d, designSize: designSize,
                           in: CGRect(origin: .zero, size: designSize), to: &part)
        result = result.isEmpty ? part : result.union(part)
    }

    /// Two halves that meet (with a hairline of overlap) at the knob's waistline.
    private static let subpaths: [String] = [
        """
M45.2703 0C31.8384 0.711861 20.7866 4.81441 11.608 15.0423C5.70306 21.6803 1.87014 29.9018 0.582186 38.6923C-0.147713 43.7877 0.0157734 49.7372 0.0153936 54.9433L0.0539369 145.858H337.983L337.981 119.972C337.986 115.578 338.047 111.021 337.918 106.643C337.804 102.829 336.114 99.2304 333.192 96.7261C327.649 91.9759 320.933 92.7219 314.139 92.7397L294.689 92.7531C289.107 92.7535 284.045 92.7539 278.607 92.2639C251.386 89.811 227.913 69.5852 226.702 41.2984C226.453 35.4795 226.362 29.5089 226.447 23.6536C226.36 19.7464 226.897 14.578 225.659 10.9276C223.656 5.02575 216.909 0.879334 210.928 0.226146C208.695 -0.0178498 206.124 0.0328479 203.897 0.0235438L193.152 0.00569617L45.2703 0Z
""",
        """
M337.866 206.998V192.256L338 145.658H0.170228L0.0449434 201.116C0.0521568 205.935 -0.121911 211.941 0.170228 216.724C0.807657 228.744 6.29338 239.99 15.3719 247.889C21.9801 253.66 30.1543 257.336 38.8556 258.448C44.2459 259.178 50.0499 259.041 55.4954 259.041L275.573 259.035C280.524 259.037 287.908 259.254 292.722 258.929C292.892 258.916 293.063 258.902 293.234 258.883C306.417 258.128 317.611 253.574 326.495 243.547C332.159 237.045 335.888 229.083 337.254 220.567C337.991 215.893 337.866 211.692 337.866 206.998Z
""",
    ]
}

/// SwiftUI has no inner shadow. Stroking a shape and clipping the result back to that
/// same shape keeps only the inner half of the stroke, which reads the same way.
struct InnerShadow<S: Shape>: View {
    let shape: S
    var color: Color = .black
    var width: CGFloat
    var blur: CGFloat
    var offset: CGSize = .zero
    var opacity: Double = 1

    var body: some View {
        shape
            .stroke(color, lineWidth: width)
            .blur(radius: blur)
            .offset(x: offset.width, y: offset.height)
            .opacity(opacity)
            .clipShape(shape)
    }
}

/// The glass: whatever is printed on it, plus the dark inner shadow that seats it into
/// the shell.
///
/// Content is laid out from the glass's own top-left corner, because that is how the
/// design measures everything on the screen — and because a child positioned against
/// the window instead would need its mask re-derived every time the panel moved.
struct LCDScreen<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    init(size: CGSize, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.size = size
        self.content = content()
    }

    @Environment(\.technoPalette) private var palette

    var body: some View {
        LCDScreenShape()
            .fill(palette.screen)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                // Color.clear pins the stack to the full glass, so a child's offset is
                // measured from the glass's corner rather than from whatever bounding
                // box its siblings happen to add up to.
                ZStack(alignment: .topLeading) {
                    Color.clear
                    content
                }
            }
            .overlay {
                // The design layers two inner shadows: a tight one cast from above and
                // a broader all-round one.
                InnerShadow(shape: LCDScreenShape(), width: 6.6, blur: 3.3)
                InnerShadow(shape: LCDScreenShape(), width: 4, blur: 2,
                            offset: CGSize(width: 0, height: -1))
            }
            .clipShape(LCDScreenShape())
    }
}

// MARK: - The shell

/// The moulded shell the glass is set into — the design's texture, clipped to the
/// panel's corner radius.
struct ShellBackground: View {
    var cornerRadius: CGFloat = TechnoSkin.shellRadius

    @Environment(\.technoPalette) private var palette

    var body: some View {
        Image("PanelBackground")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .hueRotation(palette.shellHue)
            .saturation(palette.shellSaturation)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
            }
    }
}

// MARK: - Moulded buttons

/// One of the small moulded buttons that sit in a rail on the shell.
struct PlasticButton: View {
    let systemImage: String
    /// What VoiceOver calls the button: a short name, not the tooltip's sentence.
    let label: Text
    /// The state VoiceOver reads after the name ("On" for a toggle); empty for none.
    var value = Text(verbatim: "")
    var isOn = false
    /// The lit colour when on; nil takes the display's phosphor.
    var accent: Color? = nil
    var isEnabled = true
    var help = Text(verbatim: "")
    let action: () -> Void

    /// Words from the String Catalog.
    init(systemImage: String, label: LocalizedStringKey, value: LocalizedStringKey? = nil, isOn: Bool = false,
         accent: Color? = nil, isEnabled: Bool = true, help: LocalizedStringKey? = nil, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, label: Text(label), value: value.map { Text($0) } ?? Text(verbatim: ""),
                  isOn: isOn, accent: accent, isEnabled: isEnabled, help: help.map { Text($0) } ?? Text(verbatim: ""),
                  action: action)
    }

    /// Words already made, shown as they are.
    @_disfavoredOverload
    init(systemImage: String, label: String, value: String = "", isOn: Bool = false,
         accent: Color? = nil, isEnabled: Bool = true, help: String = "", action: @escaping () -> Void) {
        self.init(systemImage: systemImage, label: Text(verbatim: label), value: Text(verbatim: value),
                  isOn: isOn, accent: accent, isEnabled: isEnabled, help: Text(verbatim: help), action: action)
    }

    init(systemImage: String, label: Text, value: Text, isOn: Bool, accent: Color?, isEnabled: Bool, help: Text,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.value = value
        self.isOn = isOn
        self.accent = accent
        self.isEnabled = isEnabled
        self.help = help
        self.action = action
    }

    static let size: CGFloat = 30

    @Environment(\.technoPalette) private var palette
    @State private var isHovering = false

    private var lit: Color { accent ?? palette.phosphor }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(foreground)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(TechnoSkin.plasticFace))
                .overlay(Circle().fill(Color.white.opacity(isHovering && isEnabled ? 0.10 : 0)))
                .overlay {
                    // The design's inset hairline: a lit edge on the top-left rim.
                    Circle()
                        .strokeBorder(TechnoSkin.plasticEdge.opacity(0.9), lineWidth: 0.5)
                        .mask(
                            LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    if isOn {
                        Circle().strokeBorder(lit.opacity(0.75), lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 2, x: -2, y: 1)
                .shadow(color: isOn ? lit.opacity(0.35) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .pointingHandCursor(enabled: isEnabled) { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var foreground: Color {
        guard isEnabled else { return .white.opacity(0.25) }
        return isOn ? lit : .white.opacity(0.9)
    }
}

/// The recessed rail the small buttons sit in.
struct ButtonRail<Content: View>: View {
    @ViewBuilder var content: Content

    /// Outer width of the rail — the design mills it 3pt wider than the buttons.
    static var width: CGFloat { PlasticButton.size + 6 }

    @Environment(\.technoPalette) private var palette

    var body: some View {
        VStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(Capsule().fill(palette.recess))
    }
}

// MARK: - Transport knob

/// The transport dial — the big moulded knob set into the shell's top-right corner.
///
/// Rebuilt from the design's layer stack rather than shipped as a bitmap: the app
/// needs it in states the design never drew (recording, transcribing, AI), and a
/// vector knob can take any glyph or tint without a new export.
struct TransportKnob: View {
    /// SF Symbol shown on the cap. Ignored while `isBusy`.
    let systemImage: String
    /// What VoiceOver calls the knob, and the state it reads after the name.
    let label: Text
    var value = Text(verbatim: "")
    var tint: Color = .white.opacity(0.92)
    /// Replaces the glyph with a sweeping arc while a provider is working.
    var isBusy = false
    var isEnabled = true
    var help = Text(verbatim: "")
    let action: () -> Void

    /// Words from the String Catalog.
    init(systemImage: String, label: LocalizedStringKey, value: LocalizedStringKey? = nil,
         tint: Color = .white.opacity(0.92), isBusy: Bool = false, isEnabled: Bool = true,
         help: LocalizedStringKey? = nil, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, label: Text(label), value: value.map { Text($0) } ?? Text(verbatim: ""),
                  tint: tint, isBusy: isBusy, isEnabled: isEnabled, help: help.map { Text($0) } ?? Text(verbatim: ""),
                  action: action)
    }

    /// Words already made, shown as they are.
    @_disfavoredOverload
    init(systemImage: String, label: String, value: String = "", tint: Color = .white.opacity(0.92),
         isBusy: Bool = false, isEnabled: Bool = true, help: String = "", action: @escaping () -> Void) {
        self.init(systemImage: systemImage, label: Text(verbatim: label), value: Text(verbatim: value),
                  tint: tint, isBusy: isBusy, isEnabled: isEnabled, help: Text(verbatim: help), action: action)
    }

    init(systemImage: String, label: Text, value: Text, tint: Color, isBusy: Bool, isEnabled: Bool, help: Text,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.value = value
        self.tint = tint
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.help = help
        self.action = action
    }

    /// Diameter of the outer plastic disc. The bevel and its shadows spill outside it,
    /// which is what seats the knob into the shell.
    static let diameter: CGFloat = 66.876

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                outerDisc
                groove
                cap
                glyph
            }
            .frame(width: Self.diameter, height: Self.diameter)
            // The bevel is larger than the knob, and a ZStack re-proposes its final
            // size to flexible children — putting it in the stack would inflate the
            // disc to match it. As a background it stays out of the layout.
            .background { bevel }
            .scaleEffect(isPressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .pointingHandCursor(enabled: isEnabled) { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    /// The moulding the knob is seated in: a soft dark disc pushed down-right, with
    /// just enough light on the up-left rim to read as a bevel rather than a shadow.
    private var bevel: some View {
        Circle()
            .fill(Color(hex: 0x0E0E10))
            .frame(width: 78.4, height: 77.8)
            .shadow(color: Color(white: 0.83, opacity: 0.10), radius: 3, x: -7, y: -8.4)
            .shadow(color: .black.opacity(0.7), radius: 5, x: 2, y: 4)
            .blur(radius: 2.5)
            .offset(x: 4.6, y: 4.9)
    }

    /// Outer plastic ring: near-black at the top, catching the light at the bottom.
    private var outerDisc: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x070707), Color(hex: 0x515253)],
                    startPoint: UnitPoint(x: 0.32, y: 0.03),
                    endPoint: UnitPoint(x: 0.64, y: 0.97)
                )
            )
            // Crisp, not soft: the design's rim lights are a sub-pixel blur, and
            // softening them any further turns the moulded edge into a grey smudge.
            .overlay { rim(.white.opacity(0.5), width: 1.2, litFrom: .topLeading) }
            .overlay { rim(.black.opacity(0.9), width: 1.8, litFrom: .bottomTrailing) }
    }

    /// The machined groove between the outer plastic and the cap. It reads as a dark
    /// gap with one faint lit edge — not as a ring in its own right.
    private var groove: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x2A2C34), Color(hex: 0x060606)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 58.4, height: 58.4)
            Circle()
                .strokeBorder(Color(hex: 0x2F2F3D).opacity(0.5), lineWidth: 1)
                .frame(width: 58.4, height: 58.4)
            Circle()
                .stroke(Color.black.opacity(0.85), lineWidth: 1.2)
                .frame(width: 58.9, height: 58.9)
        }
    }

    /// The pressable cap: dark, lit along its lower-inner rim, with a boss in the
    /// middle you can just make out.
    private var cap: some View {
        ZStack {
            Circle()
                .fill(Color(hex: 0x24272B))
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 4)
                        .blur(radius: 3)
                        .offset(x: 2, y: 2.5)
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.45), lineWidth: 8)
                        .blur(radius: 6)
                        .offset(x: -2, y: -4)
                }
                .clipShape(Circle())
                .frame(width: 49.85, height: 49.85)

            // The boss is all but invisible against the cap; what gives it away is
            // the pale glow it throws onto the cap below it.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x282B30), Color(hex: 0x212429)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30.4, height: 30.4)
                .shadow(color: .white.opacity(0.22), radius: 4, x: 2.8, y: 4.2)

            Circle()
                .fill(Color.white.opacity(isHovering && isEnabled ? 0.06 : 0))
                .frame(width: 49.85, height: 49.85)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if isBusy {
            BusyArc(tint: tint)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .ultraLight))
                .foregroundStyle(isEnabled ? tint : tint.opacity(0.3))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        }
    }

    /// A hairline of light or shade along one side of the disc's rim — the moulded
    /// edge catching the light on one side and falling into shadow on the other.
    private func rim(_ color: Color, width: CGFloat, litFrom corner: UnitPoint) -> some View {
        Circle().strokeBorder(
            LinearGradient(
                stops: [.init(color: color, location: 0), .init(color: .clear, location: 0.5)],
                startPoint: corner,
                endPoint: corner == .topLeading ? .bottomTrailing : .topLeading
            ),
            lineWidth: width
        )
    }

    /// What the cap shows while a provider is working. Driven by a repeating animation
    /// rather than a state-per-frame loop: re-rendering the knob 60 times a second
    /// would re-rasterise every gradient and blur underneath it.
    /// With Reduce Motion on, the arc stands still: it still tells the cap from a glyph.
    private struct BusyArc: View {
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var spinning = false

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                .onAppear { spinning = !reduceMotion }
        }
    }
}
