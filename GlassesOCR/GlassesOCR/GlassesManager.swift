import Foundation
import MWDATCore
import MWDATCamera
import CoreVideo
import AVFoundation
import CoreMedia

@MainActor
class GlassesManager: ObservableObject {

    @Published var connectionState: ConnectionState = .disconnected
    @Published var streamingState: StreamingState = .stopped
    @Published var errorMessage: String? = nil

    // CORRECT TYPE: Wearables.shared returns `any WearablesInterface`, not `Wearables`
    // Use lazy to defer access until after Wearables.configure() has been called
    private lazy var wearables: any WearablesInterface = Wearables.shared
    
    private var streamSession: StreamSession?
    private var stateListenerToken: AnyListenerToken?
    private var frameListenerToken: AnyListenerToken?
    
    // Frame stream
    // Frame stream - initialize immediately, not lazily
    private var frameContinuation: AsyncStream<CVPixelBuffer>.Continuation?
    private(set) var frameStream: AsyncStream<CVPixelBuffer>!
    
    // Registration observer task
    private var registrationObserverTask: Task<Void, Never>?

    enum ConnectionState {
        case disconnected, connecting, connected, registered
    }

    enum StreamingState {
        case stopped, starting, streaming, error
    }
    
    // MARK: - Initialization
    
    init() {
        // Initialize frame stream immediately
        self.frameStream = AsyncStream { [weak self] continuation in
            self?.frameContinuation = continuation
        }
        
        // Start observing registration state as soon as the manager is created
        startObservingRegistration()
    }
    
    deinit {
        registrationObserverTask?.cancel()
    }
    
    // MARK: - Registration Observer (Long-Lived)
    
    /// Starts a long-lived task that observes registration state changes.
    /// This should run for the lifetime of the GlassesManager.
    /// Starts a long-lived task that observes registration state changes.
    /// This should run for the lifetime of the GlassesManager.
    private func startObservingRegistration() {
        registrationObserverTask = Task { [weak self] in
            guard let self = self else { return }

            // This loop runs FOREVER, reacting to state changes
            for await state in self.wearables.registrationStateStream() {
                guard !Task.isCancelled else { break }

                print("[GlassesManager] 📡 Registration state changed: \(state)")

                // Update connection state based on registration state
                await MainActor.run {
                    let rawValue = self.registrationRawValue(from: state)
                    print("[GlassesManager] 🔍 Registration raw value: \(rawValue.map(String.init) ?? "unknown")")

                    if let rawValue {
                        switch rawValue {
                        case 3:
                            self.connectionState = .registered
                            self.errorMessage = nil
                            print("[GlassesManager] ✅ Registration complete (rawValue: 3)")
                        case 0:
                            if self.connectionState != .connecting {
                                self.connectionState = .disconnected
                                print("[GlassesManager] 📵 Not registered (rawValue: 0)")
                            }
                        case 1, 2:
                            self.connectionState = .connecting
                            print("[GlassesManager] ⏳ Registration in progress (rawValue: 1 or 2)")
                        default:
                            print("[GlassesManager] ⚠️ Unknown state: \(String(describing: state))")
                        }
                    } else {
                        let stateString = String(describing: state)
                        if stateString.contains("rawValue: 3") {
                            self.connectionState = .registered
                            self.errorMessage = nil
                            print("[GlassesManager] ✅ Registration complete (rawValue: 3)")
                        } else if stateString.contains("rawValue: 0") {
                            if self.connectionState != .connecting {
                                self.connectionState = .disconnected
                                print("[GlassesManager] 📵 Not registered (rawValue: 0)")
                            }
                        } else if stateString.contains("rawValue: 1") || stateString.contains("rawValue: 2") {
                            self.connectionState = .connecting
                            print("[GlassesManager] ⏳ Registration in progress (rawValue: 1 or 2)")
                        } else {
                            print("[GlassesManager] ⚠️ Unknown state: \(stateString)")
                        }
                    }
                }
            }
        }
    }

