import CoreGraphics
import Foundation
import Testing

@testable import HeronCore
@testable import HeronUI

/// The icon set: one home for the design's 24-unit path data.
@Suite struct IconGeometryTests {
    @Test func everyIconParsesAndStaysInsideItsBox() {
        for icon in HeronIcon.allCases {
            for case .path(let d) in icon.elements { #expect(SVGPath.parse(d) != nil, "\(icon): cannot parse \(d)") }
            let b = icon.path.boundingBoxOfPath
            #expect(!b.isNull && b.width > 0 && b.height > 0, "\(icon) is empty")
            #expect(b.minX >= 0 && b.minY >= 0 && b.maxX <= HeronIcon.gridSize && b.maxY <= HeronIcon.gridSize, "\(icon): \(b)")
        }
    }

    /// The thermometer's arcs: a 2-unit cap on top (centre 12,5) and a 4-unit bulb whose chord is
    /// 2 below its centre, so the outline spans x 8...16 and y 3...(14.5 + √12 + 4).
    @Test func arcsLandWhereTheSVGPutsThem() {
        let b = HeronIcon.sensors.path.boundingBoxOfPath
        let bottom = 14.5 + 12.0.squareRoot() + 4
        #expect(abs(b.minX - 8) < 0.05 && abs(b.maxX - 16) < 0.05, "\(b)")
        #expect(abs(b.minY - 3) < 0.05 && abs(b.maxY - bottom) < 0.05, "\(b)")
    }

    @Test func packedNumbersAndImplicitLinesParse() {
        // "-4.3.5" is -4.3 then .5; pairs after M are lines.
        let p = SVGPath.parse("M0 0l-4.3.5M8 5 4.5 8.5")
        #expect(p != nil)
        #expect(abs((p?.boundingBoxOfPath.minX ?? 0) + 4.3) < 1e-6)
        #expect(SVGPath.parse("M0 0Q1 1 2 2") == nil)  // a command the icons don't use
    }

    @Test func everySectionHasItsOwnIcon() {
        let icons = OverviewPart.allCases.map(\.icon)
        #expect(Set(icons).count == OverviewPart.allCases.count)
        for part in OverviewPart.allCases { #expect(!part.icon.path.isEmpty, "\(part)") }
    }
}

/// The popover is the overview: Settings › Overview order, hidden sections left out.
@Suite struct OverviewOrderTests {
    func settings() -> AppSettings { AppSettings(defaults: scratchDefaults("overview")) }
    func snapshot(battery: Bool) -> Snapshot {
        var s = Snapshot()
        s.battery = BatteryReading(present: battery, percent: 0.5, isCharging: false, onAC: true)
        return s
    }

    @Test func sectionsFollowTheOrderAndSkipHiddenOnes() {
        let s = settings()
        #expect(OverviewSection.parts(order: s.overviewOrder, hidden: s.hiddenSections, snapshot: snapshot(battery: true), ai: true) == OverviewPart.allCases)
        s.setOverviewOrder([.sensors, .battery, .memory])
        s.setHidden(.gpu, true)
        s.setHidden(.network, true)
        #expect(
            OverviewSection.parts(order: s.overviewOrder, hidden: s.hiddenSections, snapshot: snapshot(battery: true))
                == [.sensors, .battery, .memory, .cpu, .disk])
    }

    @Test func batteryShowsOnlyOnAMacWithOne() {
        let s = settings()
        #expect(!OverviewSection.parts(order: s.overviewOrder, hidden: [], snapshot: snapshot(battery: false)).contains(.battery))
        #expect(!OverviewSection.parts(order: s.overviewOrder, hidden: [], snapshot: Snapshot()).contains(.battery))
    }
}

@Suite struct StatusPillTests {
    func snapshot(cpu: Double, pressure: MemoryReading.Pressure) -> Snapshot {
        var s = Snapshot()
        s.sensors = [
            Sensor(id: "a", name: "CPU 1", group: .cpuPerformance, celsius: cpu, isKnown: true),
            Sensor(id: "b", name: "CPU 2", group: .cpuEfficiency, celsius: cpu, isKnown: true),
        ]
        s.memory = MemoryReading(total: 1, app: 0, wired: 0, compressed: 0, cached: 0, free: 1, swapUsed: 0, pressure: pressure)
        return s
    }

