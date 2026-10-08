import SwiftUI
import RealityKit
import RealityKitContent
import CoreImage
import Metal
import QuartzCore

@MainActor
final class RobotStereoDisplay: ObservableObject {
    let screen = ModelEntity()
    @Published private(set) var error: String?
    @Published private(set) var isLive = false
    @Published private(set) var displayedFPS = 0.0
    @Published private(set) var sourceAgeMs: Double?
    @Published private(set) var uncertaintyMs: Double?
    @Published private(set) var unavailableMessage = "等待第一帧画面"
    private let device = MTLCreateSystemDefaultDevice()
    private var queue: (any MTLCommandQueue)?
    private var context: CIContext?
    private var optics: RobotVideoOptics?
    private var material: ShaderGraphMaterial?
    private var textures: [LowLevelTexture] = []
    private var dimensions = SIMD2<Int>(0, 0)
    private var pending: (buffer: any MTLCommandBuffer, timing: RobotVideoTiming, streamID: UInt64, fov: Float)?
    private var lastPresentedAt: TimeInterval = 0
    private var lastTiming: RobotVideoTiming?
    private var lastStreamID: UInt64?
    private var metricsAt: TimeInterval = 0
    private var frames = 0
    private var statsStarted = CACurrentMediaTime()
    private var fov: Float = 120
    private var presentedFOV: Float = 120

