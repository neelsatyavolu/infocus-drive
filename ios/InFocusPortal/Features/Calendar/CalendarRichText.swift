import SwiftUI

/// Formatted Master Calendar notes shown the way the Portal shows them: bold, italics, underline,
/// lists, line breaks and package pills (in green). Display only; the stored HTML is never rebuilt
/// from this.
enum CalendarRichText {
    private static let tagPattern = #/<(\/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>/#

    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        var bold = 0, italic = 0, underline = 0
        var spans: [Bool] = [] // true for a package pill
        var lists: [(ordered: Bool, count: Int)] = []
        var cursor = html.startIndex

        func append(_ raw: Substring) {
            var text = DayContent.decodeEntities(String(raw)).replacing(#/\s+/#, with: " ")
            if result.characters.isEmpty || result.characters.last == "\n" {
                text = String(text.drop { $0 == " " })
            }
            guard !text.isEmpty else { return }
            var run = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if underline > 0 { run.swiftUI.underlineStyle = .single }
            if spans.contains(true) { run.swiftUI.foregroundColor = Brand.green }
            result += run
        }
        func newline() {
            if !result.characters.isEmpty, result.characters.last != "\n" { result += AttributedString("\n") }
        }

        for match in html.matches(of: tagPattern) {
            append(html[cursor..<match.range.lowerBound])
            cursor = match.range.upperBound
            let close = !match.output.1.isEmpty
            let step = close ? -1 : 1
            switch match.output.2.lowercased() {
            case "strong", "b": bold = max(0, bold + step)
            case "em", "i": italic = max(0, italic + step)
            case "u": underline = max(0, underline + step)
            case "span":
                if close { _ = spans.popLast() } else { spans.append(match.output.3.contains("package-pill")) }
            case "br": result += AttributedString("\n")
            case "p", "div": newline()
            case "ul", "ol":
                newline()
                if close { _ = lists.popLast() } else { lists.append((match.output.2.lowercased() == "ol", 0)) }
            case "li":
                newline()
                if !close, !lists.isEmpty {
                    lists[lists.count - 1].count += 1
                    let list = lists[lists.count - 1]
                    let indent = String(repeating: "  ", count: lists.count - 1)
                    result += AttributedString(indent + (list.ordered ? "\(list.count). " : "• "))
                }
            default: break
            }
        }
        append(html[cursor...])
        while result.characters.last == "\n" { result.characters.removeLast() }
        return result
    }
}
