//
//  Parser.swift
//  GlassesOCR
//
//  Extracts stock and candlestick chart observations from OCR text.
//

import Foundation
import Vision
import CoreGraphics
import CoreData

// MARK: - Stock Observation

struct StockObservation: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let ticker: String
    let price: Double
    let change: String
    let confidence: Double
    let rawSnippet: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        ticker: String,
        price: Double,
        change: String,
        confidence: Double,
        rawSnippet: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.ticker = ticker
        self.price = price
        self.change = change
        self.confidence = confidence
        self.rawSnippet = rawSnippet
    }
}

// MARK: - Candlestick Models

enum Trajectory: String, Codable, Sendable {
    case up
    case down
    case flat
    case volatile
    case unknown
}

struct CandleObject: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let ticker: String?
    let timeframe: String?
    let sourceApp: String?
    let rangeStart: Double?
    let rangeEnd: Double?
    let visibleTimeStart: String?
    let visibleTimeEnd: String?
    let visibleDateStart: String?
    let visibleDateEnd: String?
    let trajectory: Trajectory
    let slopeMetric: Double?
    let confidence: Double
    let rawSnippet: String
    let rawOcrHeader: String?
    let rawOcrYAxis: String?
    let rawOcrFooter: String?
    let debugJSON: Data?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        ticker: String?,
        timeframe: String?,
        sourceApp: String?,
        rangeStart: Double?,
        rangeEnd: Double?,
        visibleTimeStart: String?,
        visibleTimeEnd: String?,
        visibleDateStart: String?,
        visibleDateEnd: String?,
        trajectory: Trajectory,
        slopeMetric: Double? = nil,
        confidence: Double,
        rawSnippet: String,
        rawOcrHeader: String? = nil,
        rawOcrYAxis: String? = nil,
        rawOcrFooter: String? = nil,
        debugJSON: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.ticker = ticker
        self.timeframe = timeframe
        self.sourceApp = sourceApp
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.visibleTimeStart = visibleTimeStart
        self.visibleTimeEnd = visibleTimeEnd
        self.visibleDateStart = visibleDateStart
        self.visibleDateEnd = visibleDateEnd
        self.trajectory = trajectory
        self.slopeMetric = slopeMetric
        self.confidence = confidence
        self.rawSnippet = rawSnippet
        self.rawOcrHeader = rawOcrHeader
        self.rawOcrYAxis = rawOcrYAxis
        self.rawOcrFooter = rawOcrFooter
        self.debugJSON = debugJSON
    }
}

struct SessionBucket: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: Date
    var endTime: Date
    var candles: [CandleObject]

    var topTicker: String {
        let symbols = candles.compactMap(\.ticker)
        guard !symbols.isEmpty else { return "Unknown" }
        return symbols
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .max(by: { $0.value < $1.value })?
            .key ?? "Unknown"
    }
}

struct ChartExtractionResult {
    let isCandleChart: Bool
    let confidence: Double
    let candle: CandleObject?
    let reason: String
}

// MARK: - Candle Chart Pipeline

struct CandleChartContext {
    let regions: RegionOcrBundle
    let combinedUpper: String
    let headerUpper: String
    let footerUpper: String
}

struct CandleChartDetection {
    let isCandleChart: Bool
    let confidence: Double
    let reason: String
    let context: CandleChartContext?
}

struct CandleChartExtraction {
    let candle: CandleObject?
    let reason: String
}

final class CandleChartDetector: Sendable {
    private let parser = Parser()

