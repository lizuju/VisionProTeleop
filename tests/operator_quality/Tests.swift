import Foundation

@main
struct QualityChecks {
    static var checks = 0

    static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        checks += 1
        print("PASS \(label)")
    }

    static func main() throws {
        let saved: [String: Any] = ["id": 0, "name": "episode_0000_20261008", "outcome": "success",
                                   "saved_at": "2026-10-08T10:00:00+08:00", "frames": 200]
        var recording: [String: Any] = ["state": "idle", "frames_accepted": 0, "last_saved": saved]
        func decode() throws -> RobotRecordingStatus {
            try JSONDecoder().decode(RobotRecordingStatus.self, from: JSONSerialization.data(withJSONObject: recording))
        }
        var status = try decode()
        check(status.quality == nil && status.qualityLabel == nil, "status without quality retains old behavior")
        check(status.last_saved?.label == "第 1 条已保存 · 成功", "saved notice remains the save result")

        for state in ["pending", "failed"] {
            recording["quality"] = ["episode": saved["name"]!, "state": state, "error": NSNull()]
            let snapshot: [String: Any] = ["schema": "r1_teleop_status_v1", "run_id": "run", "sequence": 1,
                                          "sample_monotonic_ns": 1, "motion": "following", "recording": recording]
            let decoded = try JSONDecoder().decode(RobotControlSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot))
            check(decoded.recording.savedQuality?.state == state && decoded.motionLabel == "跟随中",
                  "\(state) without outcome/threshold decodes the entire live snapshot")
            check(decoded.recording.savedQuality?.outcomeLabel == "未确认" && decoded.recording.savedQuality?.min_segment_frames == nil,
                  "\(state) omitted label/threshold remains unconfirmed")
        }

        var quality: [String: Any] = ["episode": saved["name"]!, "state": "pending", "outcome": "success",
                                     "min_segment_frames": 40]
        recording["quality"] = quality
        status = try decode()
        check(status.qualityLabel == "第 1 条 · 质检中", "partial pending report decodes without frame counters")
        check(status.savedQuality?.hasExportableSegments == false, "pending does not claim exportable data")

        quality.merge(["state": "complete", "file_valid": true, "total_frames": 200, "eligible_frames": 160,
                       "exportable_frames": 120, "exportable_segments": 2, "longest_segment_frames": 80,
                       "excluded_counts": ["tracking_stale": 5, "observation_age": 30, "request_skew": 20,
                                           "not_following": 0, "image_stale": 3]]) { _, new in new }
        recording["quality"] = quality
        status = try decode()
        check(status.savedQuality?.hasExportableSegments == true, "success, complete files and long segments are exportable")
        check(status.qualityLabel == "第 1 条 · 可导出 2 段 / 120 帧", "summary names the saved episode and actual export size")
        check(status.savedQuality?.exclusionLabels == ["观察过旧：30 帧", "双臂与手指请求时间差过大：20 帧", "追踪过期：5 帧"],
              "details show translated top exclusions and omit zero counts")
        for (key, label) in ["actions_unaligned": "动作请求未对齐", "arm_request_unmatched": "机械臂请求与发布未匹配",
                             "hand_request_unmatched": "手指请求与发布未匹配", "hand_input_stale": "手指输入过期"] {
            var translated = quality
            translated["excluded_counts"] = [key: 3]
            recording["quality"] = translated
            let report = try decode()
            check(report.savedQuality?.exclusionLabels == ["\(label)：3 帧"], "\(key) uses the checker key and translated label")
        }
        recording["quality"] = quality

        recording["state"] = "recording"
        recording["episode"] = ["id": 1, "name": "episode_0001_20261008"]
        status = try decode()
        check(status.label == "第 2 条 · 录制中" && status.qualityLabel?.hasPrefix("第 1 条 · ") == true,
              "previous quality keeps its episode number while next episode records")

        quality["episode"] = "episode_older"
        recording["quality"] = quality
        status = try decode()
        check(status.savedQuality == nil && status.qualityLabel == nil, "quality for a different saved episode is hidden")
        quality["episode"] = saved["name"]

        quality["exportable_frames"] = 0
        quality["exportable_segments"] = 0
        quality["longest_segment_frames"] = 10
        recording["quality"] = quality
        status = try decode()
        check(status.savedQuality?.hasExportableSegments == false && status.qualityLabel == "第 1 条 · 无足够长的可导出片段",
              "many eligible frames cannot imply a long enough exportable segment")

        quality["exportable_frames"] = 120
        quality["exportable_segments"] = 2
        for outcome in ["failure", "discarded", "unspecified", "future_outcome"] {
            quality["outcome"] = outcome
            recording["quality"] = quality
            status = try decode()
            check(status.savedQuality?.hasExportableSegments == false && status.qualityLabel?.contains("不纳入训练导出") == true,
                  "\(outcome) never claims trainable/exportable data even if counters are present")
        }

        quality["outcome"] = "success"
        quality["file_valid"] = false
        recording["quality"] = quality
        status = try decode()
        check(status.savedQuality?.hasExportableSegments == false && status.qualityLabel == "第 1 条 · 文件不完整",
              "task success does not imply file integrity")
        quality.removeValue(forKey: "file_valid")
        recording["quality"] = quality
        status = try decode()
        check(status.savedQuality?.hasExportableSegments == false && status.qualityLabel == "第 1 条 · 文件完整性未确认",
              "missing integrity verdict cannot claim exportable files")

        quality["state"] = "failed"
        quality["error"] = "checker failed"
        recording["quality"] = quality
        status = try decode()
        check(status.qualityLabel == "第 1 条 · 质检失败" && status.savedQuality?.error == "checker failed",
              "quality worker failure is separate from save failure")
        quality["state"] = "future_state"
        recording["quality"] = quality
        status = try decode()
        check(status.qualityLabel == "第 1 条 · 质量状态未知", "unknown quality state stays safe")
        recording.removeValue(forKey: "last_saved")
        status = try decode()
        check(status.savedQuality == nil, "unassociated quality cannot be attached to a live recording")
        print("\(checks)/\(checks) checks passed")
    }
}
