import Foundation
import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let primaryContainer = NSPersistentContainer(name: "Model")

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            primaryContainer.persistentStoreDescriptions = [description]
        } else {
            let description = primaryContainer.persistentStoreDescriptions.first
            description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

        var loadError: Error?
        primaryContainer.loadPersistentStores { _, error in
            if let error = error {
                loadError = error
            }
        }

        var resolvedContainer = primaryContainer
        var didFallbackToMemory = false

        if let error = loadError {
            print("[PersistenceController] Failed to load store: \(error)")
            if !inMemory {
                let fallback = NSPersistentContainer(name: "Model")
                let description = NSPersistentStoreDescription()
                description.type = NSInMemoryStoreType
                fallback.persistentStoreDescriptions = [description]

                fallback.loadPersistentStores { _, error in
                    if let error = error {
                        print("[PersistenceController] In-memory fallback failed: \(error)")
                    }
                }
                resolvedContainer = fallback
                didFallbackToMemory = true
            }
        }

        resolvedContainer.viewContext.automaticallyMergesChangesFromParent = true
        resolvedContainer.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        container = resolvedContainer

        if !inMemory && !didFallbackToMemory {
            migrateLegacySessionsIfNeeded(context: resolvedContainer.viewContext)
        }
    }

    private func migrateLegacySessionsIfNeeded(context: NSManagedObjectContext) {
        let defaultsKey = "didMigrateLegacySessions"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let legacyURL = docs.appendingPathComponent("candle_sessions.json")

        guard let data = try? Data(contentsOf: legacyURL) else {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            return
        }

        do {
            let sessions = try JSONDecoder().decode([SessionBucket].self, from: data)
            for session in sessions {
                let cdSession = CDSession(context: context)
                cdSession.id = session.id
                cdSession.startAt = session.startTime
                cdSession.endAt = session.endTime
                cdSession.lastActiveAt = session.endTime
                cdSession.candleCount = Int32(session.candles.count)

                for candle in session.candles {
                    let cdCandle = CDCandleObject(context: context)
                    cdCandle.id = candle.id
                    cdCandle.timestampCaptured = candle.timestamp
                    cdCandle.updatedAt = candle.timestamp
                    cdCandle.dedupKey = "legacy-\(candle.id.uuidString)"
                    cdCandle.symbol = candle.ticker
                    cdCandle.timeframeRaw = candle.timeframe
                    cdCandle.sourceAppHintRaw = candle.sourceApp
                    cdCandle.visiblePriceMin = candle.rangeStart ?? 0
                    cdCandle.visiblePriceMax = candle.rangeEnd ?? 0
                    cdCandle.visibleTimeStart = candle.visibleTimeStart
                    cdCandle.visibleTimeEnd = candle.visibleTimeEnd
                    cdCandle.visibleDateStart = candle.visibleDateStart
                    cdCandle.visibleDateEnd = candle.visibleDateEnd
                    cdCandle.trendRaw = candle.trajectory.rawValue
                    cdCandle.slopeMetric = candle.slopeMetric ?? 0
                    cdCandle.confidence = candle.confidence
                    cdCandle.rawOcrHeader = candle.rawOcrHeader
                    cdCandle.rawOcrYAxis = candle.rawOcrYAxis
                    cdCandle.rawOcrFooter = candle.rawOcrFooter
                    cdCandle.debugJSON = candle.debugJSON
                    cdCandle.thumbnailRef = nil
                    cdCandle.session = cdSession
                }
            }

            if context.hasChanges {
                try context.save()
            }

            try FileManager.default.removeItem(at: legacyURL)
            UserDefaults.standard.set(true, forKey: defaultsKey)
        } catch {
            print("[PersistenceController] Legacy migration failed: \(error)")
        }
    }
}

// MARK: - Core Data Convenience

extension CDSession {
    var candlesArray: [CDCandleObject] {
        let set = candles as? Set<CDCandleObject> ?? []
        return set.sorted {
            ($0.timestampCaptured ?? .distantPast) < ($1.timestampCaptured ?? .distantPast)
        }
    }

    var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        guard let startAt else { return "Unknown" }
        if let end = endAt {
            return "\(formatter.string(from: startAt)) – \(formatter.string(from: end))"
        }
        return formatter.string(from: startAt)
    }

    var topSymbols: [String] {
        let symbols = candlesArray.compactMap { $0.symbol?.uppercased() }
        guard !symbols.isEmpty else { return [] }
        let counts = symbols.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { $0.key }
    }

    var isActive: Bool {
        guard let lastActiveAt else { return false }
        return Date().timeIntervalSince(lastActiveAt) < 5 * 60
    }
}

extension CDCandleObject {
    var displaySymbol: String { symbol ?? "Unknown" }

    var displayTimeframe: String { timeframeRaw ?? "—" }

    var displayRangeText: String {
        let minVal = visiblePriceMin
        let maxVal = visiblePriceMax
        if minVal == 0 && maxVal == 0 { return "Unknown" }
        return String(format: "%.2f – %.2f", minVal, maxVal)
    }
}