    func detect(regions: RegionOcrBundle, gateConfidence: Double) -> CandleChartDetection {
        let text = regions.combinedText
        guard !text.isEmpty else {
            return CandleChartDetection(isCandleChart: false, confidence: gateConfidence * 0.4, reason: "No OCR text", context: nil)
        }

        let combinedUpper = text.uppercased()
        let headerUpper = regions.header.recognizedText.uppercased()
        let footerUpper = regions.footer.recognizedText.uppercased()

        let ticker = parser.extractTicker(from: headerUpper) ?? parser.extractTicker(from: combinedUpper)
        let timeframe = parser.extractTimeframe(from: headerUpper) ?? parser.extractTimeframe(from: combinedUpper)
        let sourceApp = parser.extractSourceApp(from: combinedUpper)

        let axisPrices = parser.extractAxisPrices(from: regions.yAxis.observations)
        let priceCandidates = axisPrices.isEmpty
            ? parser.extractAllPrices(from: regions.yAxis.recognizedText)
            : axisPrices

        let keywordHits = parser.chartKeywords.filter { combinedUpper.contains($0) }.count
        let directionalHits = (parser.upIndicators + parser.downIndicators).filter { combinedUpper.contains($0) }.count

        var confidence = gateConfidence * 0.45
        confidence += regions.averageConfidence * 0.2
        confidence += ticker != nil ? 0.15 : 0
        confidence += timeframe != nil ? 0.18 : 0
        confidence += priceCandidates.count >= 4 ? 0.15 : 0
        confidence += min(Double(keywordHits) * 0.05, 0.15)
        confidence += directionalHits > 0 ? 0.05 : 0
        confidence += sourceApp != nil ? 0.07 : 0
        confidence = min(max(confidence, 0), 1)

        guard confidence >= 0.55 else {
            return CandleChartDetection(
                isCandleChart: false,
                confidence: confidence,
                reason: "Chart confidence below threshold",
                context: nil
            )
        }

        let context = CandleChartContext(
            regions: regions,
            combinedUpper: combinedUpper,
            headerUpper: headerUpper,
            footerUpper: footerUpper
        )

        return CandleChartDetection(isCandleChart: true, confidence: confidence, reason: "Detected", context: context)
    }
}

final class CandleChartExtractor: Sendable {
    private let parser = Parser()
    private let trajectoryAnalyzer = TrajectoryAnalyzer()

    func extract(from context: CandleChartContext, cropPlan: CropPlan, snapshot: FrameSnapshot, confidence: Double, adapter: PlatformAdapter? = nil) -> CandleChartExtraction {
        let regions = context.regions
        let combinedUpper = context.combinedUpper

        var ticker = parser.extractTicker(from: context.headerUpper) ?? parser.extractTicker(from: combinedUpper)
        var timeframe = parser.extractTimeframe(from: context.headerUpper) ?? parser.extractTimeframe(from: combinedUpper)
        var sourceApp = parser.extractSourceApp(from: combinedUpper)

        if let adapter {
            let augmented = adapter.augmentParsing(ticker: ticker, timeframe: timeframe, headerText: regions.header.recognizedText)
            ticker = augmented.ticker
            timeframe = augmented.timeframe
            sourceApp = sourceApp ?? adapter.platformName
        }

        let axisPrices = parser.extractAxisPrices(from: regions.yAxis.observations)
        let priceCandidates = axisPrices.isEmpty
            ? parser.extractAllPrices(from: regions.yAxis.recognizedText)
            : axisPrices
        let range = parser.inferVisibleRange(from: priceCandidates)

        let timeLabels = parser.extractTimeLabels(from: regions.footer.observations, restrictToLowerBand: false)
        let fallbackTimeLabels = timeLabels.isEmpty ? parser.extractTimeLabels(from: context.footerUpper + " " + combinedUpper) : timeLabels
        let dateLabels = parser.extractDateLabels(from: regions.footer.observations, restrictToLowerBand: false)
        let fallbackDateLabels = dateLabels.isEmpty ? parser.extractDateLabels(from: context.footerUpper + " " + combinedUpper) : dateLabels

        var trajectory: Trajectory = parser.extractTrajectory(from: combinedUpper)
        var slopeMetric: Double? = nil
        if let range = range, let bodyImage = snapshot.cropMidRes(normalizedRect: cropPlan.bodyRect) {
            let result = trajectoryAnalyzer.analyze(image: bodyImage, priceRange: range)
            trajectory = result.trajectory
            slopeMetric = result.slopeMetric
        }

        let snippetText = [regions.header.recognizedText, regions.yAxis.recognizedText, regions.footer.recognizedText]
            .joined(separator: " ")
            .prefix(180)

        let candle = CandleObject(
            ticker: ticker,
            timeframe: timeframe,
            sourceApp: sourceApp,
            rangeStart: range?.lowerBound,
            rangeEnd: range?.upperBound,
            visibleTimeStart: fallbackTimeLabels.first,
            visibleTimeEnd: fallbackTimeLabels.count >= 2 ? fallbackTimeLabels.last : nil,
            visibleDateStart: fallbackDateLabels.first,
            visibleDateEnd: fallbackDateLabels.count >= 2 ? fallbackDateLabels.last : nil,
            trajectory: trajectory,
            slopeMetric: slopeMetric,
            confidence: confidence,
            rawSnippet: String(snippetText).replacingOccurrences(of: "\n", with: " "),
            rawOcrHeader: regions.header.recognizedText.isEmpty ? nil : regions.header.recognizedText,
            rawOcrYAxis: regions.yAxis.recognizedText.isEmpty ? nil : regions.yAxis.recognizedText,
            rawOcrFooter: regions.footer.recognizedText.isEmpty ? nil : regions.footer.recognizedText,
            debugJSON: nil
        )

        return CandleChartExtraction(candle: candle, reason: "Extracted")
    }
}

