import Foundation
import CoreGraphics

protocol PlatformAdapter: Sendable {
    var platformName: String { get }
    func detectPlatform(headerText: String, fullText: String) -> (hint: String, confidence: Double)?
    func refineCropPlan(base: CropPlan, frameSize: CGSize) -> CropPlan
    func augmentParsing(ticker: String?, timeframe: String?, headerText: String) -> (ticker: String?, timeframe: String?)
}

struct AdapterRegistry: Sendable {
    private let adapters: [PlatformAdapter]

    init(adapters: [PlatformAdapter] = [KrakenAdapter(), CoinbaseAdapter(), TradingViewAdapter()]) {
        self.adapters = adapters
    }

    func detect(headerText: String, fullText: String) -> (adapter: PlatformAdapter, confidence: Double)? {
        var best: (PlatformAdapter, Double)?
        for adapter in adapters {
            guard let detected = adapter.detectPlatform(headerText: headerText, fullText: fullText) else { continue }
            if let current = best {
                if detected.confidence > current.1 { best = (adapter, detected.confidence) }
            } else {
                best = (adapter, detected.confidence)
            }
        }
        return best
    }
}

struct KrakenAdapter: PlatformAdapter {
    let platformName = "Kraken"

    func detectPlatform(headerText: String, fullText: String) -> (hint: String, confidence: Double)? {
        let upper = (headerText + " " + fullText).uppercased()
        if upper.contains("KRAKEN") { return ("KRAKEN", 0.9) }
        if upper.contains("XBT/") { return ("XBT/", 0.7) }
        return nil
    }

    func refineCropPlan(base: CropPlan, frameSize: CGSize) -> CropPlan {
        // Kraken header is taller
        let header = CGRect(x: base.headerRect.minX, y: max(0, base.headerRect.minY - 0.02), width: base.headerRect.width, height: min(base.headerRect.height + 0.02, 0.25))
        return CropPlan(headerRect: header, yAxisRect: base.yAxisRect, footerRect: base.footerRect, bodyRect: base.bodyRect)
    }

    func augmentParsing(ticker: String?, timeframe: String?, headerText: String) -> (ticker: String?, timeframe: String?) {
        guard let ticker = ticker else { return (ticker, timeframe) }
        let normalized = ticker.replacingOccurrences(of: "XBT", with: "BTC")
        return (normalized, timeframe)
    }
}

struct CoinbaseAdapter: PlatformAdapter {
    let platformName = "Coinbase"

    func detectPlatform(headerText: String, fullText: String) -> (hint: String, confidence: Double)? {
        let upper = (headerText + " " + fullText).uppercased()
        if upper.contains("COINBASE") { return ("COINBASE", 0.9) }
        if upper.contains("CB") { return ("CB", 0.5) }
        return nil
    }

    func refineCropPlan(base: CropPlan, frameSize: CGSize) -> CropPlan {
        // Coinbase tends to have right-side price axis, keep default
        return base
    }

    func augmentParsing(ticker: String?, timeframe: String?, headerText: String) -> (ticker: String?, timeframe: String?) {
        guard let ticker = ticker else { return (ticker, timeframe) }
        let normalized = ticker.replacingOccurrences(of: "-", with: "")
        return (normalized, timeframe)
    }
}

struct TradingViewAdapter: PlatformAdapter {
    let platformName = "TradingView"

    func detectPlatform(headerText: String, fullText: String) -> (hint: String, confidence: Double)? {
        let upper = (headerText + " " + fullText).uppercased()
        if upper.contains("TRADINGVIEW") { return ("TRADINGVIEW", 0.9) }
        if upper.contains("TV") { return ("TV", 0.5) }
        return nil
    }

    func refineCropPlan(base: CropPlan, frameSize: CGSize) -> CropPlan {
        // TradingView often has a taller header toolbar
        let header = CGRect(x: base.headerRect.minX, y: max(0, base.headerRect.minY - 0.03), width: base.headerRect.width, height: min(base.headerRect.height + 0.03, 0.28))
        return CropPlan(headerRect: header, yAxisRect: base.yAxisRect, footerRect: base.footerRect, bodyRect: base.bodyRect)
    }

    func augmentParsing(ticker: String?, timeframe: String?, headerText: String) -> (ticker: String?, timeframe: String?) {
        return (ticker, timeframe)
    }
}
