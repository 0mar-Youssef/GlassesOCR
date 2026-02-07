import Foundation
import Vision

struct CandleSignals {
    let ticker: String?
    let timeframe: String?
    let keywordHits: Int
    let directionalHits: Int
    let priceCountAxis: Int
    let timeLabelCount: Int
}

struct CandleDetectionDecision {
    let isCandleChart: Bool
    let confidence: Double
    let reasons: [String]
    let signals: CandleSignals
}

final class CandleChartDetector {
    private let upIndicators = ["UP", "▲", "△", "↑", "GAIN", "GREEN", "BULL"]
    private let downIndicators = ["DOWN", "▼", "▽", "↓", "LOSS", "RED", "BEAR"]
    private let chartKeywords = ["OPEN", "HIGH", "LOW", "CLOSE", "OHLC", "VOLUME", "CHART", "CANDLE", "INDICATOR"]

    private let detectThreshold: Double = 0.60

    func detect(ocrResult: OcrResult) -> CandleDetectionDecision {
        let text = ocrResult.recognizedText
        guard !text.isEmpty else {
            let signals = CandleSignals(
                ticker: nil,
                timeframe: nil,
                keywordHits: 0,
                directionalHits: 0,
                priceCountAxis: 0,
                timeLabelCount: 0
            )
            return CandleDetectionDecision(
                isCandleChart: false,
                confidence: 0,
                reasons: ["no_text"],
                signals: signals
            )
        }

        let region = CandleParsing.splitIntoRegions(ocrResult: ocrResult)
        let combinedUpper = text.uppercased()
        let headerUpper = region.header.uppercased()
        let footerUpper = region.footer.uppercased()

        let axisPrices = CandleParsing.extractFilteredPrices(from: region.leftAxis + " " + region.rightAxis)
        let priceCountAxis = axisPrices.count
        let timeframe = CandleParsing.extractTimeframe(from: headerUpper) ?? CandleParsing.extractTimeframe(from: combinedUpper)
        let keywordHits = chartKeywords.filter { combinedUpper.contains($0) }.count
        let directionalHits = (upIndicators + downIndicators).filter { combinedUpper.contains($0) }.count
        let timeLabelCount = CandleParsing.extractTimeLabels(from: footerUpper + " " + combinedUpper).count

        let allowSingleLetterTicker = (timeframe != nil && priceCountAxis >= 4) || keywordHits >= 2 || timeLabelCount >= 2
        let ticker = selectTicker(from: [headerUpper, combinedUpper], allowSingleLetter: allowSingleLetterTicker)

        var confidence = ocrResult.confidence * 0.2
        confidence += timeframe != nil ? 0.25 : 0
        confidence += priceCountAxis >= 4 ? 0.25 : 0
        confidence += keywordHits >= 2 ? 0.10 : 0
        confidence += timeLabelCount >= 2 ? 0.08 : 0
        confidence += ticker != nil ? 0.10 : 0
        confidence += directionalHits > 0 ? 0.05 : 0
        confidence = min(max(confidence, 0), 1)

        var reasons: [String] = []
        if timeframe != nil { reasons.append("timeframe") }
        if priceCountAxis >= 4 { reasons.append("axis_prices(\(priceCountAxis))") }
        if keywordHits >= 2 { reasons.append("keywords(\(keywordHits))") }
        if timeLabelCount >= 2 { reasons.append("time_labels(\(timeLabelCount))") }
        if ticker != nil { reasons.append("ticker") }
        if directionalHits > 0 { reasons.append("direction(\(directionalHits))") }

        let signals = CandleSignals(
            ticker: ticker,
            timeframe: timeframe,
            keywordHits: keywordHits,
            directionalHits: directionalHits,
            priceCountAxis: priceCountAxis,
            timeLabelCount: timeLabelCount
        )

        return CandleDetectionDecision(
            isCandleChart: confidence >= detectThreshold,
            confidence: confidence,
            reasons: reasons,
            signals: signals
        )
    }

    private func selectTicker(from texts: [String], allowSingleLetter: Bool) -> String? {
        for text in texts {
            let candidates = CandleParsing.extractTickerCandidates(from: text)
            for token in candidates {
                if CandleParsing.financeStoplist.contains(token) { continue }
                if CandleParsing.isTimeframeToken(token) { continue }
                if token.count == 1 && !allowSingleLetter { continue }
                return token
            }
        }
        return nil
    }
}
