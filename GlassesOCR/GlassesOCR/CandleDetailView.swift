import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct CandleDetailView: View {
    let candle: CDCandleObject

    var body: some View {
        List {
            Section("Overview") {
                detailRow("Symbol", candle.symbol ?? "—")
                detailRow("Timeframe", candle.timeframeRaw ?? "—")
                detailRow("Source App", candle.sourceAppHintRaw ?? "—")
                detailRow("Trend", candle.trendRaw ?? "—")
                if candle.slopeMetric != 0 {
                    detailRow("Slope Metric", String(format: "%.2f", candle.slopeMetric))
                }
                detailRow("Confidence", String(format: "%.0f%%", candle.confidence * 100))
                detailRow("Captured", candle.timestampCaptured?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                detailRow("Updated", candle.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }

            Section("Ranges") {
                detailRow("Price", candle.displayRangeText)
                detailRow("Time", rangeText(candle.visibleTimeStart, candle.visibleTimeEnd))
                detailRow("Date", rangeText(candle.visibleDateStart, candle.visibleDateEnd))
            }

            if hasRawOcr {
                Section("Raw OCR") {
                    if let header = candle.rawOcrHeader, !header.isEmpty {
                        detailRow("Header", header)
                    }
                    if let yAxis = candle.rawOcrYAxis, !yAxis.isEmpty {
                        detailRow("Y-Axis", yAxis)
                    }
                    if let footer = candle.rawOcrFooter, !footer.isEmpty {
                        detailRow("Footer", footer)
                    }
                }
            }

            if let data = candle.debugJSON, let debugText = formattedJSON(data) {
                Section("Debug") {
                    Text(debugText)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            if let path = candle.thumbnailRef, let image = UIImage(contentsOfFile: path) {
                Section("Thumbnail") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(8)
                }
            }
        }
        .navigationTitle(candle.displaySymbol)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func rangeText(_ start: String?, _ end: String?) -> String {
        if let start, let end { return "\(start) → \(end)" }
        if let start { return start }
        return "—"
    }

    private func formattedJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8)
        }
        return text
    }

    private var hasRawOcr: Bool {
        let values = [candle.rawOcrHeader, candle.rawOcrYAxis, candle.rawOcrFooter]
        return values.contains { text in
            guard let text else { return false }
            return !text.isEmpty
        }
    }
}
