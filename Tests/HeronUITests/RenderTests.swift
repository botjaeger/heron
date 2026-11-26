import SwiftUI
import Testing

@testable import HeronCore
@testable import HeronUI

/// Offscreen renders (`MenuBarRenderer.bitmap`): `ImageRenderer.cgImage` hands back the previous
/// same-size render's pixels when the content draws nothing (macOS 27.2, 2026-11-26), which made a
/// menu bar item waiting for its readings show another item's bar, 1 test run in about 12.
@MainActor
@Suite struct RenderTests {
    func ink(_ image: CGImage?) -> Int {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        return UnsafeBufferPointer(start: bytes, count: CFDataGetLength(data)).filter { $0 > 8 }.count
    }

    func cpu(_ fraction: Double, waiting: Bool) -> Snapshot {
        var s = Snapshot()
        s.awaitingReadings = waiting
        s.cpu = CPUReading(user: fraction, system: 0, idle: 1 - fraction, cores: [], loadAverage: [])
        return s
    }

    /// Deterministic, without other suites: draw something, then render the same size drawing
    /// nothing. With `ImageRenderer.cgImage` the second came back with the first's pixels.
    @Test func aBlankRenderIsBlankAfterADrawnOne() {
        let settings = AppSettings(defaults: scratchDefaults("render"))
        let drawn = MenuBarSegment(kind: .cpu, style: .bar, snapshot: cpu(0.04, waiting: false), history: MetricHistory(), settings: settings)
        let waiting = MenuBarSegment(kind: .cpu, style: .bar, snapshot: cpu(0.04, waiting: true), history: MetricHistory(), settings: settings)
        #expect(ink(MenuBarRenderer.bitmap(drawn, scale: 2)) > 0)
        #expect(ink(MenuBarRenderer.bitmap(waiting, scale: 2)) == 0, "the waiting item shows the last item drawn")
        let text = Text("CPU 4%").font(.system(size: 12)).frame(width: 70, height: 20)
        #expect(ink(MenuBarRenderer.bitmap(text, scale: 2)) > 0)
        #expect(ink(MenuBarRenderer.bitmap(text.opacity(0), scale: 2)) == 0)
        #expect(ink(MenuBarRenderer.bitmap(Color.clear.frame(width: 70, height: 20), scale: 2)) == 0)
    }

    /// A render keeps its size and its pixels: same width and height as `ImageRenderer`'s, and a
    /// second render of the same view is byte for byte the first.
    @Test func aRenderIsTheViewAtItsSize() {
        let view = Text("CPU 83%").font(.system(size: 12, weight: .bold)).foregroundStyle(.black).frame(width: 70, height: 18)
        let a = MenuBarRenderer.bitmap(view, scale: 2), b = MenuBarRenderer.bitmap(view, scale: 2)
        #expect(a?.width == 140 && a?.height == 36)
        #expect(a?.dataProvider?.data == b?.dataProvider?.data)
        #expect(ink(a) > 0)
    }

    /// The class: every offscreen render goes through `MenuBarRenderer.bitmap`.
    @Test func noOtherOffscreenRenders() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let tests = try FileManager.default.contentsOfDirectory(atPath: here.path).filter { $0.hasSuffix(".swift") }.map { name in
            (name: name, text: try String(contentsOf: here.appendingPathComponent(name), encoding: .utf8))
        }
        let files = ["Heron", "HeronUI", "heron-snap"].flatMap(sourceFiles) + tests
        #expect(!files.isEmpty)
        for file in files where file.name != "RenderTests.swift" {
            for line in file.text.split(separator: "\n") where line.contains(".cgImage") && !line.contains("cgImage(forProposedRect") {
                #expect(line.trimmingCharacters(in: .whitespaces).hasPrefix("///"), "\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