    init() {
        screen.position = [0, 0, -2]
        screen.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        screen.isEnabled = false
        if let device {
            queue = device.makeCommandQueue()
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
    }

    func prepare() async {
        do {
            guard let device else { throw CocoaError(.featureUnsupported) }
            optics = try RobotVideoOptics(device: device)
            material = try await ShaderGraphMaterial(named: "/Root/StereoMaterial", from: "RobotStereoCalibrated.usda", in: realityKitContentBundle)
            material?.faceCulling = .none
            error = nil
        } catch {
            self.error = "相机校正加载失败：\(error.localizedDescription)"
        }
    }

    func setView(fov: Float) {
        self.fov = fov
        if fov != presentedFOV {
            screen.isEnabled = false
            isLive = false
            unavailableMessage = "正在调整取景范围"
            DataManager.shared.robotVideoReason = "view_changing"
            DataManager.shared.robotVideoPresentedAt = 0
        }
    }

    private func setPresentedFOV(_ value: Float) throws {
        guard var material else { return }
        // Fit the camera view inside 80 degrees so its edges are easier to see.
        try material.setParameter(name: "tanHalfHorizontalFov", value: .float(tan(min(value, 80) * .pi / 360)))
        try material.setParameter(name: "imageAspect", value: .float(Float(dimensions.x) / Float(dimensions.y)))
        self.material = material
        screen.model?.materials = [material]
        presentedFOV = value
    }

    private func configure(width: Int, height: Int) throws {
        guard var material else { return }
        // Core Image writes linear values; the sRGB texture handles encoding and shader sampling.
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                    textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        let left = try LowLevelTexture(descriptor: descriptor)
        let right = try LowLevelTexture(descriptor: descriptor)
        let leftResource: TextureResource = try TextureResource(from: left)
        let rightResource: TextureResource = try TextureResource(from: right)
        try material.setParameter(name: "left", value: .textureResource(leftResource))
        try material.setParameter(name: "right", value: .textureResource(rightResource))
        try material.setParameter(name: "tanHalfHorizontalFov", value: .float(tan(min(fov, 80) * .pi / 360)))
        try material.setParameter(name: "imageAspect", value: .float(Float(width) / Float(height)))
        self.material = material
        textures = [left, right]
        dimensions = [width, height]
        // The shader uses each eye's viewing ray; this plane only bounds the draw area.
        let coverageWidth: Float = 4 * tan(80 * .pi / 360) + 0.2
        let coverageHeight = coverageWidth * Float(height) / Float(width) + 0.2
        screen.model = ModelComponent(mesh: .generatePlane(width: coverageWidth, depth: coverageHeight), materials: [material])
        presentedFOV = fov
    }

    func tick(connection: RobotVideoConnection) {
        let now = CACurrentMediaTime()
        if let pending {
            if pending.buffer.status == .completed {
                if pending.fov != presentedFOV {
                    do { try setPresentedFOV(pending.fov) }
                    catch { self.error = "视角更新失败：\(error.localizedDescription)" }
                }
                lastTiming = pending.timing
                lastStreamID = pending.streamID
                // The lower bound on source time makes the 0.5 s control gate conservative.
                lastPresentedAt = pending.timing.sourceMappedAt - pending.timing.uncertainty
                frames += 1
                self.pending = nil
            } else if pending.buffer.status == .error {
                error = "视频显示失败，请返回后重试"
                self.pending = nil
                lastPresentedAt = 0
            }
        }
        let streamActive = lastStreamID.map { connection.isStreamActive($0) } ?? false
        let fresh = error == nil && fov == presentedFOV && streamActive && lastTiming?.isFresh(at: now) == true
        let reason: String
        let message: String
        if let error {
            reason = "renderer_error"
            message = error
        } else if fov != presentedFOV {
            reason = "view_changing"
            message = "正在调整取景范围"
        } else if lastStreamID == nil {
            reason = "waiting_frame"
            message = connection.status
        } else if !streamActive {
            reason = "stream_inactive"
            message = "视频连接中断，正在恢复"
        } else if let timing = lastTiming {
            if now > timing.clockValidUntil {
                reason = "clock_expired"
                message = "视频时间同步已过期"
            } else if timing.uncertainty > 0.1 {
                reason = "clock_uncertain"
                message = "视频时间同步误差过大"
            } else if now - timing.sourceMappedAt < -timing.uncertainty {
                reason = "clock_invalid"
                message = "视频时间尚未对齐"
            } else if now - timing.sourceMappedAt + timing.uncertainty > 0.5 {
                reason = "source_stale"
                message = "视频画面超过 500 ms 未更新"
            } else {
                reason = "ready"
                message = ""
            }
        } else {
            reason = "waiting_frame"
            message = "等待第一帧画面"
        }
        if unavailableMessage != message { unavailableMessage = message }
        DataManager.shared.robotVideoReason = reason
        if isLive != fresh {
            let age = lastTiming.map { String(format: "%.1f", (now - $0.sourceMappedAt) * 1000) } ?? "unknown"
            let uncertainty = lastTiming.map { String(format: "%.1f", $0.uncertainty * 1000) } ?? "unknown"
            let clockRemaining = lastTiming.map { String(format: "%.1f", ($0.clockValidUntil - now) * 1000) } ?? "unknown"
            print("[R1VideoGate] live=\(fresh) reason=\(reason) stream_active=\(streamActive) source_age_ms=\(age) uncertainty_ms=\(uncertainty) clock_remaining_ms=\(clockRemaining) fov_matched=\(fov == presentedFOV) error=\(error ?? "none")")
            isLive = fresh
        }
        screen.isEnabled = fresh
        DataManager.shared.robotVideoPresentedAt = fresh ? lastPresentedAt : 0
        if now - metricsAt >= 0.2 {
            sourceAgeMs = lastTiming.map { max(0, now - $0.sourceMappedAt) * 1000 }
            uncertaintyMs = lastTiming.map { $0.uncertainty * 1000 }
            metricsAt = now
        }
        if now - statsStarted >= 1 {
            displayedFPS = Double(frames) / (now - statsStarted)
            dlog("[R1 DISPLAY] fps=\(String(format: "%.1f", displayedFPS)) live=\(fresh) eye=\(dimensions.x)x\(dimensions.y)")
            frames = 0
            statsStarted = now
        }
        // Never queue GPU work behind an unfinished frame; the receiver retains only the newest one.
        guard pending == nil, material != nil, error == nil,
              let optics, let context, let queue, let frame = connection.takeLatestFrame(),
              frame.timing.isFresh(at: now) else { return }
        guard frame.rotationDegrees == 0, frame.width > 0, frame.width % 2 == 0, frame.height > 0 else {
            error = "相机画面格式不是左右并排双目，请检查视频源"
            return
        }
        guard optics.supports(width: frame.width, height: frame.height) else {
            error = "视频尺寸与相机标定不符，请检查相机配置"
            return
        }
        do {
            let eyeWidth = frame.width / 2
            if dimensions != SIMD2(eyeWidth, frame.height) {
                try configure(width: eyeWidth, height: frame.height)
            }
            guard textures.count == 2, let command = queue.makeCommandBuffer() else { return }
            try optics.encode(pixelBuffer: frame.pixelBuffer,
                              targets: textures.map { $0.replace(using: command) },
                              fov: fov, commandBuffer: command, context: context)
            command.commit()
            pending = (command, frame.timing, frame.streamID, fov)
        } catch {
            self.error = "视频显示失败：\(error.localizedDescription)"
            DataManager.shared.robotVideoReason = "renderer_error"
            DataManager.shared.robotVideoPresentedAt = 0
        }
    }

    func stop() {
        screen.isEnabled = false
        lastPresentedAt = 0
        isLive = false
        pending = nil
        lastTiming = nil
        lastStreamID = nil
        sourceAgeMs = nil
        uncertaintyMs = nil
        frames = 0
        displayedFPS = 0
        statsStarted = CACurrentMediaTime()
        unavailableMessage = "视频已停止"
        DataManager.shared.robotVideoReason = "stopped"
        DataManager.shared.robotVideoPresentedAt = 0
    }
}

struct RobotFirstPersonView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("r1VideoHost") private var host = "192.168.124.147"
    @AppStorage("r1VideoFOV") private var fieldOfView = 120.0
    @StateObject private var connection = RobotVideoConnection()
    @StateObject private var display = RobotStereoDisplay()
    @StateObject private var operatorStatus = RobotOperatorStatus()
    @State private var sessionTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var hands = "等待双手追踪"
    @State private var handsReady = false
    @State private var exiting = false
    @State private var trackingError: String?
    @State private var trackingWriteMs = 0.0
    @State private var trackingPacketsSent: UInt64 = 0

