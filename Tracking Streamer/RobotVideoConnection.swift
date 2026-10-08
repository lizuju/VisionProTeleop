import Combine
import CoreVideo
import Foundation
import QuartzCore
import Security
@preconcurrency import LiveKitWebRTC

struct RobotVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let decodedAt: TimeInterval
    let sequence: UInt64
    let streamID: UInt64
    let width: Int
    let height: Int
    let rotationDegrees: Int
    let timing: RobotVideoTiming
}

struct RobotVideoReconnectBackoff {
    private struct FreshPeriod {
        let epoch: String
        let startedAt: TimeInterval
        let sourceStartedAt: TimeInterval
        var sequence: UInt64
        var sourceAt: TimeInterval
        var advancedAt: TimeInterval
    }

    private(set) var consecutiveFailures = 0
    private var freshPeriod: FreshPeriod?

    mutating func failed() -> TimeInterval {
        consecutiveFailures += 1
        freshPeriod = nil
        return min(Double(consecutiveFailures), 5)
    }

    mutating func observe(_ timing: RobotVideoTiming?, at now: TimeInterval) {
        guard consecutiveFailures > 0 else { return }
        guard let timing, timing.isFresh(at: now), timing.sourceMappedAt <= now else {
            freshPeriod = nil
            return
        }
        if var period = freshPeriod, period.epoch == timing.sourceEpoch {
            // Re-reading one fresh snapshot does not establish recovery.
            if timing.sourceSequence == period.sequence, timing.sourceMappedAt == period.sourceAt,
               now - period.advancedAt <= 0.5 { return }
            guard timing.sourceSequence > period.sequence, timing.sourceMappedAt > period.sourceAt else {
                freshPeriod = nil
                return
            }
            if now - period.advancedAt <= 0.5, timing.sourceMappedAt - period.sourceAt <= 0.5 {
                period.sequence = timing.sourceSequence
                period.sourceAt = timing.sourceMappedAt
                period.advancedAt = now
                if now - period.startedAt >= 2, timing.sourceMappedAt - period.sourceStartedAt >= 2 {
                    consecutiveFailures = 0
                    freshPeriod = nil
                } else {
                    freshPeriod = period
                }
                return
            }
        }
        freshPeriod = FreshPeriod(epoch: timing.sourceEpoch, startedAt: now,
                                  sourceStartedAt: timing.sourceMappedAt, sequence: timing.sourceSequence,
                                  sourceAt: timing.sourceMappedAt, advancedAt: now)
    }
}

@MainActor
final class RobotVideoConnection: ObservableObject {
    static let freshThreshold: TimeInterval = 0.5

    @Published private(set) var status = "未连接机器人视频"
    @Published private(set) var decodedFPS = 0.0
    @Published private(set) var frameWidth = 0
    @Published private(set) var frameHeight = 0
    @Published private(set) var reconnectCount = 0
    @Published private(set) var lastFrameAge: TimeInterval?
    @Published private(set) var isFresh = false
    @Published private(set) var sourceAgeMs: Double?
    @Published private(set) var uncertaintyMs: Double?
    @Published private(set) var duplicateFrames: UInt64 = 0
    @Published private(set) var unmatchedFrames: UInt64 = 0
    @Published private(set) var timingStatus = "等待源帧时间信息"

    private let factory: LKRTCPeerConnectionFactory
    private var connectionTask: Task<Void, Never>?
    private var peerConnection: LKRTCPeerConnection?
    private var receiver: RobotVideoReceiver?
    private var signalingSession: URLSession?
    private var generation: UInt64 = 0
    private var frameEpoch: UInt64 = 0

