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
    struct Quality: Decodable {
        let episode: String
        let state: String
        let outcome: String?
        let min_segment_frames: Int?
        let file_valid: Bool?
        let total_frames: Int?
        let eligible_frames: Int?
        let exportable_frames: Int?
        let exportable_segments: Int?
        let longest_segment_frames: Int?
        let excluded_counts: [String: Int]?
        let error: String?

        var outcomeLabel: String {
            guard let outcome else { return "未确认" }
            return ["success": "成功", "failure": "失败", "discarded": "已标记丢弃", "unspecified": "未标注"][outcome] ?? "未知标签"
        }

        var hasExportableSegments: Bool {
            state == "complete" && file_valid == true && outcome == "success"
                && (exportable_segments ?? 0) > 0 && (exportable_frames ?? 0) > 0
        }

        var summary: String {
            switch state {
            case "pending": return "质检中"
            case "failed": return "质检失败"
            case "complete":
                if file_valid == false { return "文件不完整" }
                if file_valid != true { return "文件完整性未确认" }
                if outcome != "success" { return "\(outcomeLabel) · 不纳入训练导出" }
                if hasExportableSegments {
                    return "可导出 \(exportable_segments!) 段 / \(exportable_frames!) 帧"
                }
                return "无足够长的可导出片段"
            default: return "质量状态未知"
            }
        }

        var exclusionLabels: [String] {
            let names = ["not_following": "未跟随", "tracking_stale": "追踪过期", "feedback_stale": "反馈过期",
                         "image_stale": "图像过期", "image_missing": "图像缺失", "cameras_unaligned": "相机未对齐",
                         "sensor_unaligned": "反馈与图像未对齐", "camera_clock_invalid": "相机时间无效",
                         "observation_skew": "观察时间差过大", "observation_age": "观察过旧",
                         "request_skew": "双臂与手指请求时间差过大", "command_inactive": "命令未生效",
                         "request_before_observation": "请求早于观察", "request_stale": "请求过期",
                         "actions_unaligned": "动作请求未对齐", "hand_input_stale": "手指输入过期",
                         "arm_request_unmatched": "机械臂请求与发布未匹配", "hand_request_unmatched": "手指请求与发布未匹配"]
            return (excluded_counts ?? [:]).filter { $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(3).map { "\(names[$0.key] ?? $0.key)：\($0.value) 帧" }
        }
    }
    let state: String
    let episode: Episode?
    let frames_accepted: Int
    let last_saved: Saved?
    let quality: Quality?
    let error: String?

    var savedQuality: Quality? {
        guard let quality, quality.episode == last_saved?.name else { return nil }
        return quality
    }

    var qualityLabel: String? {
        guard let quality = savedQuality, let saved = last_saved else { return nil }
        return "第 \(saved.id + 1) 条 · \(quality.summary)"
    }

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
