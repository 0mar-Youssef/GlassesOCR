//
//  ContentView.swift
//  GlassesOCR
//
//  Main UI for controlling glasses stream, OCR, and extraction logging.
//

import SwiftUI
import CoreVideo

// MARK: - App State

@MainActor
final class AppState: ObservableObject {

    // MARK: Dependencies

    let glassesManager = GlassesManager()
    let sessionTracker = SessionTracker()

    nonisolated let ocrPipeline = OcrPipeline()
    nonisolated let parser = Parser()
    nonisolated let sheetsClient = SheetsClient()
    nonisolated let candleGate = CandleGate()

    // MARK: Published State

    @Published var isDryRun: Bool = true
    @Published var isRunning: Bool = false
    @Published var lastObservation: StockObservation?
    @Published var lastCandleObject: CandleObject?
    @Published var lastLogResult: String = "—"
    @Published var frameCount: Int = 0
    @Published var chartConfidence: Double = 0
    @Published var isCandleChartInView: Bool = false
    @Published var chartReason: String = ""

    var sessions: [SessionBucket] { sessionTracker.sessions }
    var activeSession: SessionBucket? { sessionTracker.activeSession }

    // MARK: Private

    private var frameProcessingTask: Task<Void, Never>?
    private var lastFrameTime: Date = .distantPast
    static let frameIntervalSeconds: TimeInterval = 0.6

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

        if glassesManager.connectionState == .connected || glassesManager.connectionState == .registered {
            await glassesManager.startStreaming()
            lastLogResult = "Scanning for chart…"
            startFrameProcessing()
        } else {
            lastLogResult = "Connection failed"
            isRunning = false
        }
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

            for await buffer in self.glassesManager.frameStream {
                guard !Task.isCancelled else { break }

                let now = Date()
                guard now.timeIntervalSince(self.lastFrameTime) >= Self.frameIntervalSeconds else { continue }
                self.lastFrameTime = now
                nonisolated(unsafe) let capturedBuffer = buffer

                await MainActor.run { self.frameCount += 1 }

                let ocrResult = await self.ocrPipeline.recognizeText(in: capturedBuffer)
                guard !ocrResult.recognizedText.isEmpty else { continue }

                let lockedCandle = self.candleGate.ingest(ocrResult)
                let decision = self.candleGate.lastDecision
                let debug = self.candleGate.lastDebugState

                await MainActor.run {
                    self.chartConfidence = debug?.lastConfidence ?? 0
                    self.isCandleChartInView = decision?.isCandleChart ?? false
                    let reasons = debug?.lastReasons.joined(separator: ", ") ?? ""
                    if let rejected = debug?.lastRejectedReason {
                        self.chartReason = reasons.isEmpty ? "Rejected: \(rejected)" : "Rejected: \(rejected) • \(reasons)"
                    } else {
                        self.chartReason = reasons
                    }
                }

                if let candle = lockedCandle {
                    await MainActor.run {
                        self.lastCandleObject = candle
                        self.sessionTracker.record(candle)
                    }

                    if let observation = self.parser.parse(ocrResult: ocrResult) {
                        await MainActor.run {
                            self.lastObservation = observation
                        }

                        let result = await self.sheetsClient.log(observation, dryRun: await self.isDryRun)
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
                        await MainActor.run {
                            self.lastLogResult = "Chart locked; ticker/price still uncertain"
                        }
                    }
                } else if decision?.isCandleChart == true {
                    await MainActor.run {
                        self.lastLogResult = "Chart detected; stabilizing…"
                    }
                } else {
                    await MainActor.run {
                        self.lastLogResult = "No chart detected"
                    }
                }
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var selectedSession: SessionBucket?

    var body: some View {
        NavigationStack {
            List {
                Section("Live Status") {
                    statusRow(label: "Connection", value: appState.connectionStatus, tint: connectionColor)
                    statusRow(label: "Stream", value: appState.streamingStatus, tint: streamColor)
                    statusRow(label: "Frames", value: "\(appState.frameCount)", tint: .secondary)
                    statusRow(label: "Candlestick", value: appState.isCandleChartInView ? "Detected" : "Not in view", tint: appState.isCandleChartInView ? .green : .secondary)
                    statusRow(label: "Confidence", value: String(format: "%.0f%%", appState.chartConfidence * 100), tint: .secondary)
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
                }

                Section("Last Extraction") {
                    if let candle = appState.lastCandleObject {
                        statusRow(label: "Ticker", value: candle.ticker ?? "Unknown", tint: .primary)
                        statusRow(label: "Timeframe", value: candle.timeframe ?? "Unknown", tint: .primary)
                        statusRow(label: "App", value: candle.sourceApp ?? "Unknown", tint: .secondary)
                        statusRow(label: "Price Range", value: formatPriceRange(candle), tint: .primary)
                        statusRow(label: "Time Range", value: formatTimeRange(candle), tint: .secondary)
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

                Section("History") {
                    if let active = appState.activeSession {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active Session")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                            Text("\(formatClock(active.startTime)) → \(formatClock(active.endTime))")
                                .font(.caption)
                            Text("\(active.candles.count) extractions • Top: \(active.topTicker)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if appState.sessions.isEmpty {
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.sessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(formatClock(session.startTime)) → \(formatClock(session.endTime))")
                                            .fontWeight(.semibold)
                                        Text("\(session.candles.count) candles • \(session.topTicker)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Controls") {
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

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct SessionDetailView: View {
    let session: SessionBucket

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    Text("Start: \(session.startTime.formatted(date: .abbreviated, time: .shortened))")
                    Text("End: \(session.endTime.formatted(date: .abbreviated, time: .shortened))")
                    Text("Total Extractions: \(session.candles.count)")
                }

                Section("Candles") {
                    ForEach(Array(session.candles.reversed())) { candle in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(candle.ticker ?? "Unknown")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(candle.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("TF: \(candle.timeframe ?? "—") • App: \(candle.sourceApp ?? "—")")
                                .font(.caption)
                            Text("Range: \(rangeText(candle)) • Trajectory: \(candle.trajectory.rawValue.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Session History")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func rangeText(_ candle: CandleObject) -> String {
        guard let start = candle.rangeStart, let end = candle.rangeEnd else { return "Unknown" }
        return String(format: "%.2f - %.2f", start, end)
    }
}

#Preview {
    ContentView()
}