    init() {
        LKRTCInitializeSSL()
        factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory()
        )
    }

    static func hostIsValid(_ input: String) -> Bool {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { return false }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            return labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        }
        return true
    }

    func start(host input: String) {
        stop()
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.hostIsValid(host) else {
            status = "请输入 Ubuntu 的 IP 或主机名，不含端口和网址前缀"
            return
        }
        guard let caURL = Bundle.main.url(forResource: "RobotVideoRootCA", withExtension: "der"),
              let caData = try? Data(contentsOf: caURL),
              let rootCA = SecCertificateCreateWithData(nil, caData as CFData) else {
            status = "App 缺少机器人视频 CA 证书"
            return
        }
        reconnectCount = 0
        let currentGeneration = generation
        connectionTask = Task { [weak self] in
            await self?.run(host: host, rootCA: rootCA, generation: currentGeneration)
        }
    }

    func stop() {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        closeConnection()
        status = "未连接机器人视频"
        decodedFPS = 0
        frameWidth = 0
        frameHeight = 0
        duplicateFrames = 0
        unmatchedFrames = 0
    }

    func takeLatestFrame() -> RobotVideoFrame? {
        guard let frame = receiver?.buffer.takeLatest(),
              frame.timing.isFresh(at: CACurrentMediaTime()) else { return nil }
        return frame
    }

    func isStreamActive(_ streamID: UInt64) -> Bool {
        guard let receiver, receiver.streamID == streamID else { return false }
        return receiver.buffer.isActive()
    }

    private func closeConnection() {
        receiver?.invalidate()
        receiver = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        signalingSession?.invalidateAndCancel()
        signalingSession = nil
        isFresh = false
        lastFrameAge = nil
        sourceAgeMs = nil
        uncertaintyMs = nil
        timingStatus = "等待源帧时间信息"
    }

    private func run(host: String, rootCA: SecCertificate, generation expected: UInt64) async {
        var reconnectBackoff = RobotVideoReconnectBackoff()
        while !Task.isCancelled, generation == expected {
            do {
                status = reconnectCount == 0 ? "正在连接机器人视频…" : "正在重新连接机器人视频…"
                try await connect(host: host, rootCA: rootCA, generation: expected)
                try checkCurrent(expected)
                let connectedAt = CACurrentMediaTime()
                var measuredAt = connectedAt
                var measuredFrames: UInt64 = 0
                while !Task.isCancelled {
                    try checkCurrent(expected)
                    receiver?.sendClockPing()
                    guard let snapshot = receiver?.buffer.snapshot() else { throw CancellationError() }
                    let now = CACurrentMediaTime()
                    lastFrameAge = snapshot.decodedAt.map { max(0, now - $0) }
                    isFresh = snapshot.timing.map { $0.isFresh(at: now) } ?? false
                    sourceAgeMs = snapshot.timing.map { max(0, now - $0.sourceMappedAt) * 1000 }
                    uncertaintyMs = snapshot.timing.map { $0.uncertainty * 1000 }
                    duplicateFrames = snapshot.duplicateFrames
                    unmatchedFrames = snapshot.unmatchedFrames
                    timingStatus = snapshot.timingStatus
                    frameWidth = snapshot.width
                    frameHeight = snapshot.height
                    if let failure = snapshot.failure { throw RobotVideoError.message(failure) }
                    reconnectBackoff.observe(snapshot.timing, at: now)
                    status = isFresh ? "机器人视频已连接" : (snapshot.decodedAt == nil ? "已连接，等待机器人画面…" : "机器人视频暂未更新")
                    if now - measuredAt >= 1 {
                        decodedFPS = Double(snapshot.decodedFrames - measuredFrames) / (now - measuredAt)
                        measuredAt = now
                        measuredFrames = snapshot.decodedFrames
                        let age = lastFrameAge.map { String(format: "%.0f", $0 * 1000) } ?? "none"
                        print("[R1Video] source_age_ms=\(sourceAgeMs.map { String(format: "%.0f", $0) } ?? "unknown") uncertainty_ms=\(uncertaintyMs.map { String(format: "%.1f", $0) } ?? "unknown") duplicate=\(duplicateFrames) unmatched=\(unmatchedFrames) decoded_fps=\(String(format: "%.1f", decodedFPS)) size=\(frameWidth)x\(frameHeight) decoded_age_ms=\(age) decoded=\(snapshot.decodedFrames) replaced=\(snapshot.replacedFrames) reconnects=\(reconnectCount)")
                    }
                    if now - (snapshot.decodedAt ?? connectedAt) > 3 {
                        throw RobotVideoError.message("机器人视频超过 3 秒未更新")
                    }
                    if now - (snapshot.timing?.sourceMappedAt ?? connectedAt) > 3 {
                        throw RobotVideoError.message("机器人源帧时间超过 3 秒未更新")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                guard generation == expected, !Task.isCancelled else { return }
                closeConnection()
                decodedFPS = 0
                status = "\(error.localizedDescription)，正在重连…"
                reconnectCount += 1
                let retryDelay = reconnectBackoff.failed()
                print("[R1Video] reconnect reason=\(error.localizedDescription) retry_delay_s=\(retryDelay) consecutive_failures=\(reconnectBackoff.consecutiveFailures) reconnects=\(reconnectCount)")
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch { return }
            }
        }
    }

    private func checkCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func connect(host: String, rootCA: SecCertificate, generation expected: UInt64) async throws {
        frameEpoch &+= 1
        let receiver = RobotVideoReceiver(sequenceBase: frameEpoch << 32)
        self.receiver = receiver
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.tcpCandidatePolicy = .disabled
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: receiver) else {
            throw RobotVideoError.message("无法创建视频连接")
        }
        peerConnection = pc
        let metadataConfig = LKRTCDataChannelConfiguration()
        metadataConfig.isOrdered = false
        metadataConfig.maxRetransmits = 0
        guard let metadataChannel = pc.dataChannel(forLabel: "r1-video-meta-v1", configuration: metadataConfig) else {
            throw RobotVideoError.message("无法创建视频时间信息通道")
        }
        receiver.attach(metadataChannel)
        let transceiverInit = LKRTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        guard let transceiver = pc.addTransceiver(of: .video, init: transceiverInit) else {
            throw RobotVideoError.message("无法创建视频接收通道")
        }
        let h264 = factory.rtpReceiverCapabilities(forKind: "video").codecs.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264.isEmpty else { throw RobotVideoError.message("此设备没有 H.264 解码器") }
        try transceiver.setCodecPreferences(h264, error: ())

        let offerSDP = try await RobotVideoCallback<String>().value { complete in
            pc.offer(for: constraints) { offer, error in
                if let error { complete(.failure(error)) }
                else if let offer { complete(.success(offer.sdp)) }
                else { complete(.failure(RobotVideoError.message("视频协商未返回 SDP"))) }
            }
        }
        try checkCurrent(expected)
        try await RobotVideoCallback<Void>().value { complete in
            pc.setLocalDescription(LKRTCSessionDescription(type: .offer, sdp: offerSDP)) { error in
                if let error { complete(.failure(error)) }
                else { complete(.success(())) }
            }
        }
        try checkCurrent(expected)
        let gatheringDeadline = CACurrentMediaTime() + 5
        while pc.iceGatheringState != .complete {
            try checkCurrent(expected)
            guard CACurrentMediaTime() < gatheringDeadline else { throw RobotVideoError.message("局域网视频地址收集超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let localSDP = pc.localDescription?.sdp else { throw RobotVideoError.message("视频协商缺少本地 SDP") }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = 60001
        components.path = "/offer"
        guard let url = components.url else { throw RobotVideoError.message("视频主机地址无效") }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 12
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig, delegate: RobotVideoTrust(host: host, rootCA: rootCA), delegateQueue: nil)
        signalingSession = session
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RobotVideoOffer(sdp: localSDP, type: "offer", codec: "h264"))
        let (data, response) = try await session.data(for: request)
        try checkCurrent(expected)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw RobotVideoError.message("机器人视频服务返回错误")
        }
        let answer = try JSONDecoder().decode(RobotVideoAnswer.self, from: data)
        guard answer.type == "answer", !answer.sdp.isEmpty else { throw RobotVideoError.message("机器人视频服务返回无效 SDP") }
        try await RobotVideoCallback<Void>().value { complete in
            pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer.sdp)) { error in
                if let error { complete(.failure(error)) }
                else { complete(.success(())) }
            }
        }
        try checkCurrent(expected)
        session.finishTasksAndInvalidate()
        signalingSession = nil
    }
}

