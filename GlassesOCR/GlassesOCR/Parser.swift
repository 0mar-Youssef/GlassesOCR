//
//  Parser.swift
//  GlassesOCR
//
//  Extracts stock and candlestick chart observations from OCR text.
//

import Foundation
import Vision
import CoreGraphics

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
    let confidence: Double
    let rawSnippet: String

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
        confidence: Double,
        rawSnippet: String
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
        self.confidence = confidence
        self.rawSnippet = rawSnippet
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
    let ocrResult: OcrResult
    let region: Parser.RegionText
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

    func detect(ocrResult: OcrResult) -> CandleChartDetection {
        let text = ocrResult.recognizedText
        guard !text.isEmpty else {
            return CandleChartDetection(isCandleChart: false, confidence: 0, reason: "No OCR text", context: nil)
        }

        let region = parser.splitIntoRegions(ocrResult: ocrResult)
        let combinedUpper = text.uppercased()
        let headerUpper = region.header.uppercased()
        let footerUpper = region.footer.uppercased()

        let ticker = parser.extractTicker(from: headerUpper) ?? parser.extractTicker(from: combinedUpper)
        let timeframe = parser.extractTimeframe(from: headerUpper) ?? parser.extractTimeframe(from: combinedUpper)
        let sourceApp = parser.extractSourceApp(from: combinedUpper)

        let axisPrices = parser.extractAxisPrices(from: ocrResult.observations)
        let priceCandidates = axisPrices.isEmpty
            ? parser.extractAllPrices(from: region.rightAxis + " " + region.leftAxis)
            : axisPrices

        let keywordHits = parser.chartKeywords.filter { combinedUpper.contains($0) }.count
        let directionalHits = (parser.upIndicators + parser.downIndicators).filter { combinedUpper.contains($0) }.count

        var confidence = ocrResult.confidence * 0.25
        confidence += ticker != nil ? 0.18 : 0
        confidence += timeframe != nil ? 0.22 : 0
        confidence += priceCandidates.count >= 4 ? 0.20 : 0
        confidence += min(Double(keywordHits) * 0.06, 0.18)
        confidence += directionalHits > 0 ? 0.08 : 0
        confidence += sourceApp != nil ? 0.09 : 0
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
            ocrResult: ocrResult,
            region: region,
            combinedUpper: combinedUpper,
            headerUpper: headerUpper,
            footerUpper: footerUpper
        )

        return CandleChartDetection(isCandleChart: true, confidence: confidence, reason: "Detected", context: context)
    }
}

final class CandleChartExtractor: Sendable {
    private let parser = Parser()

    func extract(from context: CandleChartContext, confidence: Double) -> CandleChartExtraction {
        let ocrResult = context.ocrResult
        let text = ocrResult.recognizedText
        let combinedUpper = context.combinedUpper

        let ticker = parser.extractTicker(from: context.headerUpper) ?? parser.extractTicker(from: combinedUpper)
        let timeframe = parser.extractTimeframe(from: context.headerUpper) ?? parser.extractTimeframe(from: combinedUpper)
        let sourceApp = parser.extractSourceApp(from: combinedUpper)

        let axisPrices = parser.extractAxisPrices(from: ocrResult.observations)
        let priceCandidates = axisPrices.isEmpty
            ? parser.extractAllPrices(from: context.region.rightAxis + " " + context.region.leftAxis)
            : axisPrices
        let range = parser.inferVisibleRange(from: priceCandidates)

        let timeLabels = parser.extractTimeLabels(from: ocrResult.observations)
        let fallbackTimeLabels = timeLabels.isEmpty ? parser.extractTimeLabels(from: context.footerUpper + " " + combinedUpper) : timeLabels
        let dateLabels = parser.extractDateLabels(from: ocrResult.observations)
        let fallbackDateLabels = dateLabels.isEmpty ? parser.extractDateLabels(from: context.footerUpper + " " + combinedUpper) : dateLabels

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
            trajectory: parser.extractTrajectory(from: combinedUpper),
            confidence: confidence,
            rawSnippet: String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
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
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        var hits: [(label: String, x: CGFloat)] = []

        for observation in observations {
            let box = observation.boundingBox
            guard box.midY < 0.25 else { continue }
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
        var hits: [(label: String, x: CGFloat)] = []

        for observation in observations {
            let box = observation.boundingBox
            guard box.midY < 0.25 else { continue }
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
    @Published private(set) var sessions: [SessionBucket] = []
    @Published private(set) var activeSession: SessionBucket?

    private let inactivityTimeout: TimeInterval = 5 * 60
    private let dedupInterval: TimeInterval = 12
    private let maxSessionsToKeep: Int = 200
    private let storageURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storageURL = docs.appendingPathComponent("candle_sessions.json")
        loadFromDisk()
    }

    func record(_ candle: CandleObject) {
        let now = candle.timestamp

        if var current = activeSession,
           now.timeIntervalSince(current.endTime) <= inactivityTimeout {
            current.endTime = now

            if let last = current.candles.last,
               shouldDeduplicate(last: last, incoming: candle, at: now) {
                current.candles[current.candles.count - 1] = candle
            } else {
                current.candles.append(candle)
            }

            activeSession = current
            upsertSession(current)
            pruneSessionsIfNeeded()
            saveToDisk()
            return
        }

        let newSession = SessionBucket(
            id: UUID(),
            startTime: now,
            endTime: now,
            candles: [candle]
        )
        activeSession = newSession
        upsertSession(newSession)
        pruneSessionsIfNeeded()
        saveToDisk()
    }

    private func shouldDeduplicate(last: CandleObject, incoming: CandleObject, at now: Date) -> Bool {
        let sameTicker = (last.ticker ?? "") == (incoming.ticker ?? "")
        let sameTimeframe = (last.timeframe ?? "") == (incoming.timeframe ?? "")
        let tooSoon = now.timeIntervalSince(last.timestamp) < dedupInterval
        return sameTicker && sameTimeframe && tooSoon
    }

    private func upsertSession(_ session: SessionBucket) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func pruneSessionsIfNeeded() {
        guard sessions.count > maxSessionsToKeep else { return }
        sessions.sort { $0.startTime > $1.startTime }
        sessions = Array(sessions.prefix(maxSessionsToKeep))
        if let active = activeSession,
           !sessions.contains(where: { $0.id == active.id }) {
            activeSession = nil
        }
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([SessionBucket].self, from: data)
            sessions = decoded.sorted(by: { $0.startTime > $1.startTime })
            pruneSessionsIfNeeded()
            let now = Date()
            activeSession = sessions.first(where: { now.timeIntervalSince($0.endTime) <= inactivityTimeout })
        } catch {
            sessions = []
            activeSession = nil
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[SessionTracker] Failed to save sessions: \(error.localizedDescription)")
        }
    }
}
