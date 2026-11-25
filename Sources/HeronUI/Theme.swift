import AppKit
import SwiftUI

/// The "instrument cluster" design language from the mockups.
/// Colour = metric. Red appears only for warnings (too hot, too full).
public enum Theme {
    /// A colour with one value for light mode and one for dark mode.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
            })
    }

    /// Colour values as (light, dark) sRGB hex, kept in one table so a test can check contrast.
    public enum Palette {
        // Text colours: each reaches 4.5:1 (WCAG AA) against every surface in `textBackgrounds`.
        // Several older values sat at 3.3–4.2:1 (light CPU/network/warning, dark warning).
        public static let cpu: (light: UInt32, dark: UInt32) = (0x1F62C6, 0x6AA7FF)
        public static let gpu: (light: UInt32, dark: UInt32) = (0x7247D6, 0xBB92FF)
        public static let memory: (light: UInt32, dark: UInt32) = (0x0E744C, 0x3DDC97)
        public static let network: (light: UInt32, dark: UInt32) = (0x935700, 0xFFB020)
        public static let warning: (light: UInt32, dark: UInt32) = (0xBF2C20, 0xFF7E7C)
        public static let muted: (light: UInt32, dark: UInt32) = (0x5B626C, 0x9FA6B0)
        /// The second of two rates: network upload, disk write (the first is the metric colour or ink).
        public static let upload: (light: UInt32, dark: UInt32) = (0x474D57, 0xC3C8D2)
        /// Claude's orange as text: its menu bar mark, tag and value with Colour set to Metric
        /// (the brand 0xD97757 reaches only 2.5:1 light and 3.6:1 dark).
        public static let claudeText: (light: UInt32, dark: UInt32) = (0x9E4A2A, 0xE59478)
        /// Amber, for a warning that is not yet red: memory pressure "Warning", the status pill.
        public static let caution: (light: UInt32, dark: UInt32) = (0x8A5A00, 0xE0A33A)
        public static let text = [cpu, gpu, memory, network, warning, muted, settingsPickedText, upload, caution, ai, claudeText]

        public static let card: (light: UInt32, dark: UInt32) = (0xEEF0F3, 0x262A30)
        public static let track: (light: UInt32, dark: UInt32) = (0xDDE1E6, 0x30353C)

        // The Settings window's surfaces (the Settings design canvas, which is drawn dark; the
        // light values are its counterparts).
        public static let settingsWindow: (light: UInt32, dark: UInt32) = (0xF5F5F7, 0x28282B)
        public static let settingsSidebar: (light: UInt32, dark: UInt32) = (0xEAEAED, 0x232326)
        public static let settingsCard: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x303034)
        public static let settingsPreview: (light: UInt32, dark: UInt32) = (0xEDEDF0, 0x1C1C1F)
        /// Behind a popover or panel drawn in Settings: the popover's own background.
        public static let settingsPanel: (light: UInt32, dark: UInt32) = (0xFBFBFC, 0x2E2E31)
        /// Card borders and the lines between rows.
        public static let settingsLine: (light: UInt32, dark: UInt32) = (0xDCDCE1, 0x3D3D42)
        /// The selected sidebar row, small square buttons and the chart readouts' box. Text of any
        /// colour sits on it, so it is in `textBackgrounds` (light was 0xDCDCE1: the metric colours
        /// fell to 4.2:1 there).
        public static let settingsSelection: (light: UInt32, dark: UInt32) = (0xE4E4E8, 0x3A3A3F)
        /// The chosen segment of Settings › Menu Bar's compact segmented controls (primary text on it).
        public static let settingsSegment: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x5A5A60)
        /// The selected row of Settings › Overview's section list, and the text that sits on it
        /// (names in primary; the hint, grip and eye in `settingsPickedText`, 4.5:1 on the fill).
        public static let settingsPicked: (light: UInt32, dark: UInt32) = (0xDCE8FA, 0x2B4A72)
        public static let settingsPickedText: (light: UInt32, dark: UInt32) = (0x3D4A5C, 0xC9D6EA)
        /// The fan colour: the fans' menu bar tile and glyph (never text).
        public static let fan: (light: UInt32, dark: UInt32) = (0x127A85, 0x5FC9D3)
        /// AI usage: its card title, tile and bars.
        public static let ai: (light: UInt32, dark: UInt32) = (0xA8327A, 0xF08CC8)
        /// Claude's brand mark (a fixed glyph fill, like the Heron tile).
        public static let claude: UInt32 = 0xD97757
        /// The ink of Settings › Menu Bar's menu bar strip (text and the template item).
        public static let menuBarInk: (light: UInt32, dark: UInt32) = (0x111111, 0xF5F5F7)

        // Fixed fills, the same in both modes. `success` carries white glyphs, never text (3:1,
        // WCAG's non-text contrast); `accent` also carries white text (the update mock's "Install"), so 4.5:1. The badge carries its own text colour.
        public static let accent: UInt32 = 0x0071E3
        public static let success: UInt32 = 0x2E8B3E
        public static let badge: (text: UInt32, fill: UInt32) = (0x1C1C1F, 0xFFB020)

        /// Surfaces text sits on: our cards, plus approximations of the system popover, window,
        /// grouped-form row and sheet backgrounds in each mode, and the Settings window's surfaces.
        public static let textBackgrounds: (light: [UInt32], dark: [UInt32]) = (
            [
                card.light, 0xECECEC, 0xFFFFFF, 0xF5F5F5, 0xE5E5E5,
                settingsWindow.light, settingsSidebar.light, settingsCard.light, settingsPreview.light, settingsPanel.light,
                settingsSelection.light,
            ],
            [
                card.dark, 0x323232, 0x2A2A2A, 0x3A3A3A, 0x1E1E1E,
                settingsWindow.dark, settingsSidebar.dark, settingsCard.dark, settingsPreview.dark, settingsPanel.dark,
                settingsSelection.dark,
            ]
        )

        /// A text colour as it is written on a fill of its own colour (`Theme.Tint`): mixed 15%
        /// toward black in light mode and 28% toward white in dark, so it keeps 4.5:1 on the tint
        /// over every surface in `textBackgrounds` (the plain colours fell to 3.6–4.2:1 there).
        public static func onTint(_ pair: (light: UInt32, dark: UInt32)) -> (light: UInt32, dark: UInt32) {
            func mix(_ c: UInt32, toward t: UInt32, _ k: Double) -> UInt32 {
                [16, 8, 0].reduce(0) { result, shift in
                    let a = Double(c >> shift & 0xff), b = Double(t >> shift & 0xff)
                    return result | UInt32((a + (b - a) * k).rounded()) << shift
                }
            }
            return (mix(pair.light, toward: 0x000000, 0.15), mix(pair.dark, toward: 0xFFFFFF, 0.28))
        }

        /// Approximations of the menu bar behind Heron's item, for the item's metric colours.
        public static let menuBarBackgrounds: (light: [UInt32], dark: [UInt32]) = ([0xE9E9EC, 0xF6F6F6], [0x141416, 0x2A2A2D])

        /// The colour pair of a metric; nil for neutral metrics, which use the plain ink.
        public static func pair(for metric: MetricColor) -> (light: UInt32, dark: UInt32)? {
            switch metric {
            case .cpu: return cpu
            case .gpu: return gpu
            case .memory: return memory
            case .network: return network
            case .warning: return warning
            case .neutral: return nil
            }
        }
    }

    static func dynamic(_ pair: (light: UInt32, dark: UInt32)) -> Color { dynamic(light: pair.light, dark: pair.dark) }

    /// One half of a pair, fixed: for images drawn offscreen (the menu bar item), which know the
    /// menu bar's mode but have no appearance to resolve `dynamic` against.
    static func resolved(_ pair: (light: UInt32, dark: UInt32), dark: Bool) -> Color { Color(nsColor: NSColor(hex: dark ? pair.dark : pair.light)) }

    public static let cpu = dynamic(Palette.cpu)
    public static let gpu = dynamic(Palette.gpu)
    public static let memory = dynamic(Palette.memory)
    public static let network = dynamic(Palette.network)
    public static let warning = dynamic(Palette.warning)

    public static let card = dynamic(Palette.card)
    public static let track = dynamic(Palette.track)
    public static let muted = dynamic(Palette.muted)
    public static let upload = dynamic(Palette.upload)
    public static let caution = dynamic(Palette.caution)

    static let settingsWindow = dynamic(Palette.settingsWindow)
    static let settingsSidebar = dynamic(Palette.settingsSidebar)
    static let settingsCard = dynamic(Palette.settingsCard)
    static let settingsPreview = dynamic(Palette.settingsPreview)
    static let settingsPanel = dynamic(Palette.settingsPanel)
    static let settingsLine = dynamic(Palette.settingsLine)
    static let settingsSelection = dynamic(Palette.settingsSelection)
    static let settingsSegment = dynamic(Palette.settingsSegment)
    static let settingsPicked = dynamic(Palette.settingsPicked)
    static let settingsPickedText = dynamic(Palette.settingsPickedText)
    static let fan = dynamic(Palette.fan)
    public static let ai = dynamic(Palette.ai)

    /// A pill or box tinted with a colour, with text in that colour on it (the status pill, a
    /// card's chip, the AI pill, "In the menu bar", the hottest sensor, the resets advice): the
    /// fill is the colour at `alpha`, the text `Palette.onTint` of it. Every such tint is one of
    /// these, so the contrast guard covers it (`ContrastTests.textOnItsOwnTintMeetsAA`).
    struct Tint {
        static let alpha = 0.16
        let pair: (light: UInt32, dark: UInt32)
        var fill: Color { Theme.dynamic(pair).opacity(Self.alpha) }
        var text: Color { Theme.dynamic(Palette.onTint(pair)) }

        static let caution = Tint(pair: Palette.caution)
        static let warning = Tint(pair: Palette.warning)
        static let memory = Tint(pair: Palette.memory)
    }

    /// WCAG 2 contrast ratio of two sRGB colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel & 0xff) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ hex: UInt32) -> Double {
            let r: Double = linear(hex >> 16), g: Double = linear(hex >> 8), b: Double = linear(hex)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Numbers use the system font with tabular digits, so digits do not jitter as they change and
    /// words beside them stay in the text face (monospace is for the menu bar item only).
    public static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    public static func color(for metric: MetricColor) -> Color {
        switch metric {
        case .cpu: return cpu
        case .gpu: return gpu
        case .memory: return memory
        case .network: return network
        case .neutral: return .primary
        case .warning: return warning
        }
    }
}

