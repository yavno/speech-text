// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the disk image window's background in the setup window's frame: a white card
// inside a rim of glass over the green aura, a title in the setup's type saying to
// double-click the app, a dotted arrow from the app to Applications for those who drag,
// and two lines saying what comes after each. The two icons and
// their names are Finder's.
//
//   swift background.swift OUT_DIR
//
// writes OUT_DIR/background.png (640 × 388) and OUT_DIR/background@2x.png, which
// dmgbuild combines into one Retina-ready image. Rendered with SwiftUI, so the aura is
// drawn the way the setup draws it: the blobs and the turning gradient are SetupAura's
// (OnboardingChrome.swift), frozen at one moment — Finder shows a background as a still
// picture — and the glass wash and card follow SetupFrame.
//
// The geometry has to agree with dmgbuild-settings.py: the window size, and the two icons
// centred at APP_CENTER and APPS_CENTER (Finder's coordinates, from the top left).
//
// Two things here are Finder's to decide, not ours:
//
// - How much of the picture shows. The window holds 640 × WINDOW below its title bar, but
//   Finder's path bar and status bar (a global setting, which wins over the image's own)
//   each cover 28 points of its bottom. The card takes the top CARD_AREA and the window
//   is one bar taller, so the whole rim shows with the path bar on; with no bar the rim
//   is thicker at the bottom, and with both bars its lower edge goes under the second.
//   The picture runs on past the window's bottom so that no title bar height ever
//   uncovers Finder's own white.
// - The colour of the icons' names: black in light mode, white in dark mode, over
//   whatever is behind them, with no setting for it. On the white card the names read in
//   light mode only; in dark mode they fade into it. That was chosen over a mid-tone
//   behind the names — the icons say what they are without them. The check below keeps
//   the light-mode half of the bargain.

import AppKit
import SwiftUI

let WIDTH: CGFloat = 640
let HEIGHT: CGFloat = 388
/// What the card and its rim take: the top of the window.
let CARD_AREA: CGFloat = 320
/// One of Finder's bottom bars, measured on macOS 26.
let FINDER_BAR: CGFloat = 28
/// The window's own height below its title bar.
let WINDOW: CGFloat = CARD_AREA + FINDER_BAR
/// The glass rim around the card.
let RIM: CGFloat = 12
let ICON: CGFloat = 128
/// Below the title, with room under the names for the closing line.
let ICON_Y: CGFloat = 150
let APP_CENTER = CGPoint(x: 170, y: ICON_Y)
let APPS_CENTER = CGPoint(x: 470, y: ICON_Y)
/// Where Finder writes each icon's name, 13-point, under the icon.
let LABEL_BAND = (top: ICON_Y + ICON / 2 + 4, height: CGFloat(18))

func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255, opacity: alpha)
}

// SetupColor and Semantic
let phosphor = hex(0x61C58C)
let brandDeep = hex(0x0D3A25)
let brand = hex(0x14543A)
let confirmation = hex(0x30D158)
let card = hex(0xFBFBFB)

/// SetupAura at one moment: the same blobs, gradient and blur, with `t` fixed.
struct Aura: View {
    struct Blob {
        let color: Color
        let size: CGSize
        let center: CGPoint
        let period: Double
        let phase: Double
    }

    let blobs: [Blob] = [
        Blob(color: phosphor, size: .init(width: 0.38, height: 0.42), center: .init(x: 0.33, y: 0.33), period: 5, phase: 0),
        Blob(color: hex(0x1F8A5A, 0.9), size: .init(width: 0.36, height: 0.44), center: .init(x: 0.70, y: 0.38), period: 6, phase: 2),
        Blob(color: phosphor.opacity(0.75), size: .init(width: 0.42, height: 0.36), center: .init(x: 0.51, y: 0.70), period: 4, phase: 1),
        Blob(color: hex(0x2F9E67, 0.95), size: .init(width: 0.32, height: 0.40), center: .init(x: 0.28, y: 0.64), period: 6, phase: 3),
        Blob(color: confirmation.opacity(0.7), size: .init(width: 0.30, height: 0.36), center: .init(x: 0.71, y: 0.68), period: 5, phase: 4),
        Blob(color: brand.opacity(0.55), size: .init(width: 0.26, height: 0.30), center: .init(x: 0.53, y: 0.35), period: 7, phase: 1),
        Blob(color: confirmation.opacity(0.45), size: .init(width: 0.24, height: 0.28), center: .init(x: 0.58, y: 0.60), period: 4, phase: 2),
    ]
    /// The moment the picture is taken at, chosen by eye.
    let t: Double = 1.3

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                AngularGradient(colors: [
                    phosphor.opacity(0.8), brandDeep.opacity(0.55), confirmation.opacity(0.6), phosphor.opacity(0.1),
                    hex(0x2F9E67, 0.75), brand.opacity(0.25), phosphor.opacity(0.8),
                ], center: .center)
                .frame(width: size.width * 1.7, height: size.height * 1.7)
                .rotationEffect(.degrees((t / 9).truncatingRemainder(dividingBy: 1) * 360))
                ForEach(blobs.indices, id: \.self) { i in
                    let blob = blobs[i]
                    let s = (sin((t + blob.phase) / blob.period * .pi) + 1) / 2
                    let dx = (0.38 * sin(s * .pi * 1.5) - 0.1 * s) * blob.size.width * size.width
                    let dy = (-0.26 * sin(s * .pi) + 0.3 * s * s) * blob.size.height * size.height
                    Ellipse()
                        .fill(RadialGradient(colors: [blob.color, blob.color.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: blob.size.width * size.width / 2))
                        .frame(width: blob.size.width * size.width, height: blob.size.height * size.height)
                        .scaleEffect(0.85 + 0.4 * s)
                        .opacity(0.45 + 0.55 * s)
                        .position(x: blob.center.x * size.width + dx, y: blob.center.y * size.height + dy)
                }
            }
            .frame(width: size.width, height: size.height)
            .blur(radius: 22)
        }
    }
}