private final class RobotVideoCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    @MainActor
    func value(_ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                start { [self] result in finish(result) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct RobotVideoOffer: Encodable {
    let sdp: String
    let type: String
    let codec: String
    let video_metadata = "r1-video-meta-v1"
}

private struct RobotVideoAnswer: Decodable {
    let sdp: String
    let type: String
}

private enum RobotVideoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

final class RobotVideoTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let rootCA: SecCertificate

    init(host: String, rootCA: SecCertificate) {
        self.host = host
        self.rootCA = rootCA
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Add this deployment's CA while retaining certificate validity and SSL hostname checks.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [rootCA] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class RobotVideoBuffer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    struct Snapshot {
        let decodedAt: TimeInterval?
        let width: Int
        let height: Int
        let decodedFrames: UInt64
        let replacedFrames: UInt64
        let failure: String?
        let timing: RobotVideoTiming?
        let duplicateFrames: UInt64
        let unmatchedFrames: UInt64
        let timingStatus: String
    }
    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let decodedAt: TimeInterval
        let sequence: UInt64
        let width: Int
        let height: Int
        let rtp: UInt32
    }

    private let lock = NSLock()
    private let sequenceBase: UInt64
    private var active = true
    private var latest: RobotVideoFrame?
    private var pending: PendingFrame?
    private var timing = RobotVideoTimingState()
    private var decodedAt: TimeInterval?
    private var width = 0
    private var height = 0
    private var decodedFrames: UInt64 = 0
    private var replacedFrames: UInt64 = 0
    private var unmatchedFrames: UInt64 = 0
    private var failure: String?

    init(sequenceBase: UInt64) { self.sequenceBase = sequenceBase }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        guard let cvBuffer = frame.buffer as? LKRTCCVPixelBuffer else {
            failure = "视频解码器未提供 GPU 像素缓冲"
            return
        }
        guard frame.rotation.rawValue == 0,
              !cvBuffer.requiresCropping(),
              !cvBuffer.requiresScaling(toWidth: frame.width, height: frame.height) else {
            failure = "机器人视频包含不支持的旋转或裁剪"
            return
        }
        width = Int(frame.width)
        height = Int(frame.height)
        decodedFrames &+= 1
        if pending != nil { unmatchedFrames &+= 1 }
        decodedAt = now
        pending = PendingFrame(pixelBuffer: cvBuffer.pixelBuffer, decodedAt: now,
                               sequence: sequenceBase + decodedFrames, width: width, height: height,
                               rtp: UInt32(bitPattern: frame.timeStamp))
        matchPending(at: now)
    }

    func receiveMetadata(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let now = CACurrentMediaTime()
        timing.receive(data, at: now)
        matchPending(at: now)
    }

    func clockPing() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return active ? timing.ping(at: CACurrentMediaTime()) : nil
    }

    private func matchPending(at now: TimeInterval) {
        guard let pending else { return }
        switch timing.match(rtp: pending.rtp, at: now) {
        case .ready(let matched):
            if latest != nil { replacedFrames &+= 1 }
            latest = RobotVideoFrame(pixelBuffer: pending.pixelBuffer, decodedAt: pending.decodedAt,
                                     sequence: pending.sequence, streamID: sequenceBase >> 32,
                                     width: pending.width, height: pending.height,
                                     rotationDegrees: 0, timing: matched)
            self.pending = nil
        case .duplicate:
            self.pending = nil
        case .unavailable:
            if now - pending.decodedAt > 0.5 { self.pending = nil; unmatchedFrames &+= 1 }
        }
    }

    func takeLatest() -> RobotVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        timing.refresh(at: now)
        let frame = latest
        latest = nil
        return active && timing.latest != nil && frame?.timing.isFresh(at: now) == true ? frame : nil
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        timing.refresh(at: CACurrentMediaTime())
        return Snapshot(decodedAt: decodedAt, width: width, height: height,
                        decodedFrames: decodedFrames, replacedFrames: replacedFrames, failure: failure,
                        timing: timing.latest, duplicateFrames: timing.duplicateFrames,
                        unmatchedFrames: unmatchedFrames, timingStatus: timing.status)
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && failure == nil
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if active { failure = message }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        latest = nil
        pending = nil
        timing = RobotVideoTimingState()
        decodedAt = nil
    }
}