public enum MetricColor { case cpu, gpu, memory, network, neutral, warning }

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// The Heron mark's geometry: a gauge whose hub is the heron's head and whose needle is its beak.
/// One home for the shapes, so the app icon, the in-app mark and the menu bar template image
/// cannot drift apart. Everything is in a 100 × 100 space with y pointing down; every part is a
/// filled shape (the arcs are already stroked).
public enum HeronShape {
    /// Where the needle points, in degrees (0 = right, 90 = down, 270 = straight up).
    static let needle = 312.5
    static let center = CGPoint(x: 50, y: 56)

    /// Immutable CGPaths, shared read-only across threads.
    public struct Parts: @unchecked Sendable {
        public let track: CGPath  // the whole dial
        public let value: CGPath  // the dial up to the needle
        public let head: CGPath
        public let beak: CGPath
        public let mouth: CGPath
        public let eye: CGPath
    }

    /// `glyph` false: the app icon's proportions (inside the 96-unit tile).
    /// `glyph` true: the bare menu bar glyph, larger and bolder so it reads at 16 pt.
    /// Built once each: the menu bar draws the glyph on every sample.
    public static func parts(glyph: Bool) -> Parts { glyph ? glyphParts : iconParts }

    private static let glyphParts = build(glyph: true)
    private static let iconParts = build(glyph: false)

