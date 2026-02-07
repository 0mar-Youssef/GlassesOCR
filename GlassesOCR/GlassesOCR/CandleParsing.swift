import Foundation
import Vision

enum CandleParsing {
    static let tickerPattern = #"\b([A-Z]{1,8}(?:\.[A-Z]{1,2})?)\b"#
    static let pricePattern = #"\$?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,4})?|\d+(?:\.\d{1,4})?)"#
    static let timeframePattern = #"\b(1m|3m|5m|10m|15m|30m|45m|1h|2h|4h|6h|8h|12h|1d|3d|1w)\b"#
    static let timeLabelPattern = #"\b(?:[01]?\d|2[0-3]):[0-5]\d\b"#
    static let changePattern = #"([+\-−])\s*(\d+(?:\.\d{1,2})?)\s*%?"#

    static let financeStoplist: Set<String> = [
        "USD", "EUR", "GBP", "JPY",
        "NYSE", "NASDAQ", "DOW",
        "OPEN", "HIGH", "LOW", "CLOSE", "OHLC",
        "VOL", "VOLUME", "CHART", "TIME", "CANDLE", "INDICATOR"
    ]

    struct RegionText {
        let header: String
        let footer: String
        let leftAxis: String
        let rightAxis: String
    }

    static func splitIntoRegions(ocrResult: OcrResult) -> RegionText {
        guard !ocrResult.observations.isEmpty else {
            return RegionText(header: ocrResult.recognizedText, footer: "", leftAxis: "", rightAxis: "")
        }

        var header: [String] = []
        var footer: [String] = []
        var left: [String] = []
        var right: [String] = []

        for observation in ocrResult.observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let box = observation.boundingBox

            if box.midY > 0.78 {
                header.append(text)
            }
            if box.midY < 0.22 {
                footer.append(text)
            }
            if box.midX < 0.20 {
                left.append(text)
            }
            if box.midX > 0.80 {
                right.append(text)
            }
        }

        return RegionText(
            header: header.joined(separator: " "),
            footer: footer.joined(separator: " "),
            leftAxis: left.joined(separator: " "),
            rightAxis: right.joined(separator: " ")
        )
    }

    static func extractTickerCandidates(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: tickerPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).uppercased() }
        }
    }

    static func isTimeframeToken(_ token: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: timeframePattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(token.startIndex..., in: token)
        guard let match = regex.firstMatch(in: token, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    static func extractTimeframe(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: timeframePattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).lowercased()
    }

    static func extractTimeLabels(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let labels = regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range(at: 0), in: text).map { String(text[$0]) }
        }

        let unique = Array(Set(labels))
        return unique.sorted { lhs, rhs in
            let left = minutes(from: lhs)
            let right = minutes(from: rhs)
            return (left ?? 0) < (right ?? 0)
        }
    }

    static func extractPriceMatches(from text: String) -> [(value: Double, range: NSRange)] {
        guard let regex = try? NSRegularExpression(pattern: pricePattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var matches: [(Double, NSRange)] = []

        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let cleaned = String(text[matchRange]).replacingOccurrences(of: ",", with: "")
            if let value = Double(cleaned), value > 0, value < 10_000_000 {
                matches.append((value, match.range(at: 1)))
            }
        }

        return matches
    }

    static func extractFilteredPrices(from text: String) -> [Double] {
        return extractFilteredPriceMatches(from: text).map(\.value)
    }

    static func extractFilteredPriceMatches(from text: String) -> [(value: Double, range: NSRange)] {
        let timeRanges = timeLabelRanges(in: text)
        let matches = extractPriceMatches(from: text)
        var filtered: [(Double, NSRange)] = []

        for (value, range) in matches {
            if timeRanges.contains(where: { intersects($0, range) }) { continue }
            if isLikelyPercentOrVolume(text: text, range: range) { continue }
            filtered.append((value, range))
        }

        return filtered
    }

    static func extractSignedChange(from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: changePattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let signRange = Range(match.range(at: 1), in: text),
              let valueRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        var sign = String(text[signRange])
        if sign == "−" { sign = "-" }
        let value = String(text[valueRange])
        guard let numeric = Double(value) else { return nil }
        return sign == "-" ? -numeric : numeric
    }

    private static func timeLabelRanges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).map { $0.range(at: 0) }
    }

    private static func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        let lhsEnd = lhs.location + lhs.length
        let rhsEnd = rhs.location + rhs.length
        return max(lhs.location, rhs.location) < min(lhsEnd, rhsEnd)
    }

    private static func isLikelyPercentOrVolume(text: String, range: NSRange) -> Bool {
        guard let before = character(at: range.location - 1, in: text),
              let after = character(at: range.location + range.length, in: text) else {
            let afterOnly = character(at: range.location + range.length, in: text)
            let beforeOnly = character(at: range.location - 1, in: text)
            return isSuffixMarker(afterOnly) || isSuffixMarker(beforeOnly)
        }

        if before == ":" || after == ":" { return true }
        if isSuffixMarker(after) || isSuffixMarker(before) { return true }
        return false
    }

    private static func isSuffixMarker(_ char: Character?) -> Bool {
        guard let char else { return false }
        return char == "%" || char == "K" || char == "M" || char == "B" || char == "k" || char == "m" || char == "b"
    }

    private static func character(at offset: Int, in text: String) -> Character? {
        guard offset >= 0 else { return nil }
        guard let index = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else { return nil }
        if index >= text.endIndex { return nil }
        return text[index]
    }

    private static func minutes(from label: String) -> Int? {
        let parts = label.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hours = Int(parts[0]),
              let mins = Int(parts[1]) else { return nil }
        return hours * 60 + mins
    }
}
