import CoreGraphics
import Foundation
import HeronCore
import Observation
import SwiftUI

/// When a hover panel opens, switches and closes, as a pure state machine on a clock the caller
/// passes in (seconds, any origin), so tests can drive it with a fake one. The prototype's timing:
/// a panel opens after the pointer rests 120 ms on a card, waits 250 ms before switching to
/// another card (the pointer may only be crossing it), and closes 300 ms after the pointer has
/// left the popover and the panel.
public struct HoverIntent<Key: Hashable>: Equatable {
    public static var openDelay: TimeInterval { 0.12 }
    public static var switchDelay: TimeInterval { 0.25 }
    public static var closeDelay: TimeInterval { 0.3 }

    /// Where the pointer is. A card wins over the popover around it.
    public enum Region: Equatable { case card(Key), popover, panel, outside }

    public private(set) var open: Key?
    /// The card that opens at `pending.at`, and when the panel closes.
    public private(set) var pending: (key: Key, at: TimeInterval)?
    public private(set) var closeAt: TimeInterval?
    public private(set) var region: Region = .outside

    private var card: Key?
    private var inPopover = false
    private var inPanel = false

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.open == b.open && a.pending?.key == b.pending?.key && a.pending?.at == b.pending?.at && a.closeAt == b.closeAt && a.region == b.region
    }

    /// The pointer is over `key`'s card, or over no card (nil).
    public mutating func pointer(onCard key: Key?, now: TimeInterval) { card = key; update(now) }
    public mutating func pointer(inPopover inside: Bool, now: TimeInterval) { inPopover = inside; update(now) }
    public mutating func pointer(inPanel inside: Bool, now: TimeInterval) { inPanel = inside; update(now) }

    /// Click or keyboard: open now, no delay.
    public mutating func open(_ key: Key) { open = key; pending = nil; closeAt = nil }

    /// Esc, or the popover closed.
    public mutating func close() { open = nil; pending = nil; closeAt = nil }

    /// The next moment `advance` has something to do.
    public var deadline: TimeInterval? { [pending?.at, closeAt].compactMap { $0 }.min() }

    /// Fires what is due. Returns true when `open` changed.
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> Bool {
        let before = open
        if let p = pending, now >= p.at { open = p.key; pending = nil; closeAt = nil }
        if let c = closeAt, now >= c { open = nil; closeAt = nil }
        return before != open
    }

    private mutating func update(_ now: TimeInterval) {
        let next: Region = if let card { .card(card) } else if inPopover { .popover } else if inPanel { .panel } else { .outside }
        guard next != region else { return }
        region = next
        switch next {
        case .card(let key):
            closeAt = nil
            if open == key { pending = nil } else { pending = (key, now + (open == nil ? Self.openDelay : Self.switchDelay)) }
        case .popover, .panel:
            // Between cards or on the panel: nothing new opens, nothing closes.
            pending = nil; closeAt = nil
        case .outside:
            pending = nil
            closeAt = open == nil ? nil : now + Self.closeDelay
        }
    }
}

/// Where a hover panel goes: beside the popover on the side with room (left first), its top
/// `headerOffset` above the hovered card's top so its first card lines up with it, kept inside
/// the screen's visible frame. AppKit screen coordinates (y up).
public enum PanelPlacement {
    public enum Side: Equatable, Sendable { case left, right }
    public static let gap: CGFloat = 8
    public static let headerOffset: CGFloat = 50

    public static func side(width: CGFloat, popover: CGRect, visible: CGRect) -> Side {
        let left = popover.minX - gap - visible.minX, right = visible.maxX - (popover.maxX + gap)
        if left >= width { return .left }
        if right >= width { return .right }
        return left >= right ? .left : .right
    }

    public static func frame(size: CGSize, popover: CGRect, card: CGRect?, visible: CGRect) -> (frame: CGRect, side: Side) {
        let side = side(width: size.width, popover: popover, visible: visible)
        var x = side == .left ? popover.minX - gap - size.width : popover.maxX + gap
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let top = (card?.maxY ?? popover.maxY) + headerOffset
        // The top stays on screen when the panel is taller than the screen.
        let y = min(max(top - size.height, visible.minY), visible.maxY - size.height)
        return (CGRect(x: x, y: y, width: size.width, height: size.height), side)
    }

    /// How far a history's top sits above its row's top, so its title lines up with the row.
    public static let historyOffset: CGFloat = 30

