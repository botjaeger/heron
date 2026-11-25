import HeronCore
import SwiftUI

/// Heron's one icon set: the popover, the panels and Settings all draw from here. Each icon is the
/// design's SVG data on a 24-unit grid, kept verbatim (rect, circle and path `d` strings) so the app
/// and the prototype cannot drift apart. Drawn as a stroke: 1.8 units, round caps and joins.
public enum HeronIcon: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, disk, sensors, fan, list, activity
    // Settings sidebar.
    case general, menuBar, overview, alerts, updates, battery
    // Settings controls: the sidebar search, Overview's eye, Alerts' "Add rule…".
    case search, eye, eyeOff, plus
    // Settings › Menu Bar: the drag handle on each item.
    case grip
    // Popover and panels: a row with history, the card's "…", rate arrows, the card's chevron.
    case chart, more, arrowDown, arrowUp, chevronRight
    // The first run's ticked item; About's "up to date".
    case check
    // AI usage: its Settings pane and card (the design's sparkle); a pinned limit.
    case ai, pin
    // A panel's "Copy picture": two overlapping sheets.
    case copy

    enum Element {
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat)
        case circle(x: CGFloat, y: CGFloat, radius: CGFloat)
        case path(String)
    }

    /// The SVG elements, in the 24 × 24 box.
    var elements: [Element] {
        switch self {
        case .cpu:
            return [
                .rect(x: 6, y: 6, width: 12, height: 12, radius: 2), .rect(x: 9.5, y: 9.5, width: 5, height: 5, radius: 1),
                .path("M9 2.5v3M15 2.5v3M9 18.5v3M15 18.5v3M2.5 9h3M2.5 15h3M18.5 9h3M18.5 15h3"),
            ]
        case .gpu: return [.rect(x: 2.5, y: 6, width: 19, height: 12, radius: 2.5), .circle(x: 15.5, y: 12, radius: 3), .path("M6 10h4M6 14h4")]
        case .memory:
            return [
                .rect(x: 2.5, y: 7, width: 19, height: 9, radius: 1.5),
                .path("M6.5 10.5v2M10 10.5v2M14 10.5v2M17.5 10.5v2M5.5 16v2.5M18.5 16v2.5"),
            ]
        case .network: return [.path("M8 19V5M8 5 4.5 8.5M8 5l3.5 3.5M16 5v14M16 19l-3.5-3.5M16 19l3.5-3.5")]
        case .disk: return [.rect(x: 3, y: 5, width: 18, height: 14, radius: 3), .path("M3 13h18"), .circle(x: 17, y: 16, radius: 0.6)]
        case .sensors: return [.path("M10 14.5V5a2 2 0 1 1 4 0v9.5a4 4 0 1 1-4 0z"), .path("M12 9v7")]
        case .fan:
            return [
                .circle(x: 12, y: 12, radius: 1.8),
                .path("M12 10.2c0-4 1-7 4-7 2.5 0 2.5 3.5-1 5.5M13.6 12.9c3.5 2 5.5 4.3 4 6.9-1.3 2.2-4.3.5-4.2-3.6M10.4 12.9c-3.5 2-6.4 2.5-7.9-.1-1.2-2.2 1.8-3.9 5.4-1.8"),
            ]
        case .list: return [.path("M8 6h12M8 12h12M8 18h12"), .circle(x: 4, y: 6, radius: 0.6), .circle(x: 4, y: 12, radius: 0.6), .circle(x: 4, y: 18, radius: 0.6)]
        case .activity: return [.path("M3 12h4l3-7 4 14 3-7h4")]
        case .general:
            return [.path("M12 8.5a3.5 3.5 0 1 0 0 7a3.5 3.5 0 1 0 0-7M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1")]
        case .menuBar: return [.path("M3 5.5h18v4H3zM15 7.5h3M3 13.5h18M3 17.5h11")]
        case .overview: return [.path("M4 4h16v5H4zM4 11h16v4H4zM4 17h16v3H4z")]
        case .alerts: return [.path("M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5h4")]
        case .updates: return [.path("M20 12a8 8 0 1 1-2.3-5.6M20 4v4.5h-4.5")]
        case .battery: return [.path("M2.5 7.5h16v9h-16zM21 10.5v3M5 10h7v4H5z")]
        case .search: return [.path("M10.5 17a6.5 6.5 0 1 0 0-13a6.5 6.5 0 1 0 0 13M15.5 15.5 20 20")]
        case .eye: return [.path("M2.5 12C5 7 8.5 5 12 5s7 2 9.5 7c-2.5 5-6 7-9.5 7s-7-2-9.5-7zM12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6")]
        case .eyeOff: return [.path("M2.5 12C5 7 8.5 5 12 5s7 2 9.5 7c-2.5 5-6 7-9.5 7s-7-2-9.5-7zM4 4l16 16")]
        case .plus: return [.path("M12 5v14M5 12h14")]
        case .grip:
            return [
                .circle(x: 9, y: 6, radius: 0.5), .circle(x: 15, y: 6, radius: 0.5), .circle(x: 9, y: 12, radius: 0.5),
                .circle(x: 15, y: 12, radius: 0.5), .circle(x: 9, y: 18, radius: 0.5), .circle(x: 15, y: 18, radius: 0.5),
            ]
        case .chart: return [.path("M4 19V5M4 19h16M8 15l3-4 3 2 4-6")]
        case .more: return [.circle(x: 6, y: 12, radius: 0.5), .circle(x: 12, y: 12, radius: 0.5), .circle(x: 18, y: 12, radius: 0.5)]
        case .arrowDown: return [.path("M12 5v14M6.5 13.5 12 19l5.5-5.5")]
        case .arrowUp: return [.path("M12 19V5M6.5 10.5 12 5l5.5 5.5")]
        case .chevronRight: return [.path("M9 6l6 6-6 6")]
        case .check: return [.path("M5 12.6l4.6 4.4L19 7")]
        case .ai: return [.path("M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM18.5 15.5l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z")]
        case .pin: return [.path("M15 3l6 6-3 1-4 4 1 5-2 2-4-5-5 5-1-1 5-5-5-4 2-2 5 1 4-4z")]
        case .copy:
            return [
                .rect(x: 8.5, y: 8.5, width: 12, height: 12, radius: 2.5),
                .path("M15.5 8.5V6a2.5 2.5 0 0 0-2.5-2.5H6A2.5 2.5 0 0 0 3.5 6v7A2.5 2.5 0 0 0 6 15.5h2.5"),
            ]
        }
    }

    /// The outline in the 24-unit box (y down). Empty if a path string uses a command the parser lacks.
    /// Parsed once per icon: every card, row and Settings tile draws these on each render.
    public var path: CGPath { Self.paths[self] ?? CGMutablePath() }

    // CGPath is immutable once built (CGMutablePath copies are never handed out), so sharing is safe.
    nonisolated(unsafe) private static let paths: [HeronIcon: CGPath] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.buildPath()) })

    private func buildPath() -> CGPath {
        let result = CGMutablePath()
        for element in elements {
            switch element {
            case .rect(let x, let y, let w, let h, let r):
                result.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            case .circle(let x, let y, let r):
                result.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            case .path(let d):
                guard let p = SVGPath.parse(d) else { return CGMutablePath() }
                result.addPath(p)
            }
        }
        return result
    }

    public static let gridSize: CGFloat = 24
    public static let strokeWidth: CGFloat = 1.8
}

