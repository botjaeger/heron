import Foundation
import Testing

/// A sheet whose content is wrapped in `if let`/`if` can come up empty: AppKit attaches a 0×0 sheet
/// that blocks its window with nothing to dismiss (Settings › AI Usage › "Add account…", found by the
/// maintainer 2026-11-22; the smoke run measured 0 × 0). A sheet's content always draws something.
@Suite struct SheetContentGuardTests {
    @Test func noSheetContentIsConditional() {
        var offenders: [String] = []
        for target in ["HeronUI", "Heron"] {
            for file in sourceFiles(target) {
                let lines = file.text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains(".sheet(") {
                    // The content is the first statement of the closure: on this line after the "{", or the next line.
                    let rest = (line.components(separatedBy: "{").last.map { line.contains("{") ? $0 : "" } ?? "")
                        .replacingOccurrences(of: #"^[^}]*\bin\b"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    let first = rest.isEmpty ? (i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : "") : rest
                    if first.hasPrefix("if ") || first.hasPrefix("if let") { offenders.append("\(file.name):\(i + 1)") }
                }
            }
        }
        #expect(offenders.isEmpty, "conditional sheet content (can attach an empty sheet): \(offenders)")
    }
}