    /// Where a row's history goes: beside the panel, further from the popover (the way submenus
    /// cascade); on the popover's other side when that runs off the screen; its top
    /// `historyOffset` above the row's.
    public static func historyFrame(size: CGSize, panel: CGRect, popover: CGRect, row: CGRect?, side: Side, visible: CGRect) -> CGRect {
        let outward = side == .left ? panel.minX - gap - size.width : panel.maxX + gap
        let fits = side == .left ? outward >= visible.minX : outward + size.width <= visible.maxX
        var x = fits ? outward : (side == .left ? popover.maxX + gap : popover.minX - gap - size.width)
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let top = (row?.maxY ?? panel.maxY) + historyOffset
        let y = min(max(top - size.height, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// A row in a panel whose number Heron keeps a history of: clicking it shows that history.
public struct HistoryItem: Hashable, Sendable {
    /// How its numbers read: `rate` is disk throughput, `networkRate` follows the network Units setting (bits or bytes).
    /// `number` is a load average ("3.51"), `count` a whole number (cycles).
    public enum Unit: Hashable, Sendable { case percent, watts, bytes, rate, networkRate, temperature, rpm, number, count }
    public var part: OverviewPart
    public var source: HistorySource
    public var title: String
    public var unit: Unit
    public var color: Color

    public init(part: OverviewPart, source: HistorySource, title: String, unit: Unit, color: Color) {
        self.part = part; self.source = source; self.title = title; self.unit = unit; self.color = color
    }

    public init(part: OverviewPart, metric: Metric, title: String, unit: Unit, color: Color) {
        self.init(part: part, source: .metric(metric), title: title, unit: unit, color: color)
    }
}

/// A key the overview handles while the popover is key.
public enum PanelKey: Sendable { case up, down, left, right, enter, escape }

/// The hover panels' state, shared by the popover (cards report the pointer, draw their ›) and the
/// app (which shows the panel window). The app sets the clock, the visible parts and `onChange`.
@MainActor
@Observable
public final class DetailPanels {
    /// The card whose panel is shown.
    public private(set) var open: OverviewPart? { didSet { if open != oldValue { changed() } } }
    /// The card the keyboard is on (drawn with a focus ring).
    public private(set) var focused: OverviewPart?
    /// The row whose history is shown in its own panel beside the open one, like a submenu: it
    /// opens when the pointer rests on the row (or on a click), and never replaces the details,
    /// so the panel under the pointer never changes size or moves away from it.
    public private(set) var history: HistoryItem? { didSet { if history != oldValue { historyHover = nil; changed() } } }
    /// Where the pointer is across the history chart (0 left, 1 right), for its crosshair readout;
    /// nil when it is not on the chart. Redraws the chart only (the panel's size never changes).
    public var historyHover: Double?
    public var historyRange: AppSettings.GraphRange = .tenMinutes { didSet { if historyRange != oldValue { changed() } } }
    /// The side the panel opens on: the arrow pointing there opens it, the other one closes it.
    public var side: PanelPlacement.Side = .left

    /// The tallest the popover and a panel may be (`PopoverView.page`); nil draws them at full height.
    /// The app sets them from the menu bar's screen before the popover opens.
    public var popoverMaxHeight: CGFloat?
    public var panelMaxHeight: CGFloat?

    /// Card frames in the popover's `PopoverRoot.space` (the hosting view, y down from its top).
    @ObservationIgnored public private(set) var cardFrames: [OverviewPart: CGRect] = [:]
    /// The scrolling cards' visible area in `PopoverRoot.space`; nil when the overview does not
    /// scroll. A card scrolled under the header or footer is not under the pointer.
    @ObservationIgnored public private(set) var viewport: CGRect?
    /// History rows' frames in the open panel's `DetailPanels.space` (its hosting view, y down).
    @ObservationIgnored public private(set) var historyFrames: [HistoryItem: CGRect] = [:]
    /// The panel's coordinate space: its hosting view, y down from its top.
    public static let space = "heron.panel"
    @ObservationIgnored public var visibleParts: () -> [OverviewPart] = { OverviewPart.allCases }
    /// Called after `open`, `history` or the range changed.
    @ObservationIgnored public var onChange: () -> Void = {}
    @ObservationIgnored public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var intent = HoverIntent<OverviewPart>()
    /// The history's own hover state: a row is its "card", the panel its "popover", the history
    /// its "panel". The overview counts as inside too, so the history waits there like the panel.
    @ObservationIgnored private var historyIntent = HoverIntent<HistoryItem>()
    @ObservationIgnored private var inOverview = false
    @ObservationIgnored private var inPanel = false
    @ObservationIgnored private var inHistory = false
    @ObservationIgnored private var historyRow: HistoryItem?
    @ObservationIgnored private var timer: Timer?

    public init() {}

    /// The overview's cards, top to bottom (what ↑ and ↓ walk through). `ai`: whether an AI
    /// account exists (`!AIUsageService.accounts.isEmpty`); without one the AI card is left out.
    public static func visibleParts(order: [OverviewPart], hidden: Set<OverviewPart>, snapshot: Snapshot, ai: Bool = false) -> [OverviewPart] {
        OverviewSection.parts(order: order, hidden: hidden, snapshot: snapshot, ai: ai)
    }

    private func changed() { onChange() }

    func reportFrame(_ part: OverviewPart, _ rect: CGRect) { cardFrames[part] = rect }
    func reportHistoryFrame(_ item: HistoryItem, _ rect: CGRect) { historyFrames[item] = rect }
    func reportViewport(_ rect: CGRect) { viewport = rect }

    /// The pointer moved inside the popover (`PopoverRoot.space`), or left it (nil).
    public func pointerInPopover(_ point: CGPoint?) {
        let now = clock()
        let card = point.flatMap { p in
            viewport.map { $0.contains(p) } ?? true ? visibleParts().first { cardFrames[$0]?.contains(p) == true } : nil
        }
        intent.pointer(onCard: card, now: now)
        intent.pointer(inPopover: point != nil, now: now)
        inOverview = point != nil
        historyIntent.pointer(inPopover: inOverview || inPanel, now: now)
        sync()
    }

    /// The pointer entered or left the open panel.
    public func pointerInPanel(_ inside: Bool) {
        inPanel = inside
        if !inside { historyRow = nil }  // a row it left with the panel sends no "exited" of its own
        pointerMoved()
    }

    /// The pointer entered or left the history beside the panel: for the panel's hover state it
    /// is still on the panel (moving onto the history never closes it).
    public func pointerInHistory(_ inside: Bool) {
        inHistory = inside
        pointerMoved()
    }

    /// The pointer entered (`inside`) or left a history row of the open panel. A row's "left" can
    /// arrive after the next row's "entered", so it clears only its own row.
    public func pointerOnHistoryRow(_ item: HistoryItem, inside: Bool) {
        if inside { historyRow = item } else if historyRow == item { historyRow = nil } else { return }
        pointerMoved()
    }

    private func pointerMoved() {
        let now = clock()
        intent.pointer(inPanel: inPanel || inHistory, now: now)
        historyIntent.pointer(onCard: historyRow, now: now)
        historyIntent.pointer(inPopover: inOverview || inPanel, now: now)
        historyIntent.pointer(inPanel: inHistory, now: now)
        sync()
    }

    /// Click, keyboard or VoiceOver.
    public func openNow(_ part: OverviewPart) {
        intent.open(part)
        sync()
    }

    /// A row clicked (or chosen with VoiceOver): its history opens now, no delay.
    public func showHistory(_ item: HistoryItem) {
        historyIntent.open(item)
        sync()
    }

    public func closeHistory() {
        historyIntent.close()
        sync()
    }

    /// The popover closed: everything goes, where the pointer was too (a card it rested on when
    /// the popover closed would otherwise never open again until the pointer left it).
    public func closeAll() {
        intent = HoverIntent()
        historyIntent = HoverIntent()
        inOverview = false; inPanel = false; inHistory = false; historyRow = nil
        focused = nil
        sync()
    }

    /// Returns false when the key is not the overview's (Esc with no panel: the popover closes).
    public func handle(_ key: PanelKey) -> Bool {
        let parts = visibleParts()
        let toward: PanelKey = side == .left ? .left : .right, away: PanelKey = side == .left ? .right : .left
        switch key {
        case .up, .down:
            guard !parts.isEmpty else { return false }
            let step = key == .down ? 1 : -1
            if let f = focused, let i = parts.firstIndex(of: f) {
                focused = parts[min(max(i + step, 0), parts.count - 1)]
            } else {
                focused = key == .down ? parts.first : parts.last
            }
            if open != nil, let f = focused { openNow(f) }  // an open panel follows the focus
            return true
        case .enter, toward:
            guard let f = focused ?? parts.first else { return false }
            focused = f
            if open != f { openNow(f) }
            return true
        case .escape, away:
            if history != nil { closeHistory(); return true }
            if open != nil { intent.close(); sync(); return true }
            return false
        default:
            return false
        }
    }

    private func sync() {
        let now = clock()
        intent.advance(to: now)
        historyIntent.advance(to: now)
        if open != intent.open {
            // Another panel (or none): its history goes, the pointer's place stays.
            open = intent.open
            historyIntent = HoverIntent()
            historyRow = nil
            historyIntent.pointer(inPopover: inOverview || inPanel, now: now)
            historyIntent.pointer(inPanel: inHistory, now: now)
        }
        let shown = historyIntent.open.flatMap { $0.part == open ? $0 : nil }
        if history != shown { history = shown }
        timer?.invalidate(); timer = nil
        guard let deadline = [intent.deadline, historyIntent.deadline].compactMap({ $0 }).min() else { return }
        let t = Timer(timeInterval: max(0, deadline - clock()) + 0.001, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