    /// The menu bar glyph in one ink: the dial at `glyphTrackOpacity`, the filled part, head and
    /// beak solid. The template image and `HeronGlyph` both draw these, so they cannot drift.
    public static var glyphSolid: [CGPath] { [glyphParts.value, glyphParts.head, glyphParts.beak] }
    public static let glyphTrackOpacity: CGFloat = 0.35

    private static func build(glyph: Bool) -> Parts {
        let k: CGFloat = glyph ? 1.2 : 1
        let c = center
        let a = needle * .pi / 180
        let u = CGPoint(x: cos(a), y: sin(a)), n = CGPoint(x: -sin(a), y: cos(a))
        func at(_ along: CGFloat, _ side: CGFloat = 0) -> CGPoint {
            CGPoint(x: c.x + (u.x * along + n.x * side) * k, y: c.y + (u.y * along + n.y * side) * k)
        }
        func arc(to end: Double) -> CGPath {
            let path = CGMutablePath()
            let steps = 72
            for i in 0...steps {
                let t = (135 + (end - 135) * Double(i) / Double(steps)) * .pi / 180
                let p = CGPoint(x: c.x + 30 * k * cos(t), y: c.y + 30 * k * sin(t))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path.copy(strokingWithWidth: glyph ? 10 : 5, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let headRadius: CGFloat = glyph ? 10 : 7
        let beak = CGMutablePath()
        beak.move(to: at(5, -3.75))
        beak.addLine(to: at(25))
        beak.addQuadCurve(to: at(5, 3.8), control: at(14.85, 3.5))
        beak.closeSubpath()
        let mouth = CGMutablePath()
        mouth.move(to: at(5))
        mouth.addLine(to: at(17))
        let eye = at(1.06, -1.51)
        return Parts(
            track: arc(to: 405),
            value: arc(to: needle),
            head: CGPath(ellipseIn: CGRect(x: c.x - headRadius, y: c.y - headRadius, width: headRadius * 2, height: headRadius * 2), transform: nil),
            beak: beak,
            mouth: mouth.copy(strokingWithWidth: 0.9, lineCap: .round, lineJoin: .round, miterLimit: 10),
            eye: CGPath(ellipseIn: CGRect(x: eye.x - 1.8, y: eye.y - 1.8, width: 3.6, height: 3.6), transform: nil)
        )
    }
}

/// The Heron app icon: the gauge heron on a midnight-indigo tile.
public struct HeronMark: View {
    var size: CGFloat
    public init(size: CGFloat) { self.size = size }

    /// Brand colours, used only by the mark (metric colours stay in `Palette`).
    static let tileTop: UInt32 = 0x262B66, tileBottom: UInt32 = 0x0B0D26
    static let coral: UInt32 = 0xFF7A59, feather: UInt32 = 0xF2F5F5

    public var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 100
            context.scaleBy(x: s, y: s)
            context.fill(
                Path(roundedRect: CGRect(x: 2, y: 2, width: 96, height: 96), cornerRadius: 22),
                with: .linearGradient(
                    Gradient(colors: [Color(nsColor: NSColor(hex: Self.tileTop)), Color(nsColor: NSColor(hex: Self.tileBottom))]),
                    startPoint: CGPoint(x: 0, y: 2), endPoint: CGPoint(x: 0, y: 98)))
            let parts = HeronShape.parts(glyph: false)
            let coral = Color(nsColor: NSColor(hex: Self.coral)), feather = Color(nsColor: NSColor(hex: Self.feather))
            context.fill(Path(parts.track), with: .color(feather.opacity(0.25)))
            context.fill(Path(parts.value), with: .color(coral))
            context.fill(Path(parts.head), with: .color(feather))
            context.fill(Path(parts.beak), with: .color(coral))
            context.fill(Path(parts.mouth), with: .color(Color(nsColor: NSColor(hex: Self.tileBottom))))
            context.fill(Path(parts.eye), with: .color(Color(nsColor: NSColor(hex: Self.tileBottom))))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