enum CandleGateStatus: Sendable {
    case warmingUp
    case accepted
    case rejected
}

struct CandleGateResult: Sendable {
    let status: CandleGateStatus
    let candle: CandleObject?
    let reason: String
}

actor CandleGate {
    private let requiredStableCount: Int
    private let emitCooldown: TimeInterval
    private let maxWindow: TimeInterval

    private var buffer: [(candle: CandleObject, timestamp: Date)] = []
    private var lastEmittedSignature: String?
    private var lastEmitTime: Date?

    init(requiredStableCount: Int = 3, emitCooldown: TimeInterval = 30, maxWindow: TimeInterval = 12) {
        self.requiredStableCount = max(2, requiredStableCount)
        self.emitCooldown = emitCooldown
        self.maxWindow = maxWindow
    }

    func reset() {
        buffer.removeAll()
    }

    func process(_ candle: CandleObject, at now: Date = Date()) -> CandleGateResult {
        buffer.append((candle, now))
        buffer = buffer.filter { now.timeIntervalSince($0.timestamp) <= maxWindow }

        let signature = stableSignature(for: candle)
        let recent = buffer.suffix(requiredStableCount)
        let stable = recent.count == requiredStableCount &&
            recent.allSatisfy { stableSignature(for: $0.candle) == signature }

        guard stable else {
            let progress = min(recent.count, requiredStableCount)
            return CandleGateResult(
                status: .warmingUp,
                candle: nil,
                reason: "Waiting for stability (\(progress)/\(requiredStableCount))"
            )
        }

        if let lastSig = lastEmittedSignature,
           lastSig == signature,
           let lastTime = lastEmitTime,
           now.timeIntervalSince(lastTime) < emitCooldown {
            return CandleGateResult(status: .rejected, candle: nil, reason: "Stable but recently emitted")
        }

        lastEmittedSignature = signature
        lastEmitTime = now
        return CandleGateResult(status: .accepted, candle: candle, reason: "Stable across \(requiredStableCount) frames")
    }

    private func stableSignature(for candle: CandleObject) -> String {
        let ticker = candle.ticker ?? "-"
        let timeframe = candle.timeframe ?? "-"
        let sourceApp = candle.sourceApp ?? "-"
        let timeStart = candle.visibleTimeStart ?? "-"
        let timeEnd = candle.visibleTimeEnd ?? "-"
        let dateStart = candle.visibleDateStart ?? "-"
        let dateEnd = candle.visibleDateEnd ?? "-"
        return "\(ticker)|\(timeframe)|\(sourceApp)|\(timeStart)|\(timeEnd)|\(dateStart)|\(dateEnd)"
    }
}