/// The drag, as a run of dots — the record window's dot-matrix display.
struct Arrow: View {
    var body: some View {
        Canvas { context, _ in
            let startX = APP_CENTER.x + ICON / 2 + 36, endX = APPS_CENTER.x - ICON / 2 - 36
            let y = APP_CENTER.y - 6
            let pitch: CGFloat = 9, dot: CGFloat = 5
            func dotAt(_ x: CGFloat, _ y: CGFloat, _ alpha: Double) {
                context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                             with: .color(brand.opacity(alpha)))
            }
            let count = Int(((endX - startX) / pitch).rounded(.down))
            for index in 0...count {
                dotAt(endX - CGFloat(count - index) * pitch, y, 0.3 + 0.65 * Double(index) / Double(max(count, 1)))
            }
            for step in 1...3 {
                let offset = CGFloat(step) * pitch * 0.8
                dotAt(endX - offset, y - offset, 0.95)
                dotAt(endX - offset, y + offset, 0.95)
            }
        }
    }
}

/// A step's number in a green dot, and what to do.
struct StepLabel: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(brand))
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(brandDeep)
        }
    }
}

struct Background: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            // The rim: the aura under SetupFrame's light glass wash, a little thinner so
            // the green carries in a rim this narrow.
            Aura()
            LinearGradient(stops: [
                .init(color: .white.opacity(0.35), location: 0),
                .init(color: .white.opacity(0.12), location: 0.45),
                .init(color: .white.opacity(0.24), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            shape.fill(card)
                .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                .frame(width: WIDTH - 2 * RIM, height: CARD_AREA - 2 * RIM)
                .offset(x: RIM, y: RIM)
            Arrow()
            // Step 1 over the arrow: the drag.
            StepLabel(number: 1, text: "Drag")
                .position(x: (APP_CENTER.x + APPS_CENTER.x) / 2, y: APP_CENTER.y - 52)
            VStack(spacing: 0) {
                // setupTitle: semibold, tracked in by 3 %, the setup's label colour.
                Text("Drag, then open")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-28 * 0.03)
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.top, 34)
                Spacer()
                // Step 2 — the one a drag leaves out: a Finder copy starts nothing, and
                // the window would otherwise sit there with nothing opening. The icon in
                // this window opens the copy in Applications (AppInstaller).
                VStack(spacing: 5) {
                    StepLabel(number: 2, text: "Then double-click SpeechText in this window")
                    Text("It opens the copy in Applications, and setup begins.")
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.62))
                }
                .padding(.bottom, CARD_AREA - LABEL_BAND.top - LABEL_BAND.height - 62)
            }
            .frame(width: WIDTH, height: CARD_AREA)
        }
        .frame(width: WIDTH, height: HEIGHT, alignment: .topLeading)
    }
}

/// The mean relative luminance (WCAG) of a band of the rendered picture.
func luminance(of rep: NSBitmapImageRep, in rect: CGRect, scale: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    var total: CGFloat = 0, count: CGFloat = 0
    for py in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
        for px in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            total += 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
            count += 1
        }
    }
    return total / max(count, 1)
}

@MainActor
func render(scale: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)

    // Finder's black names in light mode must reach 4.5:1 — relative luminance 0.175 or more.
    for center in [APP_CENTER, APPS_CENTER] {
        let band = CGRect(x: center.x - 60, y: LABEL_BAND.top, width: 120, height: LABEL_BAND.height)
        let l = luminance(of: rep, in: band, scale: scale)
        guard l >= 0.175 else {
            FileHandle.standardError.write("background.swift: under the icon at x=\(Int(center.x)) the luminance is \(String(format: "%.3f", l)); Finder's black names would not read on it (needs 0.175 or more)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift background.swift OUT_DIR\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
try MainActor.assumeIsolated {
    try render(scale: 1, to: out.appendingPathComponent("background.png"))
    try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
}
