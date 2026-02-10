import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct SessionDetailView: View {
    let session: CDSession

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    Text("Start: \(session.startAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                    if let end = session.endAt {
                        Text("End: \(end.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("End: —")
                    }
                    Text("Total Extractions: \(session.candlesArray.count)")
                    if !session.topSymbols.isEmpty {
                        Text("Top Symbols: \(session.topSymbols.prefix(4).joined(separator: ", "))")
                    }
                }

                Section("Candles") {
                    ForEach(session.candlesArray.reversed(), id: \.objectID) { candle in
                        NavigationLink {
                            CandleDetailView(candle: candle)
                        } label: {
                            CandleRow(candle: candle)
                        }
                    }
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct CandleRow: View {
    let candle: CDCandleObject

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = thumbnailImage {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 36)
                    .clipped()
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 54, height: 36)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(candle.displaySymbol)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(candle.timestampCaptured?.formatted(date: .omitted, time: .shortened) ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("TF: \(candle.displayTimeframe) • Trend: \(candle.trendRaw ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Range: \(candle.displayRangeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnailImage: Image? {
        guard let path = candle.thumbnailRef, let uiImage = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: uiImage)
    }
}