    var body: some View {
        RealityView { content, attachments in
            let anchor = AnchorEntity(.head)
            anchor.addChild(display.screen)
            if let controls = attachments.entity(for: "controls") {
                controls.position = [0, -0.72, -1.8]
                anchor.addChild(controls)
            }
            if let warning = attachments.entity(for: "warning") {
                warning.position = [0, 0, -1.5]
                anchor.addChild(warning)
            }
            content.add(anchor)
        } attachments: {
            Attachment(id: "controls") { controls }
            Attachment(id: "warning") {
                if !display.isLive || trackingError != nil {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text(trackingError ?? display.unavailableMessage).font(.title2.weight(.semibold))
                        Text("等待画面与双手输入恢复稳定后自动对齐；首次启动按 r，手动暂停后按 r / s")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("返回") { leave() }.disabled(exiting)
                    }
                    .padding(28)
                    .glassBackgroundEffect()
                }
            }
        }
        .upperLimbVisibility(.hidden)
        .task {
            await display.prepare()
            display.setView(fov: Float(fieldOfView))
        }
        .onAppear {
            DataManager.shared.robotVideoRequired = true
            if scenePhase != .background { startSession() }
        }
        .onChange(of: scenePhase == .background) { _, background in
            if background { stopSession() }
            else if !exiting { startSession() }
        }
        .onChange(of: fieldOfView) { _, value in display.setView(fov: Float(value)) }
        .onDisappear { stopSession() }
    }

    private func startSession() {
        let previous = sessionTask
        stopSession()
        sessionTask = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            // ARKit providers cannot be restarted after stop; each activation owns new providers.
            let tracking = 🥽AppModel()
            trackingError = nil
            async let trackingLoop: Void = tracking.runFirstPersonTracking { trackingError = $0 }
            let videoHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.start(host: videoHost)
            operatorStatus.start(host: videoHost)
            defer {
                connection.stop()
                operatorStatus.stop()
                display.stop()
            }
            var statusAt: TimeInterval = 0
            while !Task.isCancelled {
                display.tick(connection: connection)
                let now = CACurrentMediaTime()
                operatorStatus.expireIfNeeded(at: now)
                if now - statusAt >= 0.2 {
                    let data = DataManager.shared.latestHandTrackingData
                    let left = data.leftValid && now - data.leftTime <= 0.25
                    let right = data.rightValid && now - data.rightTime <= 0.25
                    hands = "左手 \(left ? "正常" : "失追") · 右手 \(right ? "正常" : "失追")"
                    handsReady = left && right
                    trackingWriteMs = DataManager.shared.robotTrackingLastWriteMs
                    trackingPacketsSent = DataManager.shared.robotTrackingPacketsSent
                    statusAt = now
                }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { break }
            }
            _ = await trackingLoop
        }
    }

    private func stopSession() {
        sessionTask?.cancel()
        connection.stop()
        operatorStatus.stop()
        display.stop()
        DataManager.shared.latestHandTrackingData.headValid = false
        DataManager.shared.latestHandTrackingData.leftValid = false
        DataManager.shared.latestHandTrackingData.rightValid = false
    }

    private var motionColor: Color {
        switch operatorStatus.snapshot?.motion {
        case "following": return .green
        case "paused", "tracking_hold", "failed": return .orange
        default: return .secondary
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle().fill(display.isLive ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .accessibilityLabel(display.isLive ? "双目实时" : "视频异常")
                Text(operatorStatus.message).foregroundStyle(motionColor)
                if let recording = operatorStatus.snapshot?.recording {
                    Text(recording.label)
                        .foregroundStyle(recording.state == "recording" ? Color.red : recording.state == "failed" ? Color.orange : Color.secondary)
                }
                if !handsReady { Text(hands).foregroundStyle(.orange) }
                Button { showSettings.toggle() } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("状态与画面设置")
                Button { leave() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("返回首页").disabled(exiting)
            }
            .font(.caption)
            if let notice = operatorStatus.savedNotice {
                Text(notice).font(.caption).foregroundStyle(.green)
            }
            if let recording = operatorStatus.snapshot?.recording, let quality = recording.savedQuality,
               let label = recording.qualityLabel {
                Text(label).font(.caption)
                    .foregroundStyle(quality.state == "pending" ? Color.secondary : quality.hasExportableSegments ? Color.green : Color.orange)
            }
            if showSettings {
                Divider()
                Text(hands).font(.callout)
                if let status = operatorStatus.snapshot, status.motion == "tracking_hold" {
                    Text("暂停原因：\(status.holdLabel)").foregroundStyle(.orange)
                    if !["left_hand_lost", "right_hand_lost", "both_hands_lost"].contains(status.hold_reason ?? "") {
                        Text("画面和双手输入恢复稳定后，自动对齐并继续跟随；手动暂停仍需按 r / s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("取景范围")
                    Slider(value: $fieldOfView, in: 60...120, step: 5).frame(width: 160)
                    Text("\(Int(fieldOfView))°").monospacedDigit()
                }
                Button("最大取景 120°") { fieldOfView = 120 }
                Text("画面缩小以便看全四周；取景越大，物体越小")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("镜头去畸变 · 双目对齐")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("调整视角会暂时保持姿态；画面和双手输入恢复稳定后自动对齐继续")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("距离感仍受相机间距与瞳距差异影响")
                    .font(.caption2).foregroundStyle(.secondary)
                if let age = display.sourceAgeMs, let uncertainty = display.uncertaintyMs, display.isLive {
                    Text("源画面年龄 ≈ \(Int(age)) ± \(Int(uncertainty)) ms")
                        .monospacedDigit()
                } else {
                    Text(connection.timingStatus).foregroundStyle(.orange)
                }
                Text("从 PC2 收到相机帧开始计时，包含传输与解码；不是曝光到屏幕的完整延迟")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("单眼 \(connection.frameWidth / 2) × \(connection.frameHeight) · 接收 \(Int(connection.decodedFPS)) / 显示 \(Int(display.displayedFPS)) fps")
                Text("重复帧 \(connection.duplicateFrames) · 时间未匹配 \(connection.unmatchedFrames) · 重连 \(connection.reconnectCount)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("姿态已发送 \(trackingPacketsSent) 包 · 最近提交等待 \(trackingWriteMs, specifier: "%.1f") ms")
                    .font(.caption2).monospacedDigit()
                Text("提交等待反映本机发送积压，不是头显到机器人的网络延迟")
                    .font(.caption2).foregroundStyle(.secondary)
                if let recording = operatorStatus.snapshot?.recording {
                    if let saved = recording.last_saved {
                        Text(saved.label).font(.caption)
                    }
                    if let quality = recording.savedQuality {
                        Text("任务结果：\(quality.outcomeLabel)").font(.caption)
                        if quality.state == "complete" {
                            Text("数据文件：\(quality.file_valid == true ? "完整" : quality.file_valid == false ? "不完整" : "未确认")")
                                .foregroundStyle(quality.file_valid == true ? Color.secondary : Color.orange)
                            if let total = quality.total_frames, let eligible = quality.eligible_frames {
                                Text("单帧合格 \(eligible) / \(total) · 最长连续 \(quality.longest_segment_frames ?? 0) 帧")
                                    .monospacedDigit()
                            }
                            if let minimum = quality.min_segment_frames {
                                Text("导出至少连续 \(minimum) 帧 · \(quality.summary)")
                                    .font(.caption2)
                            } else {
                                Text("导出最小片段长度未确认 · \(quality.summary)").font(.caption2)
                            }
                            ForEach(quality.exclusionLabels, id: \.self) { label in
                                Text(label).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !quality.exclusionLabels.isEmpty {
                                Text("同一帧可有多个筛除原因").font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if quality.state == "pending" {
                            Text("正在核对文件与连续片段").font(.caption2).foregroundStyle(.secondary)
                        } else if quality.state == "failed" {
                            Text(quality.error ?? "质量检查失败，请查看电脑终端")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if recording.state == "failed" {
                        Text("采集保存失败，请查看电脑终端").foregroundStyle(.orange)
                    }
                }
            }
        }
        .font(.caption)
        .padding(showSettings ? 14 : 8)
        .frame(width: showSettings ? 520 : nil)
        .glassBackgroundEffect()
    }

    private func leave() {
        guard !exiting else { return }
        exiting = true
        stopSession()
        Task {
            openWindow(id: "main")
            await dismissImmersiveSpace()
        }
    }
}
