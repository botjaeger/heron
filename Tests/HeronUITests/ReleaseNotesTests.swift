import Testing

@testable import HeronUI

/// The notes an update carries: written from Changelog.entries at release time, read back by an
/// older copy's update window.
@MainActor
@Suite struct ReleaseNotesTests {
    @Test func everyReleaseReadsBackAsWritten() throws {
        #expect(!Changelog.entries.isEmpty)
        for entry in Changelog.entries {
            let html = try #require(ReleaseNotes.html(for: entry.version))
            let groups = ReleaseNotes.parse(html)
            #expect(groups.map(\.title) == entry.groups.map(\.title), "\(entry.version)")
            for (read, written) in zip(groups, entry.groups) {
                #expect(read.items.map(\.title) == written.items.map(\.title))
                #expect(read.items.map(\.body) == written.items.map(\.body))
                #expect(read.items.map(\.icon) == written.items.map(\.icon))
            }
        }
    }

    @Test func aVersionWithoutAnEntryHasNoNotes() {
        #expect(ReleaseNotes.html(for: "0.0.0-none") == nil)
    }

    /// Text with HTML's own characters survives the trip, and cannot open a tag of its own.
    @Test func markupInTheTextIsEscaped() {
        let entry = ChangelogEntry(
            version: "9.9.9", date: "2026",
            groups: [("FIXED", [ChangelogItem("<i>Fix</i> & \"quotes\"", "a <script b > c &amp;", icon: .chart, color: Theme.cpu)])])
        let html = ReleaseNotes.html(entry)
        #expect(!html.contains("<i"), "a tag in the text stays text")
        #expect(!html.contains("<script"))
        let item = ReleaseNotes.parse(html).first?.items.first
        #expect(item?.title == "<i>Fix</i> & \"quotes\"")
        #expect(item?.body == "a <script b > c &amp;")
    }

    /// A newer release may name a glyph this copy does not have: the change still shows, without it.
    @Test func anUnknownGlyphReadsAsNone() {
        let groups = ReleaseNotes.parse("<h3>NEW</h3>\n<ul>\n<li data-icon=\"hologram\"><b>T</b> B</li>\n</ul>")
        #expect(groups == [ReleaseNotes.Group(title: "NEW", items: [ReleaseNotes.Item(icon: nil, title: "T", body: "B")])])
    }

    @Test func otherHTMLAndEmptyGroupsAreLeftOut() {
        let groups = ReleaseNotes.parse("<p>intro</p>\n<h3>EMPTY</h3>\n<h3>NEW</h3>\n<li data-icon=\"chart\"><b>T</b> B</li>\n<script>x</script>")
        #expect(groups.map(\.title) == ["NEW"])
    }
}