private final class RobotVideoReceiver: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, @unchecked Sendable {
    let buffer: RobotVideoBuffer
    let streamID: UInt64
    private let lock = NSLock()
    private var active = true
    private var tracks: [LKRTCVideoTrack] = []
    private var metadataChannel: LKRTCDataChannel?

    init(sequenceBase: UInt64) {
        streamID = sequenceBase >> 32
        buffer = RobotVideoBuffer(sequenceBase: sequenceBase)
    }

    func invalidate() {
        lock.lock()
        active = false
        buffer.invalidate()
        let removedTracks = tracks
        let removedChannel = metadataChannel
        metadataChannel = nil
        tracks.removeAll()
        lock.unlock()
        for track in removedTracks { track.remove(buffer) }
        removedChannel?.delegate = nil
        removedChannel?.close()
    }

    func attach(_ channel: LKRTCDataChannel) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { channel.close(); return }
        metadataChannel = channel
        channel.delegate = self
    }

    func sendClockPing() {
        lock.lock()
        let channel = active ? metadataChannel : nil
        lock.unlock()
        guard let channel, channel.readyState == .open, channel.bufferedAmount < 4096,
              let data = buffer.clockPing() else { return }
        _ = channel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}
    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        lock.lock()
        let isCurrent = active && dataChannel === metadataChannel
        lock.unlock()
        if isCurrent, !buffer.isBinary { self.buffer.receiveMetadata(buffer.data) }
    }

    private func receive(_ track: LKRTCMediaStreamTrack?) {
        guard let track = track as? LKRTCVideoTrack else { return }
        lock.lock()
        defer { lock.unlock() }
        guard active, !tracks.contains(where: { $0.isEqual(track) }) else { return }
        tracks.append(track)
        track.add(buffer)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        receive(transceiver.receiver.track)
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        receive(rtpReceiver.track)
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .failed || newState == .closed { buffer.fail("机器人视频连接已断开") }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        if newState == .failed || newState == .closed { buffer.fail("机器人视频网络已断开") }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        for track in stream.videoTracks { receive(track) }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) { dataChannel.close() }
}
