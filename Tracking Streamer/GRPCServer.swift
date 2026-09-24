import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import QuartzCore

/// Manages the gRPC server for hand tracking using grpc-swift-2
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@MainActor
final class GRPCServerManager: ObservableObject {
    static let shared = GRPCServerManager()

    private var serverTask: Task<Void, Never>?
    private var isStopping = false
    private var restartAfterStop = false
    private var currentPort = 12345

    private init() {}

    func startServer(port: Int = 12345) {
        guard serverTask == nil else {
            if isStopping {
                restartAfterStop = true
            }
            return
        }
        currentPort = port
        DataManager.shared.grpcServerReady = false

        serverTask = Task {
            defer {
                DataManager.shared.grpcServerReady = false
                serverTask = nil
                isStopping = false
                if restartAfterStop {
                    restartAfterStop = false
                    startServer(port: currentPort)
                }
            }
            guard !Task.isCancelled else { return }

            let transport = HTTP2ServerTransport.Posix(
                address: .ipv4(host: "0.0.0.0", port: port),
                transportSecurity: .plaintext
            )
            let server = GRPCServer(
                transport: transport,
                services: [HandTrackingServiceImpl()]
            )

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await server.serve()
                    }
                    let address = try await transport.listeningAddress
                    try Task.checkCancellation()
                    DataManager.shared.grpcServerReady = true
                    dlog("🚀 gRPC server listening on \(address)")
                    try await group.waitForAll()
                }
            } catch {
                if !Task.isCancelled {
                    dlog("❌ gRPC server ended: \(error)")
                }
            }
            dlog("🛑 gRPC server stopped")
        }
    }

    func stopServer() {
        restartAfterStop = false
        DataManager.shared.grpcServerReady = false
        guard let serverTask else { return }
        isStopping = true
        // Cancelling also ends streaming RPCs, so resume can rebind the same port.
        serverTask.cancel()
    }
}