// MARK: - Parser

final class Parser: Sendable {

    // MARK: - Regex Patterns
    // Allow single-letter tickers (e.g., "F", "C") while still supporting dotted suffixes.
    fileprivate let tickerPattern = #"\b([A-Z]{1,8}(?:\.[A-Z]{1,2})?)\b"#
    fileprivate let pricePattern = #"\$?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,4})?|\d+(?:\.\d{1,4})?)"#
    fileprivate let changePattern = #"([+\-−])\s*(\d+(?:\.\d{1,2})?)\s*%?"#
    fileprivate let timeframePattern = #"\b(1m|3m|5m|10m|15m|30m|45m|1h|2h|4h|6h|8h|12h|1d|3d|1w)\b"#
    fileprivate let timeLabelPattern = #"\b(?:[01]?\d|2[0-3]):[0-5]\d\b"#
    fileprivate let dateLabelPatterns = [
        #"\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,?\s*\d{2,4})?\b"#,
        #"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#,
        #"\b\d{4}-\d{2}-\d{2}\b"#
    ]

    fileprivate let upIndicators = ["UP", "▲", "△", "↑", "GAIN", "GREEN", "BULL"]
    fileprivate let downIndicators = ["DOWN", "▼", "▽", "↓", "LOSS", "RED", "BEAR"]
    fileprivate let volatileIndicators = ["VOLATILE", "CHOP", "SPIKE", "WHIPSAW"]
    fileprivate let chartKeywords = ["OPEN", "HIGH", "LOW", "CLOSE", "OHLC", "VOLUME", "CHART", "CANDLE", "INDICATOR"]

    fileprivate let excludedWords: Set<String> = [
        "THE", "AND", "FOR", "ARE", "BUT", "NOT", "YOU", "ALL", "CAN", "HER", "WAS", "ONE", "OUR", "OUT", "DAY", "GET",
        "HAS", "HIM", "HIS", "HOW", "ITS", "MAY", "NEW", "NOW", "OLD", "SEE", "WAY", "WHO", "DID", "USD", "EUR", "GBP",
        "JPY", "NYSE", "NASDAQ", "DOW", "USA", "CEO", "CFO", "OPEN", "HIGH", "LOW", "CLOSE", "VOL", "CHART", "TIME"
    ]

    fileprivate let appHints: [String: [String]] = [
        "Kraken": ["KRAKEN"],
        "Coinbase": ["COINBASE"],
        "E*TRADE": ["E*TRADE", "ETRADE"],
        "TradingView": ["TRADINGVIEW", "TV"]
    ]

    // MARK: - Public Interface

    func parse(ocrResult: OcrResult) -> StockObservation? {
        let text = ocrResult.recognizedText
        guard !text.isEmpty else { return nil }

        guard let ticker = extractTicker(from: text),
              let price = extractPrice(from: text) else {
            return nil
        }

        let snippet = String(text.prefix(100))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        return StockObservation(
            ticker: ticker,
            price: price,
            change: extractChange(from: text) ?? "N/A",
            confidence: ocrResult.confidence,
            rawSnippet: snippet
        )
    }

