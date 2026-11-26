import Foundation

/// A newer Heron the update feed offers: what the update window, Settings › Updates and the
/// "update waiting" marks show.
public struct UpdateOffer: Equatable, Sendable {
    public var version: String
    /// The disk image's size in bytes, when the feed gives it.
    public var size: UInt64?
    public var date: Date?
    public var notes: [ReleaseNotes.Group]
    /// Found by the daily check with "Install updates automatically" on: it downloads and installs
    /// on its own, so nothing marks it as waiting.
    public var automatic: Bool

    public init(version: String, size: UInt64? = nil, date: Date? = nil, notes: [ReleaseNotes.Group] = [], automatic: Bool = false) {
        self.version = version; self.size = size; self.date = date; self.notes = notes; self.automatic = automatic
    }
}

/// Where an update stands. The app's update driver (`HeronUserDriver`) moves it; every surface
/// reads it from `AppServices.update`, so the icon dot, the popover strip, the menu item, the
/// update window and Settings › Updates never disagree.
public enum UpdateState: Equatable, Sendable {
    /// Nothing found, or nothing looked for yet.
    case idle
    /// A check you asked for is running.
    case checking
    /// A newer version is waiting for you to choose.
    case available(UpdateOffer)
    /// Downloading: bytes so far, and the total once the server says.
    case downloading(UpdateOffer, received: UInt64, expected: UInt64?)
    /// Downloaded; unpacking and checking its signature.
    case preparing(UpdateOffer)
    /// Ready: installs when Heron quits, or now with Restart Heron Now.
    case ready(UpdateOffer)
    /// Installing; Heron is about to quit and reopen.
    case installing(UpdateOffer)
    /// The last check you asked for failed.
    case failed(String)

    public var offer: UpdateOffer? {
        switch self {
        case .available(let o), .downloading(let o, _, _), .preparing(let o), .ready(let o), .installing(let o): o
        case .idle, .checking, .failed: nil
        }
    }

    /// The version that waits for you: what the icon dot, the popover strip and the menu item
    /// show. Nil when nothing waits, and for an update that installs itself ("Install updates
    /// automatically"): that one needs nothing from you.
    public var waiting: UpdateOffer? {
        guard let offer, !offer.automatic else { return nil }
        if case .installing = self { return nil }
        return offer
    }

    /// The right-click menu's update item.
    public var menuTitle: String {
        if let waiting { return "Update to Heron \(waiting.version)…" }
        return "Check for Updates…"
    }

    /// The download's progress, 0…1; nil while the size is unknown or nothing downloads.
    public var progress: Double? {
        guard case .downloading(_, let received, let expected?) = self, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    /// Settings › Updates' status line for this state; nil when the check status (up to date, last
    /// checked) shows instead.
    public var statusLine: String? {
        switch self {
        case .idle: nil
        case .checking: "Checking for updates…"
        case .available(let o): "Heron \(o.version) is available" + (o.size.map { " · \(Self.megabytes($0))" } ?? "")
        case .downloading(let o, let received, let expected):
            "Downloading Heron \(o.version) · " + (expected.map { "\(Self.megabytes(received, of: $0)) of \(Self.megabytes($0))" } ?? Self.megabytes(received))
        case .preparing(let o): "Preparing Heron \(o.version)…"
        case .ready(let o): "Heron \(o.version) is ready · installs when you quit Heron"
        case .installing(let o): "Installing Heron \(o.version)…"
        case .failed(let why): "Couldn’t check for updates: \(why)"
        }
    }

    /// "4.5 MB": one decimal, in the feed's own units (Sparkle sizes are bytes; macOS counts
    /// 1 MB as 1,000,000 bytes).
    static func megabytes(_ bytes: UInt64, of total: UInt64? = nil) -> String {
        let mb = Double(bytes) / 1_000_000
        let text = String(format: "%.1f", mb)
        return total == nil ? "\(text) MB" : text
    }
}
