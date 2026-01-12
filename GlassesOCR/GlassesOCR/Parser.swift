//
//  Parser.swift
//  GlassesOCR
//
//  Extracts stock ticker, price, and change from OCR text.
//

import Foundation

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

// MARK: - Parser

final class Parser: Sendable {
    
    // MARK: - Regex Patterns
    
    // Ticker: 1-5 uppercase letters, optionally with a dot and more letters (e.g., BRK.B)
    private let tickerPattern = #"\b([A-Z]{1,5}(?:\.[A-Z]{1,2})?)\b"#
    
    // Price: optional $, digits with optional decimal (e.g., $185.42, 185.42, 1,234.56)
    private let pricePattern = #"\$?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"#
    
    // Change: +/- followed by number and optional % (e.g., +1.25%, -0.5%, +2.30)
    private let changePattern = #"([+\-−])\s*(\d+(?:\.\d{1,2})?)\s*%?"#
    
    // Direction words/arrows that might appear as text
    private let upIndicators = ["UP", "▲", "△", "↑", "GAIN", "GREEN"]
    private let downIndicators = ["DOWN", "▼", "▽", "↓", "LOSS", "RED"]
    
    // MARK: - Public Interface
    
    /// Parses OCR text to extract stock observation data.
    /// Returns nil if required fields (ticker + price) cannot be extracted.
    func parse(ocrResult: OcrResult) -> StockObservation? {
        let text = ocrResult.recognizedText
        
        guard !text.isEmpty else { return nil }
        
        // Extract components
        guard let ticker = extractTicker(from: text) else { return nil }
        guard let price = extractPrice(from: text) else { return nil }
        
        let change = extractChange(from: text)
        
        // Create snippet for debugging (first 50 chars)
        let snippet = String(text.prefix(80))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        
        return StockObservation(
            ticker: ticker,
            price: price,
            change: change ?? "N/A",
            confidence: ocrResult.confidence,
            rawSnippet: snippet
        )
    }
    
    // MARK: - Extraction Methods
    
    private func extractTicker(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: tickerPattern, options: []) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        // Find the first valid ticker (filter out common false positives)
        let excludedWords: Set<String> = [
            "THE", "AND", "FOR", "ARE", "BUT", "NOT", "YOU", "ALL",
            "CAN", "HER", "WAS", "ONE", "OUR", "OUT", "DAY", "GET",
            "HAS", "HIM", "HIS", "HOW", "ITS", "MAY", "NEW", "NOW",
            "OLD", "SEE", "WAY", "WHO", "BOY", "DID", "USD", "EUR",
            "GBP", "JPY", "NYSE", "NASDAQ", "DOW", "USA", "CEO", "CFO"
        ]
        
        for match in matches {
            if let matchRange = Range(match.range(at: 1), in: text) {
                let ticker = String(text[matchRange])
                if !excludedWords.contains(ticker) && ticker.count >= 1 {
                    return ticker
                }
            }
        }
        
        return nil
    }
    
    private func extractPrice(from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pricePattern, options: []) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            if let matchRange = Range(match.range(at: 1), in: text) {
                var priceStr = String(text[matchRange])
                // Remove commas for parsing
                priceStr = priceStr.replacingOccurrences(of: ",", with: "")
                
                if let price = Double(priceStr), price > 0 && price < 1_000_000 {
                    return price
                }
            }
        }
        
        return nil
    }
    
    private func extractChange(from text: String) -> String? {
        // Try regex pattern first
        if let regex = try? NSRegularExpression(pattern: changePattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                if let signRange = Range(match.range(at: 1), in: text),
                   let numRange = Range(match.range(at: 2), in: text) {
                    var sign = String(text[signRange])
                    let num = String(text[numRange])
                    
                    // Normalize minus sign variants
                    if sign == "−" { sign = "-" }
                    
                    // Check if % was part of the match (look ahead in text)
                    let afterMatch = text[numRange.upperBound...]
                    let hasPercent = afterMatch.hasPrefix("%")
                    
                    return "\(sign)\(num)\(hasPercent ? "%" : "")"
                }
            }
        }
        
        // Fall back to directional indicators
        let upperText = text.uppercased()
        
        for indicator in upIndicators {
            if upperText.contains(indicator) {
                return "↑ (up)"
            }
        }
        
        for indicator in downIndicators {
            if upperText.contains(indicator) {
                return "↓ (down)"
            }
        }
        
        return nil
    }
}