    func parseCandleChart(ocrResult: OcrResult) -> ChartExtractionResult {
        let text = ocrResult.recognizedText
        guard !text.isEmpty else {
            return ChartExtractionResult(isCandleChart: false, confidence: 0, candle: nil, reason: "No OCR text")
        }

        let region = splitIntoRegions(ocrResult: ocrResult)
        let combinedUpper = text.uppercased()
        let headerUpper = region.header.uppercased()
        let footerUpper = region.footer.uppercased()

        let ticker = extractTicker(from: headerUpper) ?? extractTicker(from: combinedUpper)
        let timeframe = extractTimeframe(from: headerUpper) ?? extractTimeframe(from: combinedUpper)
        let sourceApp = extractSourceApp(from: combinedUpper)

        let axisPrices = extractAxisPrices(from: ocrResult.observations)
        let priceCandidates = axisPrices.isEmpty
            ? extractAllPrices(from: region.rightAxis + " " + region.leftAxis)
            : axisPrices
        let range = inferVisibleRange(from: priceCandidates)
        let timeLabels = extractTimeLabels(from: ocrResult.observations)
        let fallbackTimeLabels = timeLabels.isEmpty ? extractTimeLabels(from: footerUpper + " " + combinedUpper) : timeLabels
        let dateLabels = extractDateLabels(from: ocrResult.observations)
        let fallbackDateLabels = dateLabels.isEmpty ? extractDateLabels(from: footerUpper + " " + combinedUpper) : dateLabels

        let keywordHits = chartKeywords.filter { combinedUpper.contains($0) }.count
        let directionalHits = (upIndicators + downIndicators).filter { combinedUpper.contains($0) }.count

        var confidence = ocrResult.confidence * 0.25
        confidence += ticker != nil ? 0.18 : 0
        confidence += timeframe != nil ? 0.22 : 0
        confidence += priceCandidates.count >= 4 ? 0.20 : 0
        confidence += min(Double(keywordHits) * 0.06, 0.18)
        confidence += directionalHits > 0 ? 0.08 : 0
        confidence += sourceApp != nil ? 0.09 : 0
        confidence = min(max(confidence, 0), 1)

        guard confidence >= 0.55 else {
            return ChartExtractionResult(
                isCandleChart: false,
                confidence: confidence,
                candle: nil,
                reason: "Chart confidence below threshold"
            )
        }

        let candle = CandleObject(
            ticker: ticker,
            timeframe: timeframe,
            sourceApp: sourceApp,
            rangeStart: range?.lowerBound,
            rangeEnd: range?.upperBound,
            visibleTimeStart: fallbackTimeLabels.first,
            visibleTimeEnd: fallbackTimeLabels.count >= 2 ? fallbackTimeLabels.last : nil,
            visibleDateStart: fallbackDateLabels.first,
            visibleDateEnd: fallbackDateLabels.count >= 2 ? fallbackDateLabels.last : nil,
            trajectory: extractTrajectory(from: combinedUpper),
            confidence: confidence,
            rawSnippet: String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
        )

        return ChartExtractionResult(isCandleChart: true, confidence: confidence, candle: candle, reason: "Detected")
    }

    // MARK: - Region split

    struct RegionText {
        let header: String
        let footer: String
        let leftAxis: String
        let rightAxis: String
    }

