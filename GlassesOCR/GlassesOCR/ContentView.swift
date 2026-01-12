//
//  ContentView.swift
//  GlassesOCR
//
//  Main UI for controlling glasses stream, OCR, and Sheets logging.
//

import SwiftUI
import CoreVideo

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    
    // MARK: Dependencies
    
    let glassesManager = GlassesManager()
    
    // 🔹 Make these nonisolated so they can be safely accessed from tasks
    nonisolated let ocrPipeline = OcrPipeline()
    nonisolated let parser = Parser()
    nonisolated let sheetsClient = SheetsClient()
    
    // MARK: Published State
    
    @Published var isDryRun: Bool = true
    @Published var isRunning: Bool = false
    @Published var lastObservation: StockObservation?
    @Published var lastLogResult: String = "—"
    @Published var frameCount: Int = 0
    
    // MARK: Private
    
    private var frameProcessingTask: Task<Void, Never>?
    private var lastFrameTime: Date = .distantPast
    
    /// Minimum interval between processed frames (in seconds)
    static let frameIntervalSeconds: TimeInterval = 3.0
    
    // MARK: - Computed Properties
    
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
    
    var errorMessage: String? {
        glassesManager.errorMessage
    }
    
    // MARK: - Actions
    
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastLogResult = "Starting…"
        
        // Connect if needed
        if glassesManager.connectionState != .connected && glassesManager.connectionState != .registered {
            await glassesManager.connect()
        }
        
        // Start streaming
        if glassesManager.connectionState == .connected || glassesManager.connectionState == .registered {
            await glassesManager.startStreaming()
            lastLogResult = "Waiting for data…"
            
            // Start frame processing loop
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
    
    // MARK: - Frame Processing
    
    private func startFrameProcessing() {
        frameProcessingTask?.cancel()
        frameProcessingTask = Task { [weak self] in
            guard let self = self else { return }
            
            for await buffer in self.glassesManager.frameStream {
                guard !Task.isCancelled else { break }
                guard !Task.isCancelled else { break }
                
                // Throttle frames
                let now = Date()
                guard now.timeIntervalSince(self.lastFrameTime) >= Self.frameIntervalSeconds else { continue }
                self.lastFrameTime = now
                
                // Capture buffer immediately to avoid data race
                nonisolated(unsafe) let capturedBuffer = buffer

                // Process frame immediately in this context to avoid data race
                // Increment frame count on main actor
                await MainActor.run {
                    self.incrementFrameCount()
                }
                let currentCount = self.frameCount

                // Run OCR (nonisolated)
                let ocrResult = await self.ocrPipeline.recognizeText(in: capturedBuffer)
                print("🔍 OCR detected: '\(ocrResult.recognizedText)'")
                print("🔍 OCR confidence: \(ocrResult.confidence)")
                print("🔍 OCR char count: \(ocrResult.recognizedText.count)")
                
                guard !ocrResult.recognizedText.isEmpty else {
                    print("[AppState] Frame \(currentCount): No text detected")
                    continue
                }
                
                print("[AppState] Frame \(currentCount): OCR found \(ocrResult.recognizedText.count) chars")
                
                // Parse stock data (nonisolated)
                guard let observation = self.parser.parse(ocrResult: ocrResult) else {
                    print("[AppState] Frame \(currentCount): No stock data found in text")
                    await MainActor.run {
                        self.updateLogResult("No stock data found")
                    }
                    continue
                }
                
                // Update observation on main actor
                await MainActor.run {
                    self.updateObservation(observation)
                }
                
                // Log to Sheets (nonisolated)
                let dryRun = await self.isDryRun
                let result = await self.sheetsClient.log(observation, dryRun: dryRun)
                
                // Update result on main actor
                await MainActor.run {
                    switch result {
                    case .success:
                        self.updateLogResult("✅ Logged to Sheets")
                    case .dryRun:
                        self.updateLogResult("📋 Dry run logged")
                    case .error(let message):
                        self.updateLogResult("❌ \(message)")
                    }
                }
            }
        }
    }
    
    // 🔹 Helper methods to update @Published properties on main actor
    private func incrementFrameCount() {
        frameCount += 1
    }
    
    private func updateObservation(_ observation: StockObservation) {
        lastObservation = observation
    }
    
    private func updateLogResult(_ result: String) {
        lastLogResult = result
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Status Section
                statusSection
                
                // Last Observation
                observationSection
                
                Spacer()
                
                // Controls
                controlsSection
            }
            .padding()
            .navigationTitle("GlassesOCR")
        }
    }
    
    // MARK: - Status Section
    
    private var statusSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Connection", systemImage: "glasses")
                Spacer()
                Text(appState.connectionStatus)
                    .foregroundStyle(connectionColor)
                    .fontWeight(.medium)
            }
            
            HStack {
                Label("Stream", systemImage: "video")
                Spacer()
                Text(appState.streamingStatus)
                    .foregroundStyle(streamColor)
                    .fontWeight(.medium)
            }
            
            HStack {
                Label("Frames", systemImage: "photo.stack")
                Spacer()
                Text("\(appState.frameCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            if let error = appState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Observation Section
    
    private var observationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last Extraction")
                .font(.headline)
            
            if let obs = appState.lastObservation {
                VStack(spacing: 8) {
                    dataRow(label: "Ticker", value: obs.ticker, icon: "chart.line.uptrend.xyaxis")
                    dataRow(label: "Price", value: String(format: "$%.2f", obs.price), icon: "dollarsign.circle")
                    dataRow(label: "Change", value: obs.change, icon: "arrow.up.arrow.down")
                    dataRow(label: "Confidence", value: String(format: "%.0f%%", obs.confidence * 100), icon: "checkmark.seal")
                }
            } else {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
            
            Divider()
            
            HStack {
                Text("Log Status:")
                    .foregroundStyle(.secondary)
                Text(appState.lastLogResult)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func dataRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
    
    // MARK: - Controls Section
    
    private var controlsSection: some View {
        VStack(spacing: 16) {
            // Dry Run Toggle
            Toggle(isOn: $appState.isDryRun) {
                VStack(alignment: .leading) {
                    Text("Dry Run Mode")
                        .fontWeight(.medium)
                    Text("Print to console instead of sending to Sheets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            
            // Start/Stop Button
            Button {
                Task {
                    if appState.isRunning {
                        await appState.stop()
                    } else {
                        await appState.start()
                    }
                }
            } label: {
                Label(
                    appState.isRunning ? "Stop" : "Start",
                    systemImage: appState.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isRunning ? .red : .green)
        }
    }
    
    // MARK: - Helpers
    
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
}

#Preview {
    ContentView()
}
