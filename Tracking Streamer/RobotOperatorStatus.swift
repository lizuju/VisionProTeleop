import Combine
import Foundation
import QuartzCore
import Security

struct RobotRecordingStatus: Decodable {
    struct Episode: Decodable {
        let id: Int
        let name: String
    }
    struct Saved: Decodable {
        let id: Int
        let name: String
        let outcome: String
        let saved_at: String
        let frames: Int

        var label: String {
            let result = ["success": "成功", "failure": "失败", "discarded": "已标记丢弃", "unspecified": "未标注"][outcome] ?? "未知标签"
            return "第 \(id + 1) 条已保存 · \(result)"
        }
    }
    let state: String
    let episode: Episode?
    let frames_accepted: Int
    let last_saved: Saved?
    let error: String?

    var label: String {
        let number = episode.map { "第 \($0.id + 1) 条 · " } ?? ""
        switch state {
        case "disabled": return "未启用采集"
        case "idle": return "待采集"
        case "recording": return number + "录制中"
        case "saving": return number + "保存中"
        case "failed": return "保存失败"
        default: return "采集状态未知"
        }
    }
}

struct RobotControlSnapshot: Decodable {
    let schema: String
    let run_id: String
    let sequence: UInt64
    let sample_monotonic_ns: UInt64
    let motion: String
    let recording: RobotRecordingStatus
    let error: String?
    let hold_reason: String?

    var holdLabel: String {
        switch hold_reason {
        case "receive_timeout": return "姿态接收超时"
        case "input_stale": return "姿态数据已过期"
        case "connection_lost": return "姿态连接中断"
        case "connection_restarted": return "姿态连接已恢复，待对齐"
        case "head_untracked": return "头部追踪丢失"
        case "video_source_stale": return "视频画面已过期"
        case "video_stream_inactive": return "视频连接中断"
        case "video_clock_expired": return "视频时间同步已过期"
        case "video_clock_uncertain", "video_clock_invalid": return "视频时间未对齐"
        case "video_view_changing": return "取景范围已调整"
        case "video_renderer_error": return "视频显示异常"
        case "video_stopped": return "视频已停止"
        case "video_waiting_frame": return "等待视频画面"
        case "left_hand_lost": return "左手失追"
        case "right_hand_lost": return "右手失追"
        case "both_hands_lost": return "双手失追"
        default: return "追踪中断"
        }
    }

    var motionLabel: String {
        switch motion {
        case "waiting": return "等待跟随"
        case "preparing": return "正在对齐"
        case "following": return "跟随中"
        case "paused": return "已暂停"
        case "tracking_hold": return "\(holdLabel) · 保持"
        case "stopped": return "遥操已结束"
        case "failed": return "遥操异常"
        default: return "状态未知"
        }
    }
}

@MainActor
final class RobotOperatorStatus: ObservableObject {
    @Published private(set) var snapshot: RobotControlSnapshot?
    @Published private(set) var message = "未连接遥操"
    @Published private(set) var savedNotice: String?
    private var task: Task<Void, Never>?
    private var session: URLSession?
    private var generation: UInt64 = 0
    private var validUntil: TimeInterval = 0
    private var noticeUntil: TimeInterval = 0

    private struct Response: Decodable {
        let available: Bool
        let reason: String?
        let age_ms: Double?
        let status: RobotControlSnapshot?
    }

    func start(host: String) {
        stop()
        guard RobotVideoConnection.hostIsValid(host),
              let caURL = Bundle.main.url(forResource: "RobotVideoRootCA", withExtension: "der"),
              let caData = try? Data(contentsOf: caURL),
              let ca = SecCertificateCreateWithData(nil, caData as CFData),
              let url = URL(string: "https://\(host):60001/r1/status") else {
            message = "遥操状态连接失败"
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 0.8
        let session = URLSession(configuration: config, delegate: RobotVideoTrust(host: host, rootCA: ca), delegateQueue: nil)
        self.session = session
        let expected = generation
        task = Task { [weak self] in
            guard let self else { return }
            var lastRun: String?
            var lastSequence: UInt64 = 0
            var advancedAt: TimeInterval = 0
            var lastSaved: String?
            while !Task.isCancelled, generation == expected {
                let sentAt = CACurrentMediaTime()
                do {
                    let (data, response) = try await session.data(from: url)
                    guard !Task.isCancelled, generation == expected else { return }
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          data.count <= 32768 else { throw URLError(.badServerResponse) }
                    let reply = try JSONDecoder().decode(Response.self, from: data)
                    let now = CACurrentMediaTime()
                    if reply.available, let status = reply.status, status.schema == "r1_teleop_status_v1",
                       let age = reply.age_ms, age.isFinite, age >= 0, age / 1000 + now - sentAt <= 1 {
                        if lastRun != status.run_id {
                            lastRun = status.run_id
                            lastSequence = status.sequence
                            advancedAt = now
                            lastSaved = status.recording.last_saved?.name
                            savedNotice = nil
                            noticeUntil = 0
                        } else if status.sequence > lastSequence {
                            lastSequence = status.sequence
                            advancedAt = now
                        }
                        if now - advancedAt <= 1, status.sequence == lastSequence {
                            snapshot = status
                            validUntil = min(sentAt + 1 - age / 1000, advancedAt + 1)
                            message = status.motionLabel
                            if let saved = status.recording.last_saved, saved.name != lastSaved {
                                lastSaved = saved.name
                                savedNotice = saved.label
                                noticeUntil = now + 4
                            }
                        } else {
                            snapshot = nil
                            validUntil = 0
                            message = "遥操状态已过期"
                        }
                    } else {
                        snapshot = nil
                        validUntil = 0
                        message = reply.reason == "not_running" ? "未启动遥操" : "遥操状态已过期"
                    }
                    expireIfNeeded(at: now)
                } catch {
                    guard !Task.isCancelled, generation == expected else { return }
                    snapshot = nil
                    validUntil = 0
                    savedNotice = nil
                    message = "遥操状态连接中断"
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func expireIfNeeded(at now: TimeInterval = CACurrentMediaTime()) {
        if snapshot != nil, now >= validUntil {
            snapshot = nil
            message = "遥操状态已过期"
        }
        if now >= noticeUntil { savedNotice = nil }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        snapshot = nil
        validUntil = 0
        savedNotice = nil
        noticeUntil = 0
        message = "未连接遥操"
    }
}