    fileprivate func splitIntoRegions(ocrResult: OcrResult) -> RegionText {
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

    // MARK: - Extraction methods

    fileprivate func extractTicker(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: tickerPattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[matchRange]).uppercased()
            if !excludedWords.contains(token) {
                return token
            }
        }
        return nil
    }

    fileprivate func extractPrice(from text: String) -> Double? {
        extractAllPrices(from: text).first
    }

    fileprivate func extractAllPrices(from text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pricePattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var prices: [Double] = []

        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let cleaned = String(text[matchRange]).replacingOccurrences(of: ",", with: "")
            if let value = Double(cleaned), value > 0, value < 10_000_000 {
                prices.append(value)
            }
        }

        return prices
    }

    fileprivate func inferVisibleRange(from prices: [Double]) -> ClosedRange<Double>? {
        guard let minimum = prices.min(), let maximum = prices.max() else { return nil }
        return minimum...maximum
    }

    fileprivate func extractTimeframe(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: timeframePattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).lowercased()
    }

    fileprivate func extractTimeLabels(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let labels = regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range(at: 0), in: text).map { String(text[$0]) }
        }
        return uniquePreservingOrder(labels)
    }

    fileprivate func extractTimeLabels(from observations: [VNRecognizedTextObservation]) -> [String] {
        extractTimeLabels(from: observations, restrictToLowerBand: true)
    }

    fileprivate func extractTimeLabels(from observations: [VNRecognizedTextObservation], restrictToLowerBand: Bool) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        var hits: [(label: String, x: CGFloat)] = []

        for observation in observations {
            let box = observation.boundingBox
            if restrictToLowerBand && box.midY >= 0.25 { continue }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let range = NSRange(text.startIndex..., in: text)

            for match in regex.matches(in: text, options: [], range: range) {
                guard let matchRange = Range(match.range(at: 0), in: text) else { continue }
                hits.append((String(text[matchRange]), box.midX))
            }
        }

        let ordered = hits.sorted { $0.x < $1.x }.map { $0.label }
        return uniquePreservingOrder(ordered)
    }

    fileprivate func extractDateLabels(from text: String) -> [String] {
        var labels: [String] = []
        for pattern in dateLabelPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range).compactMap { match in
                Range(match.range(at: 0), in: text).map { String(text[$0]) }
            }
            labels.append(contentsOf: matches)
        }
        return uniquePreservingOrder(labels)
    }

    fileprivate func extractDateLabels(from observations: [VNRecognizedTextObservation]) -> [String] {
        extractDateLabels(from: observations, restrictToLowerBand: true)
    }

    fileprivate func extractDateLabels(from observations: [VNRecognizedTextObservation], restrictToLowerBand: Bool) -> [String] {
        var hits: [(label: String, x: CGFloat)] = []

        for observation in observations {
            let box = observation.boundingBox
            if restrictToLowerBand && box.midY >= 0.25 { continue }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string

            for pattern in dateLabelPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, options: [], range: range) {
                    guard let matchRange = Range(match.range(at: 0), in: text) else { continue }
                    hits.append((String(text[matchRange]), box.midX))
                }
            }
        }

        let ordered = hits.sorted { $0.x < $1.x }.map { $0.label }
        return uniquePreservingOrder(ordered)
    }

    fileprivate func extractSourceApp(from text: String) -> String? {
        for (app, hints) in appHints where hints.contains(where: { text.contains($0) }) {
            return app
        }
        return nil
    }

    fileprivate func extractTrajectory(from text: String) -> Trajectory {
        if upIndicators.contains(where: { text.contains($0) }) { return .up }
        if downIndicators.contains(where: { text.contains($0) }) { return .down }
        if volatileIndicators.contains(where: { text.contains($0) }) { return .volatile }
        if text.contains("SIDEWAYS") || text.contains("RANGE") { return .flat }
        return .unknown
    }

    fileprivate func extractChange(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: changePattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let signRange = Range(match.range(at: 1), in: text),
           let valueRange = Range(match.range(at: 2), in: text) {
            var sign = String(text[signRange])
            if sign == "−" { sign = "-" }
            let value = String(text[valueRange])
            let suffix = text[valueRange.upperBound...].hasPrefix("%") ? "%" : ""
            return "\(sign)\(value)\(suffix)"
        }

        // Fallback: handle directional words/arrows captured by OCR without numeric values.
        let upper = text.uppercased()
        if upIndicators.contains(where: { indicator in upper.contains(indicator) || text.contains(indicator) }) {
            return "UP"
        }
        if downIndicators.contains(where: { indicator in upper.contains(indicator) || text.contains(indicator) }) {
            return "DOWN"
        }

        return nil
    }

    fileprivate func extractAxisPrices(from observations: [VNRecognizedTextObservation]) -> [Double] {
        var prices: [Double] = []

        for observation in observations {
            let box = observation.boundingBox
            guard box.midX < 0.22 || box.midX > 0.78 else { continue }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            prices.append(contentsOf: extractAllPrices(from: text))
        }

        return prices
    }

    fileprivate func uniquePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.uppercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
}

// MARK: - Session Tracker

@MainActor
final class SessionTracker: ObservableObject {
    @Published private(set) var activeSession: CDSession?

