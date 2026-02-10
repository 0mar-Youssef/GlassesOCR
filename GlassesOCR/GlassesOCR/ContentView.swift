//
//  ContentView.swift
//  GlassesOCR
//
//  Main UI for controlling glasses stream, OCR, and extraction logging.
//

import SwiftUI
import CoreVideo
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App State

@MainActor
final class AppState: ObservableObject {

    // MARK: Dependencies

    let glassesManager = GlassesManager()
    let sessionTracker = SessionTracker()

    nonisolated let ocrPipeline = OcrPipeline()
    nonisolated let parser = Parser()
    nonisolated let sheetsClient = SheetsClient()
    nonisolated let candleDetector = CandleChartDetector()
    nonisolated let candleExtractor = CandleChartExtractor()
    nonisolated let candleGate = CandleGate()
    nonisolated let visualGate = VisualChartGate()
    nonisolated let cropPlanner = CropPlanner()
    nonisolated let adapterRegistry = AdapterRegistry()

    // MARK: Published State

    @Published var isDryRun: Bool = true
    @Published var isRunning: Bool = false
    @Published var lastObservation: StockObservation?
    @Published var lastCandleObject: CandleObject?
    @Published var lastCandleTimestamp: Date?
    @Published var lastLogResult: String = "—"
    @Published var frameCount: Int = 0
    @Published var chartConfidence: Double = 0
    @Published var isCandleChartInView: Bool = false
    @Published var chartReason: String = ""
    @Published var frameIntervalSeconds: Double = 1.0
    @Published var debugOverlayEnabled: Bool = false
    @Published var debugPreviewImage: UIImage?
    @Published var debugChartBox: CGRect?
    @Published var debugCropPlan: CropPlan?
    @Published var debugGateSignals: String = ""

    var activeSession: CDSession? { sessionTracker.activeSession }

    // MARK: Private

    private var frameProcessingTask: Task<Void, Never>?

    // MARK: Computed Properties