extension HeronIcon {
    /// The icon as a template image, for controls AppKit draws: a `Menu`'s label shows only its
    /// text and images, so a SwiftUI-drawn glyph in it is never seen.
    func templateImage(size: CGFloat, weight: CGFloat = HeronIcon.strokeWidth) -> NSImage {
        let path = self.path
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: size / HeronIcon.gridSize, y: size / HeronIcon.gridSize)
            ctx.addPath(path)
            ctx.setLineWidth(weight)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The icon scaled into its frame.
struct HeronIconShape: Shape {
    var icon: HeronIcon
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / HeronIcon.gridSize
        return Path(icon.path).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s))
    }
}

/// An icon at a point size, stroked in the current foreground style.
public struct HeronIconView: View {
    var icon: HeronIcon
    var size: CGFloat
    /// Stroke width in grid units (the design's 1.8; Settings tiles draw bolder, as in the canvas).
    var weight: CGFloat
    public init(_ icon: HeronIcon, size: CGFloat = 16, weight: CGFloat = HeronIcon.strokeWidth) { self.icon = icon; self.size = size; self.weight = weight }
    public var body: some View {
        HeronIconShape(icon: icon)
            .stroke(style: StrokeStyle(lineWidth: weight * size / HeronIcon.gridSize, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The subset of SVG path syntax the icon data uses: M L H V C S A Z, absolute and relative,
/// with implicit repeats ("M8 5 4.5 8.5" is a move then a line) and packed numbers ("-4.3.5").
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        var tokens: [Token] = []
        var chars = Array(d.unicodeScalars)[...]
        while let c = chars.first {
            if CharacterSet.letters.contains(c) {
                tokens.append(.command(Character(c))); chars.removeFirst()
            } else if c == " " || c == "," || c == "\n" || c == "\t" {
                chars.removeFirst()
            } else if let n = number(&chars) {
                tokens.append(.number(n))
            } else {
                return nil
            }
        }
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var command: Character?
        var i = 0
        func next() -> CGFloat? {
            guard i < tokens.count, case .number(let n) = tokens[i] else { return nil }
            i += 1
            return n
        }
        // The second control point of the last C or S, which an S reflects.
        var lastControl: CGPoint?
        while i < tokens.count {
            if case .command(let c) = tokens[i] { command = c; i += 1 }
            guard let cmd = command else { return nil }
            let relative = cmd.isLowercase
            let base = relative ? current : .zero
            let control = lastControl
            lastControl = nil
            switch cmd.uppercased() {
            case "M":
                guard let x = next(), let y = next() else { return nil }
                current = CGPoint(x: base.x + x, y: base.y + y)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"  // further pairs are lines
            case "L":
                guard let x = next(), let y = next() else { return nil }
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: current)
            case "H":
                guard let x = next() else { return nil }
                current.x = (relative ? current.x : 0) + x
                path.addLine(to: current)
            case "V":
                guard let y = next() else { return nil }
                current.y = (relative ? current.y : 0) + y
                path.addLine(to: current)
            case "C":
                guard let x1 = next(), let y1 = next(), let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return nil }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: end, control1: CGPoint(x: base.x + x1, y: base.y + y1), control2: CGPoint(x: base.x + x2, y: base.y + y2))
                lastControl = CGPoint(x: base.x + x2, y: base.y + y2)
                current = end
            case "S":
                // The first control point mirrors the previous curve's second one (or is the
                // current point when there was no curve before).
                guard let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return nil }
                let first = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: end, control1: first, control2: CGPoint(x: base.x + x2, y: base.y + y2))
                lastControl = CGPoint(x: base.x + x2, y: base.y + y2)
                current = end
            case "A":
                guard let rx = next(), let ry = next(), let rotation = next(), let large = next(), let sweep = next(), let x = next(), let y = next() else { return nil }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                arc(path, from: current, to: end, rx: rx, ry: ry, degrees: rotation, large: large != 0, sweep: sweep != 0)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
                // A number after Z would need a new command.
                if i < tokens.count, case .number = tokens[i] { return nil }
            default:
                return nil
            }
        }
        return path
    }

    enum Token { case command(Character), number(CGFloat) }

    /// One number: optional sign, digits, at most one decimal point. A second point or a sign ends it.
    static func number(_ chars: inout ArraySlice<Unicode.Scalar>) -> CGFloat? {
        var text = ""
        if let c = chars.first, c == "-" || c == "+" { text.append(Character(c)); chars.removeFirst() }
        var seenPoint = false
        while let c = chars.first {
            if c == "." { if seenPoint { break }; seenPoint = true } else if !("0"..."9").contains(c) { break }
            text.append(Character(c)); chars.removeFirst()
        }
        return Double(text).map { CGFloat($0) }
    }

    /// SVG elliptical arc (endpoint form) as a CG arc on a transformed unit circle (SVG 1.1, F.6.5).
    static func arc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, rx: CGFloat, ry: CGFloat, degrees: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let phi = degrees * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large != sweep ? 1 : -1) * sqrt(max(0, num / den))
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let center = CGPoint(x: c * cx1 - s * cy1 + (p1.x + p2.x) / 2, y: s * cx1 + c * cy1 + (p1.y + p2.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: phi).scaledBy(x: rx, y: ry)
        // Positive delta is increasing angle, which CG calls counter-clockwise.
        path.addArc(center: .zero, radius: 1, startAngle: theta, endAngle: theta + delta, clockwise: delta < 0, transform: t)
    }
}

