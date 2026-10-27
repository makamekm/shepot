import Foundation
import NaturalLanguage

public enum ListFormatting {
    /// Local fallback preserves every phrase. Meaning-based grouping belongs to the AI editor.
    public static func fallback(_ text: String) -> String {
        if let items = explicitItems(text), items.count > 1 { return render(items) }

        // Keep spoken enumeration cues in the text, using them only as boundaries.
        let separated = text.replacingOccurrences(
            of: "(?i)(?<![\\p{L}])(?=во[- ]первых\\b|во[- ]вторых\\b|в[- ]третьих\\b|в[- ]четв[её]ртых\\b|в[- ]пятых\\b|следующий пункт\\b|ещ[её] один пункт\\b)",
            with: "\n", options: .regularExpression
        ).replacingOccurrences(of: "[ \\t]+•[ \\t]+", with: "\n• ", options: .regularExpression)

        let tokenizer = NLTokenizer(unit: .sentence)
        var items: [String] = []
        for line in separated.components(separatedBy: .newlines) {
            let body = strippingMarker(line)
            guard !body.isEmpty else { continue }
            tokenizer.string = body
            tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
                // A semicolon is an explicit boundary even when the recognizer omitted full stops.
                items.append(contentsOf: body[range].split(separator: ";").map(String.init))
                return true
            }
        }
        return render(items)
    }

    /// Keep the AI's semantic groups, including explanations of several sentences in one item.
    /// If it returned one prose block, still apply the local list fallback.
    public static func normalizeEdited(_ text: String) -> String {
        if let items = explicitItems(text), items.count > 1 { return render(items) }
        return fallback(text)
    }

    private static func explicitItems(_ text: String) -> [String]? {
        var items: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.range(of: markerPattern, options: .regularExpression) != nil {
                items.append(strippingMarker(line))
            } else {
                guard !items.isEmpty else { return nil }
                items[items.count - 1] += " " + line
            }
        }
        return items.isEmpty ? nil : items
    }

    private static let markerPattern = "^(?:[•*▪◦‣-]|[0-9]{1,3}[.)])[ \\t]+"
    private static func strippingMarker(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ items: [String]) -> String {
        items.compactMap { item -> String? in
            var body = strippingMarker(item)
            guard let first = body.first else { return nil }
            body = String(first).uppercased() + body.dropFirst()
            if let last = body.last, last.isLetter || last.isNumber { body += "." }
            return "• " + body
        }.joined(separator: "\n")
    }
}
