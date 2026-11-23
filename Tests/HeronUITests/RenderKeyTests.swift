import AppKit
import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

/// Class: a cached picture that misses one of its inputs. The status item skips its redraw while
/// `MenuBarLabel.renderKey` is unchanged, so two labels with one key must draw one image, and
/// every input that changes the image (a value, the mode, the scale, the look) changes the key.
@MainActor
@Suite struct RenderKeyTests {
    func snapshot(_ high: Bool, nudge: Double = 0) -> Snapshot {
        var s = MenuBarWidthTests().snapshot(high: high)
        s.date = Date(timeIntervalSince1970: 1_000_000)
        // A nudge below what any text shows; the glyphs (bar, gauge, battery) draw it unrounded.
        if var cpu = s.cpu { cpu.user = max(0, cpu.user - nudge); s.cpu = cpu }
        s.gpu?.device -= nudge
        s.memory?.app += UInt64(nudge * 1_000_000_000)
        s.disk?.volumes[0].available -= UInt64(nudge * 1_000_000_000_000)
        s.battery?.percent -= nudge
        s.battery?.chargeLimit = 0.8
        s.network?.downBytesPerSecond += nudge
        s.sensors[0].celsius += nudge
        return s
    }

    func history(_ shift: Double) -> MetricHistory {
        var h = MetricHistory()
        for i in 0..<30 {
            var s = snapshot(i.isMultiple(of: 3))
            s.date = Date(timeIntervalSince1970: 1_000_000 + Double(i))
            s.cpu = CPUReading(user: Double(i % 10) / 12 + shift, system: 0.1, idle: 0.2, cores: [], loadAverage: [])
            s.network?.downBytesPerSecond = Double(i * 1000 % 7000) + shift * 1000
            h.record(s)
        }
        return h
    }

    /// The same picture: the same pixels (`sameImage`) and the same template flag.
    func same(_ a: NSImage, _ b: NSImage) -> Bool { a.isTemplate == b.isTemplate && sameImage(a, b) }

    /// Every look of every item, over values, nudges, histories, modes and colour modes: whenever
    /// two labels share a key they draw the same pixels.
    @Test func equalKeysDrawEqualImages() {
        let histories = [history(0), history(0.3)]
        var compared = 0, sharedKeys = 0
        for mode in [MenuBarColour.monochrome, .metric] {
            let s = AppSettings(defaults: scratchDefaults("renderkey"))
            s.colourMode = mode
            for kind in MenuItemKind.allCases {
                for style in kind.styles {
                    for k in MenuItemKind.allCases { s.setShown(k, k == kind) }
                    s.setStyle(kind, style)
                    var seen: [(MenuBarLabel.RenderKey, NSImage)] = []
                    for high in [false, true] {
                        for nudge in [0, 0.004] {
                            for h in histories {
                                for dark in [false, true] {
                                    let label = MenuBarLabel(snapshot: snapshot(high, nudge: nudge), history: h, settings: s, ink: dark ? .white : .black, dark: dark)
                                    let key = label.renderKey(scale: 2), image = MenuBarRenderer.image(for: label, scale: 2)
                                    if let match = seen.first(where: { $0.0 == key }) {
                                        sharedKeys += 1
                                        #expect(
                                            same(match.1, image), "\(mode) \(kind.rawValue) \(style.rawValue): one key, two images (high \(high), nudge \(nudge), dark \(dark))")
                                    } else {
                                        seen.append((key, image))
                                    }
                                    compared += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(compared > 500)
        #expect(sharedKeys > 150)  // most samples share a key: the skip does its job
    }

    /// A text look keeps its key while the reading moves below what it shows ("CPU 16%" stays).
    @Test func aSubPercentChangeKeepsATextLooksKey() {
        let s = AppSettings(defaults: scratchDefaults("renderkey-text"))
        for k in MenuItemKind.allCases { s.setShown(k, k == .cpu) }
        s.setStyle(.cpu, .text)
        let a = MenuBarLabel(snapshot: snapshot(false), history: MetricHistory(), settings: s).renderKey(scale: 2)
        let b = MenuBarLabel(snapshot: snapshot(false, nudge: 0.0004), history: MetricHistory(), settings: s).renderKey(scale: 2)
        #expect(a == b)
        s.setStyle(.cpu, .bar)  // the bar draws the unrounded load
        let c = MenuBarLabel(snapshot: snapshot(false), history: MetricHistory(), settings: s).renderKey(scale: 2)
        let d = MenuBarLabel(snapshot: snapshot(false, nudge: 0.0004), history: MetricHistory(), settings: s).renderKey(scale: 2)
        #expect(c != d)
    }

    /// Inputs outside the snapshot: the screen's scale, the menu bar's mode, the icon, spacing,
    /// labels, units, warnings and colour mode each change the key.
    @Test func everyAppearanceInputChangesTheKey() {
        let s = AppSettings(defaults: scratchDefaults("renderkey-look"))
        for k in MenuItemKind.allCases { s.setShown(k, k == .cpu || k == .temperature || k == .network) }
        s.setStyle(.cpu, .text)
        func key(dark: Bool = false, scale: CGFloat = 2, high: Bool = true) -> MenuBarLabel.RenderKey {
            MenuBarLabel(snapshot: snapshot(high), history: MetricHistory(), settings: s, ink: dark ? .white : .black, dark: dark).renderKey(scale: scale)
        }
        let base = key()
        #expect(key(scale: 1) != base)
        #expect(key(dark: true) != base)
        let changes: [(String, () -> Void, () -> Void)] = [
            ("icon", { s.showIcon.toggle() }, { s.showIcon.toggle() }),
            ("spacing", { s.spacing = .wide }, { s.spacing = .regular }),
            ("label", { s.setLabel(.cpu, false) }, { s.setLabel(.cpu, true) }),
            ("unit", { s.temperatureUnit = .fahrenheit }, { s.temperatureUnit = .celsius }),
            ("bits", { s.networkInBits.toggle() }, { s.networkInBits.toggle() }),
            ("colour", { s.colourMode = .metric }, { s.colourMode = .monochrome }),
            ("look", { s.setStyle(.cpu, .gauge) }, { s.setStyle(.cpu, .text) }),
        ]
        for (name, change, undo) in changes {
            let before = key()
            change()
            #expect(key() != before, "\(name)")
            undo()
            #expect(key() == before, "\(name) undone")
        }
        // A warning turns the value red: the same text, warned or not, is a different key.
        s.warnRed = true
        var hotSnapshot = snapshot(true)
        hotSnapshot.sensors[0].celsius = 99
        let hot = MenuBarLabel(snapshot: hotSnapshot, history: MetricHistory(), settings: s).renderKey(scale: 2)
        s.warnRed = false
        #expect(MenuBarLabel(snapshot: hotSnapshot, history: MetricHistory(), settings: s).renderKey(scale: 2) != hot)
    }
}

/// Class: a view per data point. The CPU bars draw in one Canvas and never more bars than pixels.
@Suite struct UserSystemBarsDownsampleTests {
    @Test func neverMoreBarsThanPixels() {
        let stacks = (0..<600).map { (user: Double($0) / 600, system: 0.0) }
        let (kept, slots) = UserSystemBars.downsampled(stacks, slots: 600, pixels: 100)
        #expect(slots == 100 && kept.count == 100)
        #expect(kept.last?.user == stacks.last?.user)  // the newest bar stays at the right edge
        let few = UserSystemBars.downsampled(Array(stacks.prefix(60)), slots: 60, pixels: 576)
        #expect(few.slots == 60 && few.stacks.count == 60)  // fewer bars than pixels: untouched
    }
}
