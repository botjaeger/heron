import Foundation

/// The notes an update carries in its appcast entry. `scripts/release.sh` writes them from
/// `Changelog.entries` with `Heron changelog --notes <version>`; the update window of the copy
/// being updated reads them back, since that copy has never seen the new version's entry. One
/// heading per group, one item per change, its glyph in `data-icon`:
///
///     <h3>NEW</h3>
///     <ul>
///     <li data-icon="chart"><b>History for any row</b> Click a row with a chart mark…</li>
///     </ul>
public enum ReleaseNotes {
    public struct Item: Equatable, Sendable {
        public var icon: HeronIcon?
        public var title: String
        public var body: String
    }

    public struct Group: Equatable, Sendable {
        public var title: String
        public var items: [Item]
    }

    /// The notes of `version`'s `Changelog.entries` entry; nil when it has none.
    public static func html(for version: String) -> String? {
        Changelog.entries.first { $0.version == version }.map(html)
    }

    static func html(_ entry: ChangelogEntry) -> String {
        entry.groups.map { group in
            let items = group.items.map { "<li data-icon=\"\($0.icon.rawValue)\"><b>\(escape($0.title))</b> \(escape($0.body))</li>" }
            return (["<h3>\(escape(group.title))</h3>", "<ul>"] + items + ["</ul>"]).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// The groups in notes written by `html`, in order. Anything else in the HTML is ignored, and an
    /// unknown glyph name reads as no glyph (a newer Heron may add glyphs this copy lacks).
    public static func parse(_ html: String) -> [Group] {
        var groups: [Group] = []
        let heading = /<h3>(.*?)<\/h3>/
        let item = /<li data-icon="([A-Za-z]*)"><b>(.*?)<\/b> (.*?)<\/li>/
        for line in html.split(whereSeparator: \.isNewline) {
            if let m = line.firstMatch(of: heading) {
                groups.append(Group(title: unescape(String(m.1)), items: []))
            } else if let m = line.firstMatch(of: item), !groups.isEmpty {
                groups[groups.count - 1].items.append(Item(icon: HeronIcon(rawValue: String(m.1)), title: unescape(String(m.2)), body: unescape(String(m.3))))
            }
        }
        return groups.filter { !$0.items.isEmpty }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
