import Foundation

struct CandleDebugState {
    let lastConfidence: Double
    let lastReasons: [String]
    let lastRejectedReason: String?
}

final class CandleGate: @unchecked Sendable {
    struct FrameHit {
        let ts: Date
        let decision: CandleDetectionDecision
        let candle: CandleObject?
    }

    private(set) var lastDecision: CandleDetectionDecision?
    private(set) var lastDebugState: CandleDebugState?

    private var window: [FrameHit] = []
    private var lastLock: (time: Date, candle: CandleObject)?

    private let detector: CandleChartDetector
    private let extractor: CandleChartExtractor

    private let windowSeconds: TimeInterval = 2.0
    private let minHits: Int = 3
    private let minAvgConfidence: Double = 0.65
    private let cooldownSeconds: TimeInterval = 7.0

    init(detector: CandleChartDetector = CandleChartDetector(),
         extractor: CandleChartExtractor = CandleChartExtractor()) {
        self.detector = detector
        self.extractor = extractor
    }

    func ingest(_ ocr: OcrResult) -> CandleObject? {
        let decision = detector.detect(ocrResult: ocr)
        lastDecision = decision

        let candle = decision.isCandleChart ? extractor.extract(ocrResult: ocr, decision: decision) : nil
        let now = Date()
        window.append(FrameHit(ts: now, decision: decision, candle: candle))
        trimWindow(now: now)

        let rejectedReason = decision.isCandleChart ? nil : (decision.reasons.contains("no_text") ? "no_text" : "below_threshold")
        lastDebugState = CandleDebugState(
            lastConfidence: decision.confidence,
            lastReasons: decision.reasons,
            lastRejectedReason: rejectedReason
        )

        guard decision.isCandleChart else { return nil }

        let hits = window.filter { $0.decision.isCandleChart }
        guard hits.count >= minHits else { return nil }

        let avgConfidence = hits.map { $0.decision.confidence }.reduce(0, +) / Double(hits.count)
        guard avgConfidence >= minAvgConfidence else { return nil }

        let tickerMode = mode(of: hits.compactMap { $0.decision.signals.ticker })
        let timeframeMode = mode(of: hits.compactMap { $0.decision.signals.timeframe })
        let stableTicker = isStable(modeValue: tickerMode, hits: hits) { $0.decision.signals.ticker }
        let stableTimeframe = isStable(modeValue: timeframeMode, hits: hits) { $0.decision.signals.timeframe }

        guard stableTicker || (tickerMode == nil && stableTimeframe) else { return nil }
        guard let recentCandle = hits.last?.candle else { return nil }

        let stabilized = CandleObject(
            id: UUID(),
            timestamp: recentCandle.timestamp,
            ticker: tickerMode ?? recentCandle.ticker,
            timeframe: timeframeMode ?? recentCandle.timeframe,
            sourceApp: recentCandle.sourceApp,
            rangeStart: recentCandle.rangeStart,
            rangeEnd: recentCandle.rangeEnd,
            visibleTimeStart: recentCandle.visibleTimeStart,
            visibleTimeEnd: recentCandle.visibleTimeEnd,
            trajectory: recentCandle.trajectory,
            confidence: avgConfidence,
            rawSnippet: recentCandle.rawSnippet
        )

        if let lastLock, now.timeIntervalSince(lastLock.time) < cooldownSeconds {
            if !isSignificantlyDifferent(new: stabilized, old: lastLock.candle) {
                return nil
            }
        }

        lastLock = (time: now, candle: stabilized)
        window.removeAll()
        return stabilized
    }

    private func trimWindow(now: Date) {
        window = window.filter { now.timeIntervalSince($0.ts) <= windowSeconds }
    }

    private func mode(of values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func isStable(modeValue: String?,
                          hits: [FrameHit],
                          value: (FrameHit) -> String?) -> Bool {
        guard let modeValue else { return false }
        let matches = hits.filter { value($0) == modeValue }.count
        return Double(matches) / Double(hits.count) >= 0.6
    }

    private func isSignificantlyDifferent(new: CandleObject, old: CandleObject) -> Bool {
        if (new.ticker ?? "") != (old.ticker ?? "") { return true }
        if (new.timeframe ?? "") != (old.timeframe ?? "") { return true }

        if let newStart = new.rangeStart, let oldStart = old.rangeStart,
           let newEnd = new.rangeEnd, let oldEnd = old.rangeEnd {
            let startDelta = abs(newStart - oldStart) / max(oldStart, 1)
            let endDelta = abs(newEnd - oldEnd) / max(oldEnd, 1)
            return startDelta > 0.01 || endDelta > 0.01
        }

        return false
    }
}