    var connectionStatus: String {
        switch glassesManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .registered: return "Registered"
        }
    }

    var streamingStatus: String {
        switch glassesManager.streamingState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .streaming: return "Streaming"
        case .error: return "Error"
        }
    }

    var errorMessage: String? { glassesManager.errorMessage }

    // MARK: Actions

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastLogResult = "Starting…"

        if glassesManager.connectionState != .connected && glassesManager.connectionState != .registered {
            await glassesManager.connect()
        }

        if glassesManager.connectionState != .connected && glassesManager.connectionState != .registered {
            lastLogResult = "Waiting for registration approval…"
            let ready = await glassesManager.waitForRegistration(timeout: 30)
            if !ready {
                lastLogResult = "Registration not completed"
                isRunning = false
                return
            }
        }

        await glassesManager.startStreaming()
        if glassesManager.streamingState == .error {
            lastLogResult = "Streaming failed"
            isRunning = false
            return
        }
        lastLogResult = "Scanning for chart…"
        startFrameProcessing()
    }

    func stop() async {
        isRunning = false
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        await glassesManager.stopStreaming()
        lastLogResult = "Stopped"
    }

    // MARK: Frame processing
    private func startFrameProcessing() {
        frameProcessingTask?.cancel()
        frameProcessingTask = Task { [weak self] in
            guard let self = self else { return }

            let stabilizer = ChartStabilizer()
            var lastGateResult: ChartGateResult?
            var lastFrameTime = Date.distantPast
            var lastGateTime = Date.distantPast
            var lastOcrTime = Date.distantPast
            let gateInterval: TimeInterval = 1.0 / 6.0
            let ocrCooldown: TimeInterval = 2.5

            for await buffer in self.glassesManager.frameStream {
                guard !Task.isCancelled else { break }

                let now = Date()
                let interval = await MainActor.run { self.frameIntervalSeconds }
                let shouldProcess = now.timeIntervalSince(lastFrameTime) >= interval
                if shouldProcess { lastFrameTime = now }
                guard shouldProcess else { continue }
                guard let snapshot = FrameSnapshot(pixelBuffer: buffer, capturedAt: now) else { continue }

                await MainActor.run { self.frameCount += 1 }

                if now.timeIntervalSince(lastGateTime) >= gateInterval || lastGateResult == nil {
                    let rawGate = await self.visualGate.evaluate(snapshot: snapshot)
                    let stabilized = stabilizer.stabilize(result: rawGate)
                    lastGateResult = stabilized
                    lastGateTime = now

                    let signalsText = stabilized.signals
                        .map { "\($0.key):\(String(format: "%.2f", $0.value))" }
                        .sorted()
                        .joined(separator: " ")

                    await MainActor.run {
                        self.chartConfidence = stabilized.confidence
                        self.isCandleChartInView = stabilized.isChart
                        self.chartReason = "[gate] conf=\(String(format: "%.2f", stabilized.confidence))"
                        self.debugGateSignals = signalsText
                        if self.debugOverlayEnabled {
                            self.debugPreviewImage = snapshot.midResUIImage()
                            self.debugChartBox = stabilized.chartBox
                        }
                    }

                    await MainActor.run {
                        self.sessionTracker.observeGate(confidence: stabilized.confidence, isChart: stabilized.isChart, at: now)
                    }
                }

                guard let gateResult = lastGateResult, gateResult.isChart else {
                    await self.candleGate.reset()
                    await MainActor.run { self.lastLogResult = "No chart detected (gate)" }
                    continue
                }

                guard now.timeIntervalSince(lastOcrTime) >= ocrCooldown else { continue }
                lastOcrTime = now

                var cropPlan = self.cropPlanner.plan(
                    chartBox: gateResult.chartBox,
                    axisSide: gateResult.axisSide,
                    frameSize: CGSize(width: snapshot.width, height: snapshot.height)
                )

                var regionBundle = await self.ocrPipeline.recognizeRegions(in: snapshot, cropPlan: cropPlan)
                var activeAdapter: PlatformAdapter?

                if let detected = self.adapterRegistry.detect(
                    headerText: regionBundle.header.recognizedText,
                    fullText: regionBundle.combinedText
                ), detected.confidence >= 0.7 {
                    cropPlan = detected.adapter.refineCropPlan(
                        base: cropPlan,
                        frameSize: CGSize(width: snapshot.width, height: snapshot.height)
                    )
                    regionBundle = await self.ocrPipeline.recognizeRegions(in: snapshot, cropPlan: cropPlan)
                    activeAdapter = detected.adapter
                }

                let debugEnabled = await MainActor.run { self.debugOverlayEnabled }
                if debugEnabled {
                    await MainActor.run { self.debugCropPlan = cropPlan }
                }

                let detection = self.candleDetector.detect(regions: regionBundle, gateConfidence: gateResult.confidence)
                await MainActor.run {
                    self.chartConfidence = detection.confidence
                    self.isCandleChartInView = detection.isCandleChart
                    self.chartReason = detection.reason
                }

                guard detection.isCandleChart, let context = detection.context else {
                    await self.candleGate.reset()
                    await MainActor.run { self.lastLogResult = "No chart detected (OCR)" }
                    continue
                }

                let extraction = self.candleExtractor.extract(
                    from: context,
                    cropPlan: cropPlan,
                    snapshot: snapshot,
                    confidence: detection.confidence,
                    adapter: activeAdapter
                )
                if let candle = extraction.candle {
                    let gateDecision = await self.candleGate.process(candle)
                    await MainActor.run { self.chartReason = gateDecision.reason }
                    if gateDecision.status == .accepted, let gated = gateDecision.candle {
                        let thumbnailData = snapshot.thumbnailJPEG(normalizedRect: cropPlan.bodyRect)
                        await MainActor.run {
                            self.lastCandleObject = gated
                            self.lastCandleTimestamp = gated.timestamp
                            self.sessionTracker.record(gated, chartBox: gateResult.chartBox, thumbnailData: thumbnailData)
                        }
                    } else {
                        await MainActor.run { self.lastLogResult = gateDecision.reason }
                    }
                } else {
                    await MainActor.run { self.lastLogResult = extraction.reason }
                }

                let syntheticOcr = OcrResult(
                    recognizedText: regionBundle.combinedText,
                    confidence: regionBundle.averageConfidence,
                    observations: []
                )

                if let observation = self.parser.parse(ocrResult: syntheticOcr) {
                    await MainActor.run { self.lastObservation = observation }

                    let isDryRun = await MainActor.run { self.isDryRun }
                    let result = await self.sheetsClient.log(observation, dryRun: isDryRun)
                    await MainActor.run {
                        switch result {
                        case .success:
                            self.lastLogResult = "✅ Chart extraction logged"
                        case .dryRun:
                            self.lastLogResult = "📋 Chart extraction ready (dry run)"
                        case .error(let message):
                            self.lastLogResult = "❌ \(message)"
                        }
                    }
                } else {
                    await MainActor.run { self.lastLogResult = "Chart detected; ticker/price still uncertain" }
                }
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var appState = AppState()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CDSession.startAt, ascending: false)],
        animation: .default
    ) private var sessions: FetchedResults<CDSession>

    @State private var selectedSession: CDSession?
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Live Status") {
                    statusRow(label: "Connection", value: appState.connectionStatus, tint: connectionColor)
                    statusRow(label: "Stream", value: appState.streamingStatus, tint: streamColor)
                    statusRow(label: "Frames", value: "\(appState.frameCount)", tint: .secondary)
                    statusRow(label: "Candlestick", value: appState.isCandleChartInView ? "Detected" : "Not in view", tint: appState.isCandleChartInView ? .green : .secondary)
                    statusRow(label: "Confidence", value: String(format: "%.0f%%", appState.chartConfidence * 100), tint: .secondary)
                    statusRow(label: "Sampling", value: formatInterval(appState.frameIntervalSeconds), tint: .secondary)
                    if let lastSeen = appState.lastCandleTimestamp {
                        statusRow(label: "Last Candle", value: formatClock(lastSeen), tint: .secondary)
                    }
                    if !appState.chartReason.isEmpty {
                        Text(appState.chartReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = appState.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Toggle("Debug Overlay", isOn: $appState.debugOverlayEnabled)
                        .toggleStyle(.switch)

                    if appState.debugOverlayEnabled {
                        DebugOverlayView(
                            image: appState.debugPreviewImage,
                            chartBox: appState.debugChartBox,
                            cropPlan: appState.debugCropPlan
                        )
                        .frame(height: 180)

                        if !appState.debugGateSignals.isEmpty {
                            Text(appState.debugGateSignals)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Last Extraction") {
                    if let candle = appState.lastCandleObject {
                        statusRow(label: "Ticker", value: candle.ticker ?? "Unknown", tint: .primary)
                        statusRow(label: "Timeframe", value: candle.timeframe ?? "Unknown", tint: .primary)
                        statusRow(label: "App", value: candle.sourceApp ?? "Unknown", tint: .secondary)
                        statusRow(label: "Price Range", value: formatPriceRange(candle), tint: .primary)
                        statusRow(label: "Time Range", value: formatTimeRange(candle), tint: .secondary)
                        statusRow(label: "Date Range", value: formatDateRange(candle), tint: .secondary)
                        statusRow(label: "Trajectory", value: candle.trajectory.rawValue.capitalized, tint: .primary)
                    } else {
                        Text("No candle extraction yet")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Log")
                        Spacer()
                        Text(appState.lastLogResult)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                if groupedSessions.isEmpty {
                    Section("History") {
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groupedSessions, id: \.day) { group in
                        Section(group.title) {
                            ForEach(group.sessions, id: \.objectID) { session in
                                Button {
                                    selectedSession = session
                                } label: {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Controls") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sampling Interval")
                        Picker("Sampling Interval", selection: $appState.frameIntervalSeconds) {
                            Text("0.5s").tag(0.5)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle(isOn: $appState.isDryRun) {
                        VStack(alignment: .leading) {
                            Text("Dry Run Mode")
                            Text("Only preview logs without sending to Sheets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            if appState.isRunning {
                                await appState.stop()
                            } else {
                                await appState.start()
                            }
                        }
                    } label: {
                        Label(appState.isRunning ? "Stop" : "Start", systemImage: appState.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.isRunning ? .red : .green)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("GlassesOCR")
            .searchable(text: $searchText, prompt: "Search ticker")
            .sheet(item: $selectedSession) { session in
                SessionDetailView(session: session)
            }
        }
    }

    private func statusRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(tint)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }

    private var connectionColor: Color {
        switch appState.glassesManager.connectionState {
        case .connected, .registered: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var streamColor: Color {
        switch appState.glassesManager.streamingState {
        case .streaming: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    private func formatPriceRange(_ candle: CandleObject) -> String {
        guard let start = candle.rangeStart, let end = candle.rangeEnd else { return "Unknown" }
        return String(format: "%.2f - %.2f", start, end)
    }

    private func formatTimeRange(_ candle: CandleObject) -> String {
        if let start = candle.visibleTimeStart, let end = candle.visibleTimeEnd { return "\(start) → \(end)" }
        if let start = candle.visibleTimeStart { return start }
        return "Unknown"
    }

    private func formatDateRange(_ candle: CandleObject) -> String {
        if let start = candle.visibleDateStart, let end = candle.visibleDateEnd { return "\(start) → \(end)" }
        if let start = candle.visibleDateStart { return start }
        return "Unknown"
    }

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatInterval(_ value: Double) -> String {
        let fps = value > 0 ? Int(round(1.0 / value)) : 0
        return String(format: "%.1fs (~%d fps)", value, fps)
    }

    private var filteredSessions: [CDSession] {
        let allSessions = Array(sessions)
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return allSessions
        }
        let query = searchText.lowercased()
        return allSessions.filter { session in
            session.candlesArray.contains { candle in
                (candle.symbol ?? "").lowercased().contains(query)
            }
        }
    }

    private var groupedSessions: [(day: Date, title: String, sessions: [CDSession])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredSessions) { session in
            calendar.startOfDay(for: session.startAt ?? Date.distantPast)
        }
        let sortedDays = grouped.keys.sorted(by: >)
        return sortedDays.map { day in
            let title = formatDay(day)
            let sessions = grouped[day]?.sorted {
                ($0.startAt ?? Date.distantPast) > ($1.startAt ?? Date.distantPast)
            } ?? []
            return (day: day, title: title, sessions: sessions)
        }
    }

    private func formatDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct SessionRow: View {
    let session: CDSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.timeRangeText)
                        .fontWeight(.semibold)
                    if session.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                }

                if !session.topSymbols.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(session.topSymbols.prefix(3), id: \.self) { symbol in
                            Text(symbol)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                        }
                    }
                }

                Text("\(session.candlesArray.count) candles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
}
