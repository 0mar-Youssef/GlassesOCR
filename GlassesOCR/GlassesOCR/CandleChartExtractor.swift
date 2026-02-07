import Foundation
import Vision

final class CandleChartExtractor {
    private let upIndicators = ["UP", "▲", "△", "↑", "GAIN", "GREEN", "BULL"]
    private let downIndicators = ["DOWN", "▼", "▽", "↓", "LOSS", "RED", "BEAR"]
    private let volatileIndicators = ["VOLATILE", "CHOP", "SPIKE", "WHIPSAW"]

    func extract(ocrResult: OcrResult, decision: CandleDetectionDecision) -> CandleObject? {
        let text = ocrResult.recognizedText
        guard !text.isEmpty else { return nil }

        let region = CandleParsing.splitIntoRegions(ocrResult: ocrResult)
        let combinedUpper = text.uppercased()
        let footerUpper = region.footer.uppercased()

        let ticker = decision.signals.ticker
        let timeframe = decision.signals.timeframe

        let range = extractRange(from: combinedUpper, axisText: region.leftAxis + " " + region.rightAxis)
        let timeLabels = CandleParsing.extractTimeLabels(from: footerUpper + " " + combinedUpper)
        let trajectory = extractTrajectory(from: combinedUpper)

        let candle = CandleObject(
            ticker: ticker,
            timeframe: timeframe,
            sourceApp: nil,
            rangeStart: range?.lowerBound,
            rangeEnd: range?.upperBound,
            visibleTimeStart: timeLabels.first,
            visibleTimeEnd: timeLabels.count >= 2 ? timeLabels.last : nil,
            trajectory: trajectory,
            confidence: decision.confidence,
            rawSnippet: String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
        )

        return candle
    }

    private func extractRange(from text: String, axisText: String) -> ClosedRange<Double>? {
        if let highLowRange = extractRangeFromHighLow(in: text) {
            return highLowRange
        }

        let axisPrices = CandleParsing.extractFilteredPrices(from: axisText)
        guard let minimum = axisPrices.min(), let maximum = axisPrices.max() else { return nil }
        return minimum...maximum
    }

    private func extractRangeFromHighLow(in text: String) -> ClosedRange<Double>? {
        let priceMatches = CandleParsing.extractFilteredPriceMatches(from: text)

        guard let regex = try? NSRegularExpression(pattern: #"\b(HIGH|LOW)\b"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var highValue: Double?
        var lowValue: Double?

        for match in matches {
            guard let wordRange = Range(match.range(at: 1), in: text) else { continue }
            let word = String(text[wordRange])
            let maxDistance = 40

            let start = match.range.location + match.range.length
            let nearby = priceMatches
                .filter { $0.range.location > start && $0.range.location - start <= maxDistance }
                .min(by: { $0.range.location < $1.range.location })
            if let nearest = nearby {
                if word == "HIGH" { highValue = nearest.value }
                if word == "LOW" { lowValue = nearest.value }
            }
        }

        if let lowValue, let highValue {
            return min(lowValue, highValue)...max(lowValue, highValue)
        }

        return nil
    }

    private func extractTrajectory(from text: String) -> Trajectory {
        if let signedChange = CandleParsing.extractSignedChange(from: text) {
            if signedChange > 0 { return .up }
            if signedChange < 0 { return .down }
        }

        if upIndicators.contains(where: { text.contains($0) }) { return .up }
        if downIndicators.contains(where: { text.contains($0) }) { return .down }
        if volatileIndicators.contains(where: { text.contains($0) }) { return .volatile }
        if text.contains("SIDEWAYS") || text.contains("RANGE") { return .flat }
        return .unknown
    }
}