    private let context: NSManagedObjectContext
    private let inactivityTimeout: TimeInterval = 5 * 60
    private let dedupInterval: TimeInterval = 120
    private let gateWindowSize = 5
    private let gateRequiredCount = 3
    private var gateSamples: [Bool] = []

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        self.activeSession = fetchActiveSession()
    }

    func observeGate(confidence: Double, isChart: Bool, at now: Date = Date()) {
        let pass = isChart && confidence >= 0.70
        gateSamples.append(pass)
        if gateSamples.count > gateWindowSize {
            gateSamples.removeFirst(gateSamples.count - gateWindowSize)
        }

        if shouldStartSession(), activeSession == nil {
            let session = CDSession(context: context)
            session.id = UUID()
            session.startAt = now
            session.endAt = now
            session.lastActiveAt = now
            activeSession = session
            saveContext()
        } else if pass, let activeSession {
            activeSession.lastActiveAt = now
            activeSession.endAt = now
            saveContext()
        } else if let activeSession, let lastActive = activeSession.lastActiveAt, now.timeIntervalSince(lastActive) > inactivityTimeout {
            activeSession.endAt = lastActive
            self.activeSession = nil
            saveContext()
        }
    }

    func record(_ candle: CandleObject, chartBox: CGRect?, thumbnailData: Data?) {
        let now = candle.timestamp
        let session = activeSession ?? createSession(at: now)

        session.lastActiveAt = now
        session.endAt = now

        let dedupKey = makeDedupKey(candle: candle, chartBox: chartBox)
        if let existing = fetchRecentCandle(dedupKey: dedupKey, since: now.addingTimeInterval(-dedupInterval)) {
            merge(existing: existing, incoming: candle)
            existing.updatedAt = now
            if let thumbnailData, shouldUpdateThumbnail(existing: existing, incomingConfidence: candle.confidence) {
                let candleID = existing.id ?? UUID()
                if existing.id == nil { existing.id = candleID }
                existing.thumbnailRef = persistThumbnail(data: thumbnailData, candleID: candleID)
            }
        } else {
            let newCandle = CDCandleObject(context: context)
            newCandle.id = candle.id
            newCandle.timestampCaptured = candle.timestamp
            newCandle.updatedAt = now
            newCandle.dedupKey = dedupKey
            apply(candle: candle, to: newCandle)
            newCandle.session = session

            if let thumbnailData {
                newCandle.thumbnailRef = persistThumbnail(data: thumbnailData, candleID: candle.id)
            }
        }

        session.candleCount = Int32(session.candlesArray.count)
        if session.platformHintRaw == nil, let app = candle.sourceApp {
            session.platformHintRaw = app
        }
        if !session.topSymbols.isEmpty {
            session.summaryTopSymbols = session.topSymbols.prefix(3).joined(separator: ", ")
        }
        saveContext()
    }

    private func shouldStartSession() -> Bool {
        gateSamples.filter { $0 }.count >= gateRequiredCount
    }

    private func createSession(at date: Date) -> CDSession {
        let session = CDSession(context: context)
        session.id = UUID()
        session.startAt = date
        session.endAt = date
        session.lastActiveAt = date
        activeSession = session
        return session
    }

    private func fetchActiveSession() -> CDSession? {
        let request: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "startAt", ascending: false)]
        request.fetchLimit = 1
        guard let session = (try? context.fetch(request))?.first else { return nil }
        if let lastActive = session.lastActiveAt, Date().timeIntervalSince(lastActive) <= inactivityTimeout {
            return session
        }
        return nil
    }

    private func fetchRecentCandle(dedupKey: String, since date: Date) -> CDCandleObject? {
        let request: NSFetchRequest<CDCandleObject> = CDCandleObject.fetchRequest()
        request.predicate = NSPredicate(format: "dedupKey == %@ AND timestampCaptured >= %@", dedupKey, date as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestampCaptured", ascending: false)]
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func makeDedupKey(candle: CandleObject, chartBox: CGRect?) -> String {
        let ticker = candle.ticker ?? "-"
        let timeframe = candle.timeframe ?? "-"
        let boxKey: String
        if let box = chartBox {
            let q = { (value: CGFloat) -> String in String(format: "%.2f", value) }
            boxKey = "\(q(box.minX))|\(q(box.minY))|\(q(box.width))|\(q(box.height))"
        } else {
            boxKey = "no-box"
        }
        return "\(ticker)|\(timeframe)|\(boxKey)"
    }

    private func merge(existing: CDCandleObject, incoming: CandleObject) {
        let shouldReplace = incoming.confidence >= existing.confidence

        if shouldReplace || existing.symbol == nil { existing.symbol = incoming.ticker }
        if shouldReplace || existing.timeframeRaw == nil { existing.timeframeRaw = incoming.timeframe }
        if shouldReplace || existing.sourceAppHintRaw == nil { existing.sourceAppHintRaw = incoming.sourceApp }
        if shouldReplace || existing.visibleTimeStart == nil { existing.visibleTimeStart = incoming.visibleTimeStart }
        if shouldReplace || existing.visibleTimeEnd == nil { existing.visibleTimeEnd = incoming.visibleTimeEnd }
        if shouldReplace || existing.visibleDateStart == nil { existing.visibleDateStart = incoming.visibleDateStart }
        if shouldReplace || existing.visibleDateEnd == nil { existing.visibleDateEnd = incoming.visibleDateEnd }
        if shouldReplace || existing.trendRaw == nil { existing.trendRaw = incoming.trajectory.rawValue }
        if shouldReplace || existing.rawOcrHeader == nil { existing.rawOcrHeader = incoming.rawOcrHeader }
        if shouldReplace || existing.rawOcrYAxis == nil { existing.rawOcrYAxis = incoming.rawOcrYAxis }
        if shouldReplace || existing.rawOcrFooter == nil { existing.rawOcrFooter = incoming.rawOcrFooter }
        if shouldReplace || existing.debugJSON == nil { existing.debugJSON = incoming.debugJSON }

        if let rangeStart = incoming.rangeStart { existing.visiblePriceMin = rangeStart }
        if let rangeEnd = incoming.rangeEnd { existing.visiblePriceMax = rangeEnd }
        if let slope = incoming.slopeMetric { existing.slopeMetric = slope }

        existing.confidence = max(existing.confidence, incoming.confidence)
    }

    private func apply(candle: CandleObject, to record: CDCandleObject) {
        record.symbol = candle.ticker
        record.timeframeRaw = candle.timeframe
        record.sourceAppHintRaw = candle.sourceApp
        if let rangeStart = candle.rangeStart { record.visiblePriceMin = rangeStart }
        if let rangeEnd = candle.rangeEnd { record.visiblePriceMax = rangeEnd }
        record.visibleTimeStart = candle.visibleTimeStart
        record.visibleTimeEnd = candle.visibleTimeEnd
        record.visibleDateStart = candle.visibleDateStart
        record.visibleDateEnd = candle.visibleDateEnd
        record.trendRaw = candle.trajectory.rawValue
        if let slope = candle.slopeMetric { record.slopeMetric = slope }
        record.confidence = candle.confidence
        record.rawOcrHeader = candle.rawOcrHeader
        record.rawOcrYAxis = candle.rawOcrYAxis
        record.rawOcrFooter = candle.rawOcrFooter
        record.debugJSON = candle.debugJSON
    }

    private func shouldUpdateThumbnail(existing: CDCandleObject, incomingConfidence: Double) -> Bool {
        return incomingConfidence >= existing.confidence + 0.1 || existing.thumbnailRef == nil
    }

    private func persistThumbnail(data: Data, candleID: UUID) -> String? {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("\(candleID.uuidString).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            print("[SessionTracker] Failed to persist thumbnail: \(error)")
            return nil
        }
    }

    private func saveContext() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("[SessionTracker] Failed to save Core Data: \(error)")
        }
    }
}