/// Hand tracking service implementation using grpc-swift-2 SimpleServiceProtocol
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct HandTrackingServiceImpl: Handtracking_HandTrackingService.SimpleServiceProtocol {
    
    init() {
        dlog("🎯 HandTrackingServiceImpl initialized")
    }
    
    func streamHandUpdates(
        request: Handtracking_HandUpdate,
        response: GRPCCore.RPCWriter<Handtracking_HandUpdate>,
        context: GRPCCore.ServerContext
    ) async throws {
        dlog("📥 [DEBUG] streamHandUpdates called - client connected!")
        
        // Track if this is a WebRTC info-only connection (will close immediately)
        let isWebRTCInfoOnly = request.head.m00 == 999.0
        
        // Check if this is a special "discovery" message from Python
        // Python will send a message with Head.m00 = 888.0 to announce its presence
        if request.head.m00 == 888.0 {
            dlog("✨ [DEBUG] Discovery message detected!")
            let ip1 = Int(request.head.m01)
            let ip2 = Int(request.head.m02)
            let ip3 = Int(request.head.m03)
            let ip4 = Int(request.head.m10)
            let pythonIP = "\(ip1).\(ip2).\(ip3).\(ip4)"
            let versionCode = Int(request.head.m30)  // Library version (0 if old library)
            dlog("🔍 Python client discovered at: \(pythonIP), version code: \(versionCode)")
            dlog("💾 [DEBUG] Storing Python IP and version in DataManager...")
            await MainActor.run {
                DataManager.shared.pythonClientIP = pythonIP
                DataManager.shared.pythonLibraryVersionCode = versionCode
                if versionCode > 0 && versionCode < DataManager.minimumPythonVersionCode {
                    dlog("⚠️ [VERSION] Python library version \(versionCode) is older than minimum required \(DataManager.minimumPythonVersionCode)")
                } else if versionCode == 0 {
                    dlog("⚠️ [VERSION] Python library does not report version (likely < 2.2.2)")
                }
            }
        } else if isWebRTCInfoOnly {
            // WebRTC server info message
            dlog("🎞️ [DEBUG] WebRTC server info message detected (info-only connection)!")
            let ip1 = Int(request.head.m01)
            let ip2 = Int(request.head.m02)
            let ip3 = Int(request.head.m03)
            let ip4 = Int(request.head.m10)
            let port = Int(request.head.m11)
            let stereoVideo = request.head.m12 > 0.5
            let stereoAudio = request.head.m13 > 0.5
            let audioEnabled = request.head.m20 > 0.5
            let videoEnabled = request.head.m21 > 0.5
            let simEnabled = request.head.m22 > 0.5
            let meshEnabled = request.head.m23 > 0.5
            let versionCode = Int(request.head.m30)  // Library version (0 if old library)
            let host = "\(ip1).\(ip2).\(ip3).\(ip4)"
            dlog("🎞️ WebRTC server available at: \(host):\(port) (video=\(videoEnabled), audio=\(audioEnabled), sim=\(simEnabled), mesh=\(meshEnabled), version=\(versionCode))")
            dlog("💾 [DEBUG] Storing WebRTC info in DataManager...")
            
            await MainActor.run {
                // Update version if provided (WebRTC info may come after discovery)
                if versionCode > 0 {
                    DataManager.shared.pythonLibraryVersionCode = versionCode
                }
                let hadConnection = DataManager.shared.webrtcServerInfo != nil
                DataManager.shared.webrtcServerInfo = (host: host, port: port)
                DataManager.shared.stereoEnabled = stereoVideo
                DataManager.shared.stereoAudioEnabled = stereoAudio
                DataManager.shared.audioEnabled = audioEnabled
                DataManager.shared.videoEnabled = videoEnabled
                DataManager.shared.simEnabled = simEnabled
                if DataManager.shared.webrtcGeneration < 0 || !hadConnection {
                    DataManager.shared.webrtcGeneration = 1
                } else {
                    DataManager.shared.webrtcGeneration += 1
                }  
                dlog("🔄 [DEBUG] Set WebRTC generation to \(DataManager.shared.webrtcGeneration)")
            }
            
            // Send one response and return for info-only connections
            let update = await fill_handUpdate()
            try await response.write(update)
            return
        } else if request.head.m00 == 778.0 {
            // Python calibration mode signal
            dlog("🎯 [DEBUG] Calibration mode signal detected!")
            await MainActor.run {
                DataManager.shared.pythonCalibrationActive = true
                DataManager.shared.pythonCalibrationStep = Int(request.head.m01)
                DataManager.shared.pythonCalibrationSamplesCollected = Int(request.head.m02)
                DataManager.shared.pythonCalibrationSamplesNeeded = Int(request.head.m03)
                DataManager.shared.pythonCalibrationTargetMarker = Int(request.head.m10)
                DataManager.shared.pythonCalibrationMarkerDetected = request.head.m11 > 0.5
                DataManager.shared.pythonCalibrationProgress = request.head.m12 / 100.0
                DataManager.shared.pythonCalibrationStepStatus = Int(request.head.m13)
            }
            // Send response and return for calibration status messages
            let update = await fill_handUpdate()
            try await response.write(update)
            return
        } else {
            dlog("⚠️ [DEBUG] Not a special message (expected m00=888.0, 999.0, or 778.0, got \(request.head.m00))")
        }
        
        // Register for benchmark events
        if !isWebRTCInfoOnly {
            BenchmarkEventDispatcher.shared.register(responseWriter: response)
        }
        
        // Check version compatibility - block streaming if incompatible
        let versionCode = Int(request.head.m30)
        let isVersionCompatible = versionCode >= DataManager.minimumPythonVersionCode
        
        if !isVersionCompatible {
            dlog("🚫 [VERSION] Blocking hand tracking stream - Python library version \(versionCode) is below minimum \(DataManager.minimumPythonVersionCode)")
            dlog("🚫 [VERSION] User must upgrade: pip install --upgrade avp-stream")
            
            // Keep connection alive but don't send useful hand tracking data
            // Periodically write empty updates to detect when client disconnects
            while !Task.isCancelled {
                do {
                    // Send an empty update (all zeros) - this allows us to detect disconnection
                    // The Python side will receive this but it won't contain valid tracking data
                    try await response.write(Handtracking_HandUpdate())
                    try await Task.sleep(nanoseconds: 500_000_000)  // Check every 0.5 seconds
                } catch {
                    dlog("🔌 [VERSION] Client disconnected while blocked: \(error)")
                    break
                }
            }
            
            // Cleanup on disconnect (same as normal disconnect)
            dlog("🧹 [VERSION] Cleaning up after blocked client disconnect")
            await MainActor.run {
                DataManager.shared.pythonClientIP = nil
                DataManager.shared.pythonLibraryVersionCode = 0
                DataManager.shared.webrtcServerInfo = nil
                DataManager.shared.webrtcGeneration = -1
            }
            return
        }
        
        dlog("🔄 [DEBUG] Starting hand tracking data stream...")
        dlog("⏱️ [DEBUG] Starting hand tracking updates...")

        var updateCount = 0
        
        // create a stream that buffers only newest item
        let handPoseStream = AsyncStream(Handtracking_HandUpdate.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            
            // generator
            let task = Task {
                while !Task.isCancelled {
                    let update = await fill_handUpdate()
                    updateCount += 1
                    continuation.yield(update)
                    
                    // Stream at approximately 200Hz (5ms delay)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                continuation.finish()
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        
        // sample the latest frame from the stream
        for await handUpdate in handPoseStream {
            do {
                try await response.write(handUpdate)
            } catch {
                dlog("🔌 [DEBUG] Client disconnected or error writing: \(error)")
                break
            }
        }
        
        dlog("🔌 [DEBUG] Stream ended. Sent \(updateCount) updates.")
        
        // Cleanup on disconnect
        if !isWebRTCInfoOnly {
            BenchmarkEventDispatcher.shared.clear()
            
            await MainActor.run {
                dlog("🧹 [DEBUG] Cleaning up connection state after main client disconnect")
                DataManager.shared.pythonClientIP = nil
                DataManager.shared.pythonLibraryVersionCode = 0  // Reset version on disconnect
                DataManager.shared.webrtcServerInfo = nil
                DataManager.shared.webrtcGeneration = -1
                DataManager.shared.pythonCalibrationActive = false  // Reset calibration state
            }
        }
    }
}