    func waitForRegistration(timeout: TimeInterval) async -> Bool {
        if connectionState == .registered || connectionState == .connected {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if connectionState == .registered || connectionState == .connected {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return connectionState == .registered || connectionState == .connected
    }

    private func registrationRawValue(from state: Any) -> Int? {
        let mirror = Mirror(reflecting: state)
        for child in mirror.children where child.label == "rawValue" {
            switch child.value {
            case let value as Int:
                return value
            case let value as Int8:
                return Int(value)
            case let value as Int16:
                return Int(value)
            case let value as Int32:
                return Int(value)
            case let value as Int64:
                return Int(value)
            case let value as UInt:
                return Int(value)
            case let value as UInt8:
                return Int(value)
            case let value as UInt16:
                return Int(value)
            case let value as UInt32:
                return Int(value)
            case let value as UInt64:
                return Int(value)
            default:
                return nil
            }
        }
        return nil
    }
    func connect() async {
        print("[GlassesManager] 🚀 Checking registration status...")
        
        // Give the observer a moment to update connectionState
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Check if already registered by getting current state
        // The observer will have already processed any state changes
        if connectionState == .registered {
            print("[GlassesManager] ✅ Already registered, no action needed")
            return
        }
        
        connectionState = .connecting
        errorMessage = nil
        
        print("[GlassesManager] 📱 Starting registration...")

        do {
            // Simply trigger registration - the observer handles the rest
            try wearables.startRegistration()
            print("[GlassesManager] 📱 Registration request sent. Check Meta View app for approval.")
        } catch {
            errorMessage = "Failed to start registration: \(error.localizedDescription)"
            connectionState = .disconnected
            print("[GlassesManager] ❌ Registration error: \(error)")
        }
    }
    
    func startStreaming() async {
        streamingState = .starting
        errorMessage = nil

        do {
            // Check camera permission first
            let cameraStatus = try await wearables.checkPermissionStatus(.camera)
            print("[GlassesManager] 📷 Camera permission status: \(cameraStatus)")
            
            if cameraStatus != .granted {
                print("[GlassesManager] 📷 Requesting camera permission...")
                let newStatus = try await wearables.requestPermission(.camera)
                print("[GlassesManager] 📷 Camera permission after request: \(newStatus)")
                
                if newStatus != .granted {
                    errorMessage = "Camera permission denied"
                    streamingState = .error
                    return
                }
            }
            
            // AutoDeviceSelector expects WearablesInterface
            let deviceSelector = AutoDeviceSelector(wearables: wearables)

            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .medium,  // or .high
                frameRate: 15  // lower framerate = more bandwidth for quality
            )

            let session = StreamSession(
                streamSessionConfig: config,
                deviceSelector: deviceSelector
            )

            self.streamSession = session

            // Listen to state updates with explicit type annotation
            stateListenerToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
                guard let self = self else { return }
                Task { @MainActor in
                    print("[GlassesManager] 📺 Stream state: \(state)")
                    
                    switch state {
                    case .streaming:
                        self.streamingState = .streaming
                        print("[GlassesManager] ✅ Streaming active")
                        
                    case .starting:
                        self.streamingState = .starting
                        print("[GlassesManager] 🔄 Stream starting...")
                        
                    case .stopped, .stopping:
                        self.streamingState = .stopped
                        print("[GlassesManager] ⏹️ Stream stopped")
                        
                    case .waitingForDevice:
                        self.streamingState = .starting
                        print("[GlassesManager] ⏳ Waiting for device")
                        
                    case .paused:
                        self.streamingState = .stopped
                        print("[GlassesManager] ⏸️ Stream paused")
                        
                    @unknown default:
                        // Log unknown states but don't treat as error
                        print("[GlassesManager] ⚠️ Unknown stream state: \(state)")
                        // Keep current state instead of setting error
                    }
                }
            }

            // Capture continuation for use in closure
            let continuation = self.frameContinuation
            
            // Listen to frame updates and yield to frameStream
            frameListenerToken = session.videoFramePublisher.listen { (frame: VideoFrame) in
                
                
                // Get the sample buffer from the frame
                let sampleBuffer = frame.sampleBuffer
                
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    print("[GlassesManager] ⚠️ Could not get image buffer from sample buffer")
                    return
                }
                
                // Yield to continuation
                continuation?.yield(pixelBuffer)
            }
            await session.start()
        } catch {
            errorMessage = "Streaming failed: \(error)"
            streamingState = .error
        }
    }

    func stopStreaming() async {
        await streamSession?.stop()
        stateListenerToken = nil
        frameListenerToken = nil
        streamSession = nil
        streamingState = .stopped
    }
}