// MARK: - Shared parts

extension OverviewPart {
    /// The section's icon in the popover, its panel and Settings.
    public var icon: HeronIcon {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .network: return .network
        case .disk: return .disk
        case .sensors: return .sensors
        case .battery: return .battery
        case .ai: return .ai
        }
    }

    /// The section colour: its icon tile and (except battery and disk, which use the text colour) its title.
    var color: Color {
        switch self {
        case .cpu: return Theme.cpu
        case .gpu: return Theme.gpu
        case .memory, .battery: return Theme.memory
        case .network: return Theme.network
        case .disk: return .primary
        case .sensors: return Theme.warning
        case .ai: return Theme.ai
        }
    }

    var titleColor: Color { self == .battery ? .primary : color }
}

extension MenuItemKind {
    /// The tile a menu bar item is shown with (onboarding, Settings › Menu Bar): its overview
    /// section's, except fans, which have their own glyph and colour (as in Settings › Menu Bar).
    func tile(battery: BatteryReading? = nil, size: CGFloat = 26) -> IconTile {
        switch self {
        case .cpu: return IconTile(part: .cpu, size: size)
        case .gpu: return IconTile(part: .gpu, size: size)
        case .memory: return IconTile(part: .memory, size: size)
        case .network: return IconTile(part: .network, size: size)
        case .disk: return IconTile(part: .disk, size: size)
        case .temperature: return IconTile(part: .sensors, size: size)
        case .fans: return IconTile(part: .sensors, size: size, glyph: .fan, tint: Theme.fan)
        case .battery: return IconTile(part: .battery, battery: battery, size: size)
        case .ai: return IconTile(part: .ai, size: size, glyph: .ai, tint: Theme.ai)
        }
    }
}

