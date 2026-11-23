import AppKit
import HeronCore
import SwiftUI
import Testing

@testable import HeronUI

@Suite struct ProviderMarksTests {
    /// Every mark parses (the shared SVG parser returns nil on anything it cannot read) and fills
    /// most of its 24×24 square, so none draws as nothing or as a dot.
    @Test(arguments: AIProvider.allCases)
    func everyMarkParsesAndFillsItsSquare(_ p: AIProvider) throws {
        let path = try #require(SVGPath.parse(ProviderMark.data(p)))
        let box = path.boundingBoxOfPath
        #expect(box.width > 18 && box.height > 18 && box.maxX <= 24.01 && box.maxY <= 24.01)
    }

    @Test func onlyClaudeKeepsItsBrandColour() {
        #expect(ProviderMark.tint(.claude) != nil)
        #expect(ProviderMark.tint(.codex) == nil && ProviderMark.tint(.opencode) == nil)
    }

    @Test func theMenuBarImageIsATemplateNamedForItsProvider() {
        let image = ProviderMark.templateImage(.codex, size: 13)
        #expect(image.isTemplate && image.accessibilityDescription == "ChatGPT")
    }
}
