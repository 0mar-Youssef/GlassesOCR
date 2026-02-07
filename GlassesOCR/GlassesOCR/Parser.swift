//
//  Parser.swift
//  GlassesOCR
//
//  Extracts stock and candlestick chart observations from OCR text.
//

import Foundation
import Vision

// MARK: - Stock Observation

struct StockObservation: Codable, Identifiable {
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

enum Trajectory: String, Codable {
    case up
    case down
    case flat
    case volatile
    case unknown
}

struct CandleObject: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let ticker: String?
    let timeframe: String?
    let sourceApp: String?
    let rangeStart: Double?
    let rangeEnd: Double?
    let visibleTimeStart: String?
    let visibleTimeEnd: String?
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
        self.trajectory = trajectory
        self.confidence = confidence
        self.rawSnippet = rawSnippet
    }
}

struct SessionBucket: Identifiable, Codable {
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

// MARK: - Parser

final class Parser: Sendable {
     //Hi

    // MARK: - Regex Patterns
    // Allow single-letter tickers (e.g., "F", "C") while still supporting dotted suffixes.
    private let tickerPattern = #"\b([A-Z]{1,8}(?:\.[A-Z]{1,2})?)\b"#
    private let pricePattern = #"\$?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,4})?|\d+(?:\.\d{1,4})?)"#
    private let changePattern = #"([+\-−])\s*(\d+(?:\.\d{1,2})?)\s*%?"#
    private let timeframePattern = #"\b(1m|3m|5m|10m|15m|30m|45m|1h|2h|4h|6h|8h|12h|1d|3d|1w)\b"#
    private let timeLabelPattern = #"\b(?:[01]?\d|2[0-3]):[0-5]\d\b"#

    private let upIndicators = ["UP", "▲", "△", "↑", "GAIN", "GREEN", "BULL"]
    private let downIndicators = ["DOWN", "▼", "▽", "↓", "LOSS", "RED", "BEAR"]
    private let volatileIndicators = ["VOLATILE", "CHOP", "SPIKE", "WHIPSAW"]
    private let chartKeywords = ["OPEN", "HIGH", "LOW", "CLOSE", "OHLC", "VOLUME", "CHART", "CANDLE", "INDICATOR"]

    private let excludedWords: Set<String> = [
        "USD", "EUR", "GBP", "JPY",
        "NYSE", "NASDAQ", "DOW",
        "OPEN", "HIGH", "LOW", "CLOSE", "OHLC",
        "VOL", "VOLUME", "CHART", "TIME", "CANDLE", "INDICATOR"
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
        let detector = CandleChartDetector()
        let extractor = CandleChartExtractor()
        let decision = detector.detect(ocrResult: ocrResult)
        let candle = decision.isCandleChart ? extractor.extract(ocrResult: ocrResult, decision: decision) : nil
        let reason = decision.reasons.isEmpty ? "No chart signals" : decision.reasons.joined(separator: ", ")
        return ChartExtractionResult(
            isCandleChart: decision.isCandleChart,
            confidence: decision.confidence,
            candle: candle,
            reason: decision.isCandleChart ? "Detected" : reason
        )
    }

    // MARK: - Region split

    private struct RegionText {
        let header: String
        let footer: String
        let leftAxis: String
        let rightAxis: String
    }

    private func splitIntoRegions(ocrResult: OcrResult) -> RegionText {
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

    private func extractTicker(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: tickerPattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[matchRange]).uppercased()
            if isTimeframeToken(token) { continue }
            if excludedWords.contains(token) { continue }
            if token.count == 1 {
                return token
            }
            if !excludedWords.contains(token) {
                return token
            }
        }
        return nil
    }

    private func extractPrice(from text: String) -> Double? {
        extractAllPrices(from: text).first
    }

    private func extractAllPrices(from text: String) -> [Double] {
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

    private func inferVisibleRange(from prices: [Double]) -> ClosedRange<Double>? {
        guard let minimum = prices.min(), let maximum = prices.max() else { return nil }
        return minimum...maximum
    }

    private func extractTimeframe(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: timeframePattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).lowercased()
    }

    private func extractTimeLabels(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: timeLabelPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let labels = regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range(at: 0), in: text).map { String(text[$0]) }
        }
        return Array(NSOrderedSet(array: labels)) as? [String] ?? labels
    }

    private func extractTrajectory(from text: String) -> Trajectory {
        if upIndicators.contains(where: { text.contains($0) }) { return .up }
        if downIndicators.contains(where: { text.contains($0) }) { return .down }
        if volatileIndicators.contains(where: { text.contains($0) }) { return .volatile }
        if text.contains("SIDEWAYS") || text.contains("RANGE") { return .flat }
        return .unknown
    }

    private func extractChange(from text: String) -> String? {
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

    private func isTimeframeToken(_ token: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: timeframePattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(token.startIndex..., in: token)
        guard let match = regex.firstMatch(in: token, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }
}

// MARK: - Session Tracker

@MainActor
final class SessionTracker: ObservableObject {
    @Published private(set) var sessions: [SessionBucket] = []
    @Published private(set) var activeSession: SessionBucket?

    private let inactivityTimeout: TimeInterval = 5 * 60
    private let dedupInterval: TimeInterval = 12
    private let maxCandlesPerSession: Int = 200
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
                current.candles[current.candles.count - 1] = merge(last: last, incoming: candle)
            } else {
                current.candles.append(candle)
            }

            if current.candles.count > maxCandlesPerSession {
                current.candles.removeFirst(current.candles.count - maxCandlesPerSession)
            }

            activeSession = current
            upsertSession(current)
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
        saveToDisk()
    }

    private func shouldDeduplicate(last: CandleObject, incoming: CandleObject, at now: Date) -> Bool {
        let sameTicker = (last.ticker ?? "") == (incoming.ticker ?? "")
        let sameTimeframe = (last.timeframe ?? "") == (incoming.timeframe ?? "")
        let tooSoon = now.timeIntervalSince(last.timestamp) < dedupInterval
        return sameTicker && sameTimeframe && tooSoon
    }

    private func merge(last: CandleObject, incoming: CandleObject) -> CandleObject {
        let useIncomingRange = incoming.confidence >= last.confidence
        return CandleObject(
            id: incoming.id,
            timestamp: incoming.timestamp,
            ticker: incoming.ticker ?? last.ticker,
            timeframe: incoming.timeframe ?? last.timeframe,
            sourceApp: nil,
            rangeStart: useIncomingRange ? incoming.rangeStart : last.rangeStart,
            rangeEnd: useIncomingRange ? incoming.rangeEnd : last.rangeEnd,
            visibleTimeStart: incoming.visibleTimeStart ?? last.visibleTimeStart,
            visibleTimeEnd: incoming.visibleTimeEnd ?? last.visibleTimeEnd,
            trajectory: incoming.trajectory,
            confidence: max(last.confidence, incoming.confidence),
            rawSnippet: incoming.rawSnippet
        )
    }

    private func upsertSession(_ session: SessionBucket) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([SessionBucket].self, from: data)
            sessions = decoded.sorted(by: { $0.startTime > $1.startTime })
            activeSession = sessions.first(where: { Date().timeIntervalSince($0.endTime) <= inactivityTimeout })
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