/// A tinted rounded square with the section's glyph in its colour. Battery: the battery glyph,
/// filled to the charge, with a tick at the charge limit when macOS sets one.
struct IconTile: View {
    var part: OverviewPart
    var battery: BatteryReading?
    var size: CGFloat = 26
    /// Overrides for a tile that is not a section's own (fans).
    var glyph: HeronIcon?
    var tint: Color?

    var body: some View {
        let color = tint ?? part.color
        ZStack {
            RoundedRectangle(cornerRadius: size * 7 / 26).fill(color.opacity(0.15))
            if part == .battery && glyph == nil {
                BatteryIcon(fraction: battery?.percent ?? 0, limit: battery?.chargeLimit, low: battery.map(Warnings.isLow) ?? false).frame(
                    width: size * 24 / 26, height: size * 12 / 26)
            } else {
                HeronIconView(glyph ?? part.icon, size: size * 16 / 26)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The battery glyph (26 × 13 design units): outline and nub in the foreground style, the charge
/// in the memory colour (red when low, `Warnings.isLow`, as in the menu bar), a tick at the charge limit.
struct BatteryIcon: View {
    var fraction: Double
    var limit: Double?
    var low = false

    var body: some View {
        Canvas { context, size in
            let k = min(size.width / 26, size.height / 13)
            context.scaleBy(x: k, y: k)
            context.stroke(Path(roundedRect: CGRect(x: 0.75, y: 0.75, width: 21.5, height: 11.5), cornerRadius: 3), with: .foreground, lineWidth: 1.2)
            let charge = fraction.unitClamped
            if charge > 0 {
                context.fill(
                    Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 18 * charge, height: 8), cornerRadius: min(1.5, 9 * charge)),
                    with: .color(low ? Theme.warning : Theme.memory))
            }
            if let limit {
                context.fill(Path(CGRect(x: 2.5 + 18 * limit.unitClamped - 0.6, y: 1.6, width: 1.2, height: 9.8)), with: .foreground)
            }
            context.fill(Path(roundedRect: CGRect(x: 23.5, y: 4.5, width: 1.6, height: 4), cornerRadius: 0.8), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// The › at a card's right edge: dim at rest, bright on hover, in the section's colour when its
/// panel is open, red when the card is hot.
struct Chevron: View {
    var hovered = false
    var open = false
    var color: Color = Theme.cpu
    var hot = false
    var body: some View {
        HeronIconView(.chevronRight, size: 14, weight: 2)
            .foregroundStyle(hot ? Theme.warning : (open ? color : Theme.muted))
            .opacity(hot || open || hovered ? 1 : 0.7)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: open)
            .accessibilityHidden(true)
    }
}

/// One line in the overview header that says whether anything needs attention: the most serious
/// issue, and "+N" when there are more. Every threshold comes from `Warnings`.
struct StatusPill: View {
    enum Level: Int, Comparable {
        case normal, caution, alarm
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Issue: Equatable {
        var text: String
        var level: Level
    }

    /// Everything that needs attention, the most serious first (ties keep this order).
    static func issues(_ s: Snapshot) -> [Issue] {
        var list: [Issue] = []
        let cpuHot = SensorSummary.value(.cpu, in: s).map(Warnings.isHot) ?? false
        let gpuHot = SensorSummary.value(.gpu, in: s).map(Warnings.isHot) ?? false
        if cpuHot { list.append(Issue(text: "CPU running hot", level: .alarm)) }
        if gpuHot { list.append(Issue(text: "GPU running hot", level: .alarm)) }
        // One sensor over the limit while its component's average is not: name the sensor, not the
        // component, so the pill agrees with the CPU card (normal) and the Sensors card (hot).
        if !cpuHot && !gpuHot, let hottest = s.hottest, Warnings.isHot(hottest.celsius) {
            list.append(Issue(text: "\(hottest.name) running hot", level: .alarm))
        }
        switch s.memory?.pressure {
        case .critical: list.append(Issue(text: "Memory pressure critical", level: .alarm))
        case .warning: list.append(Issue(text: "Memory pressure high", level: .caution))
        default: break
        }
        if let root = s.rootVolume, Warnings.isNearlyFull(root) {
            list.append(Issue(text: "Disk nearly full", level: .alarm))
        }
        if let b = s.battery, Warnings.isLow(b) { list.append(Issue(text: "Battery low", level: .alarm)) }
        return list.enumerated().sorted { $0.element.level != $1.element.level ? $0.element.level > $1.element.level : $0.offset < $1.offset }.map(\.element)
    }

    /// What the pill says: the first issue and how many more, or all normal.
    static func state(_ s: Snapshot) -> (text: String, level: Level, more: Int) {
        let all = issues(s)
        guard let first = all.first else { return ("All normal", .normal, 0) }
        return (first.text, first.level, all.count - 1)
    }

    static func tint(_ level: Level) -> Theme.Tint {
        switch level {
        case .normal: return .memory
        case .caution: return .caution
        case .alarm: return .warning
        }
    }

    var snapshot: Snapshot
    var body: some View {
        let state = Self.state(snapshot)
        let tint = Self.tint(state.level)
        HStack(spacing: 6) {
            Circle().frame(width: 7, height: 7)
            Text(state.text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if state.more > 0 {
                // Outlined, not filled again: a second tint under the text fell to 2.7:1.
                Text("+\(state.more)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(tint.text.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(.horizontal, 10).frame(height: 24)
        .foregroundStyle(tint.text)
        .background(tint.fill, in: Capsule())
        .fixedSize()
        // "All normal" before Heron has read anything would be a claim with nothing behind it.
        .opacity(snapshot.awaitingReadings ? 0 : 1)
        .accessibilityHidden(snapshot.awaitingReadings)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.more > 0 ? "\(state.text), and \(state.more) more" : state.text)
    }
}

extension Sensor.Group {
    /// The group as a short name for a sentence: "CPU", "SSD", "Enclosure".
    var title: String {
        switch self {
        case .cpuPerformance, .cpuEfficiency: return "CPU"
        default: return rawValue
        }
    }
}

/// A big segmented ring: each part an arc in its colour, one after another from 12 o'clock, the
/// value in the middle with a small unit and an optional caption under it.
struct BigRing: View {
    var parts: [(fraction: Double, color: Color)]
    var size: CGFloat
    var value: String
    var unit: String = "%"
    var caption: String = ""
    var valueColor: Color = .primary

    /// Start and end (0...1) of each part's arc; parts never run past a full turn.
    static func segments(_ fractions: [Double]) -> [(start: Double, end: Double)] {
        var at = 0.0
        return fractions.map { f in
            let start = at
            at = min(1, at + max(0, f))
            return (start, at)
        }
    }

    var body: some View {
        let w = size * 0.075
        let segments = Self.segments(parts.map(\.fraction))
        ZStack {
            Circle().inset(by: w / 2).stroke(Theme.track, lineWidth: w)
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                Circle().inset(by: w / 2).trim(from: seg.start, to: seg.end)
                    .stroke(parts[i].color, lineWidth: w)
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: size * 0.01) {
                (Text(value).font(Theme.number(size * 0.26)).foregroundStyle(valueColor) + Text(unit).font(Theme.number(size * 0.13, weight: .regular)).foregroundStyle(Theme.muted))
                    .lineLimit(1).minimumScaleFactor(0.45)
                if !caption.isEmpty {
                    Text(caption).font(.system(size: size * 0.085, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: size - 3 * w)
            .offset(y: caption.isEmpty ? 0 : size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.isEmpty ? value + unit : "\(caption.capitalized) \(value)\(unit)")
    }
}

/// CPU history as two areas: user load in the CPU colour at the bottom, system load in grey on
/// top of it, each with its edge line (the stacked bars' twin, `UserSystemBars`).
struct UserSystemArea: View {
    var total: [Double]
    var system: [Double]
    var height: CGFloat = 40
    var points = 60

    var body: some View {
        let stacks = Array(UserSystemBars.stacks(total: total, system: system).suffix(points))
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, n = stacks.count
            let x = { (i: Int) in n > 1 ? w * CGFloat(i) / CGFloat(n - 1) : w }
            let y = { (v: Double) in h - CGFloat(v.unitClamped) * (h - 2) - 1 }
            let top = stacks.enumerated().map { CGPoint(x: x($0.offset), y: y($0.element.user + $0.element.system)) }
            let mid = stacks.enumerated().map { CGPoint(x: x($0.offset), y: y($0.element.user)) }
            if n > 1 {
                ZStack {
                    Path { p in
                        p.addLines(top + mid.reversed()); p.closeSubpath()
                    }.fill(UserSystemBars.systemColor.opacity(0.35))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for point in mid { p.addLine(to: point) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }.fill(Theme.cpu.opacity(0.2))
                    Path { p in p.addLines(top) }.stroke(UserSystemBars.systemColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    Path { p in p.addLines(mid) }.stroke(Theme.cpu, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The fan glyph turning at a speed that follows the fans: one turn per 6,000 rpm-seconds. The
/// angle accumulates, so a new rpm changes the speed without a jump. Still with Reduce Motion.
struct SpinningFan: View {
    var rpm: Double
    var size: CGFloat = 14
    @State private var phase = SpinPhase()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion || rpm <= 0
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            HeronIconView(.fan, size: size)
                .rotationEffect(.degrees(still ? 0 : phase.advance(to: context.date, rpm: rpm) * 360))
        }
        .frame(width: size, height: size)
    }
}

/// The fan's turn so far (0..<1), advanced by elapsed time × the current speed.
final class SpinPhase {
    private(set) var turns = 0.0
    private var last: Date?

    /// One turn per 6,000 rpm-seconds. A gap longer than half a second (paused, off screen) is
    /// not caught up, so the fan never leaps.
    func advance(to date: Date, rpm: Double) -> Double {
        if let last {
            let dt = min(0.5, max(0, date.timeIntervalSince(last)))
            turns = (turns + dt * max(0, rpm) / 6000).truncatingRemainder(dividingBy: 1)
        }
        last = date
        return turns
    }
}