    @Test func aHotCPUComesFirstThenMemoryPressure() {
        #expect(StatusPill.state(snapshot(cpu: 70, pressure: .normal)) == ("All normal", .normal, 0))
        #expect(StatusPill.state(snapshot(cpu: 70, pressure: .warning)) == ("Memory pressure high", .caution, 0))
        #expect(StatusPill.state(snapshot(cpu: 70, pressure: .critical)) == ("Memory pressure critical", .alarm, 0))
        #expect(StatusPill.state(snapshot(cpu: 89.4, pressure: .normal)).text == "All normal")
        // Several issues: the most serious first, "+N" for the rest.
        #expect(StatusPill.state(snapshot(cpu: 90, pressure: .critical)) == ("CPU running hot", .alarm, 1))
        #expect(StatusPill.state(snapshot(cpu: 90, pressure: .warning)) == ("CPU running hot", .alarm, 1))
        #expect(StatusPill.state(Snapshot()) == ("All normal", .normal, 0))
    }

    /// One hot sensor whose component average is normal: the pill names that sensor, never the
    /// component, so it agrees with the component's card.
    @Test func aSingleHotSensorIsNamedNotItsComponent() {
        var s = snapshot(cpu: 70, pressure: .normal)
        s.sensors.append(Sensor(id: "c", name: "CPU 25", group: .cpuPerformance, celsius: 96, isKnown: true))
        #expect(SensorSummary.value(.cpu, in: s).map(Warnings.isHot) == false)
        #expect(StatusPill.state(s) == ("CPU 25 running hot", .alarm, 0))
    }

    @Test func anAlarmOutranksACautionListedBeforeIt() {
        var s = snapshot(cpu: 70, pressure: .warning)
        s.battery = BatteryReading(present: true, percent: 0.1, isCharging: false, onAC: false)
        #expect(StatusPill.issues(s).map(\.text) == ["Battery low", "Memory pressure high"])
        #expect(StatusPill.state(s) == ("Battery low", .alarm, 1))
        s.battery?.onAC = true  // on the adapter a low charge is not an issue
        #expect(StatusPill.state(s) == ("Memory pressure high", .caution, 0))
    }
}

@Suite struct BatteryStatusTests {
    func battery(_ percent: Double, charging: Bool, ac: Bool, minutes: Int?, limit: Double?) -> BatteryReading {
        var b = BatteryReading(present: true, percent: percent, isCharging: charging, onAC: ac)
        b.minutesRemaining = minutes
        b.chargeLimit = limit
        return b
    }

    @Test func oneWordingWithAndWithoutAChargeLimit() {
        #expect(BatteryStatus.text(battery(0.27, charging: true, ac: true, minutes: 135, limit: nil)) == "Charging · 2h 15m to full")
        #expect(BatteryStatus.text(battery(0.27, charging: true, ac: true, minutes: 135, limit: 0.8)) == "Charging to 80% · 2h 15m")
        #expect(BatteryStatus.text(battery(0.8, charging: false, ac: true, minutes: nil, limit: 0.8)) == "Held at 80% limit")
        #expect(BatteryStatus.text(battery(0.9, charging: false, ac: false, minutes: 200, limit: 0.8)) == "On battery · 3h 20m left")
        #expect(BatteryStatus.text(battery(0.5, charging: false, ac: true, minutes: nil, limit: nil)) == "On power adapter")
    }
}

/// The overview's fan turns with the fans, continuously.
@Suite struct SpinPhaseTests {
    @Test func aNewSpeedChangesTheRateWithoutAJump() {
        let phase = SpinPhase()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(phase.advance(to: t0, rpm: 3000) == 0)
        let a = phase.advance(to: t0.addingTimeInterval(0.2), rpm: 3000)
        #expect(abs(a - 0.1) < 1e-6)  // 3,000 rpm = half a turn per second
        let b = phase.advance(to: t0.addingTimeInterval(0.3), rpm: 6000)
        #expect(abs(b - (a + 0.1)) < 1e-6)  // the new speed applies from here on
        let c = phase.advance(to: t0.addingTimeInterval(60.3), rpm: 6000)
        #expect(abs(c - (b + 0.5).truncatingRemainder(dividingBy: 1)) < 1e-6)  // a long gap is not caught up
    }
}

@Suite struct BigRingTests {
    @Test func segmentsFollowEachOtherAndNeverPassAFullTurn() {
        let s = BigRing.segments([0.3, 0.2, 0.7, -0.1])
        #expect(s.map(\.start) == [0, 0.3, 0.5, 1])
        #expect(s.map(\.end) == [0.3, 0.5, 1, 1])
    }
}
