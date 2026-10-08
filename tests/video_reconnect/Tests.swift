import Foundation

@main
struct ReconnectChecks {
    static var checks = 0

    static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        checks += 1
        print("PASS \(label)")
    }

    static func frame(_ sequence: UInt64, at source: TimeInterval, epoch: String = "camera-a",
                      uncertainty: TimeInterval = 0.001, clockUntil: TimeInterval = 100) -> RobotVideoTiming {
        RobotVideoTiming(sourceSequence: sequence, sourceEpoch: epoch, timestampKind: "pc2_rtp_decoded_receive",
                         sourceMappedAt: source, uncertainty: uncertainty, clockValidUntil: clockUntil)
    }

    static func stream(_ state: inout RobotVideoReconnectBackoff, from start: TimeInterval = 10,
                       through end: Int = 8, epoch: String = "camera-a") {
        for index in 0...end {
            let now = start + Double(index) * 0.25
            state.observe(frame(UInt64(index + 1), at: now - 0.01, epoch: epoch), at: now)
        }
    }

    static func main() {
        var state = RobotVideoReconnectBackoff()
        for index in 1...7 {
            check(state.failed() == Double(min(index, 5)), "continuous failure \(index) backs off up to five seconds")
        }
        stream(&state)
        check(state.consecutiveFailures == 0 && state.failed() == 1,
              "two seconds of genuinely advancing fresh frames reset the next retry to one second")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 7)
        check(state.failed() == 2, "brief healthy connection does not reset the failure streak")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        for index in 0...12 {
            state.observe(frame(1, at: 10), at: 10 + Double(index) * 0.25)
        }
        check(state.failed() == 2, "repeated frozen source frames cannot establish recovery")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        for index in 0...12 {
            let now = 10 + Double(index) * 0.25
            state.observe(frame(1, at: now - 0.01), at: now)
        }
        check(state.failed() == 2, "timestamp changes without a new source sequence do not reset retries")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        for index in 0...12 {
            state.observe(frame(UInt64(index + 1), at: 10), at: 10 + Double(index) * 0.25)
        }
        check(state.failed() == 2, "sequence changes without a new source sample time do not reset retries")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        check(frame(1, at: 10.01, uncertainty: 0.02).isFresh(at: 10),
              "freshness uncertainty permits a near-future sample")
        for index in 0...12 {
            let now = 10 + Double(index) * 0.25
            let future = frame(UInt64(index + 1), at: now + 0.01, uncertainty: 0.02)
            state.observe(future, at: now)
        }
        check(state.failed() == 2, "future samples do not prove sustained recovery even within clock uncertainty")

        for invalid in ["stale", "expired_clock", "uncertain_clock", "nan_time"] {
            state = RobotVideoReconnectBackoff()
            _ = state.failed()
            stream(&state, through: 6)
            for index in 7...12 {
                let now = 10 + Double(index) * 0.25
                let timing: RobotVideoTiming
                switch invalid {
                case "stale": timing = frame(UInt64(index + 1), at: now - 0.5)
                case "expired_clock": timing = frame(UInt64(index + 1), at: now - 0.01, clockUntil: now - 0.001)
                case "uncertain_clock": timing = frame(UInt64(index + 1), at: now - 0.01, uncertainty: 0.101)
                default: timing = frame(UInt64(index + 1), at: .nan)
                }
                state.observe(timing, at: now)
            }
            check(state.failed() == 2, "\(invalid) samples break recovery rather than reset retries")
        }

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 6)
        state.observe(nil, at: 11.75)
        stream(&state, from: 12, through: 6)
        check(state.failed() == 2, "missing timing clears prior healthy duration")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 6)
        for index in 0...6 {
            let now = 12.25 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 20), at: now - 0.01), at: now)
        }
        check(state.failed() == 2, "a receive gap longer than 500 ms starts a new recovery window")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        for index in 0...6 {
            let now = 10 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 1), at: now - 0.4), at: now)
        }
        for index in 0...6 {
            let now = 11.75 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 20), at: now - 0.01), at: now)
        }
        check(state.failed() == 2, "a source sample gap longer than 500 ms starts a new recovery window")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 7)
        stream(&state, from: 12, through: 7, epoch: "camera-b")
        check(state.consecutiveFailures == 1, "source epoch changes do not inherit healthy time")
        state.observe(frame(9, at: 13.99, epoch: "camera-b"), at: 14)
        check(state.failed() == 1, "a new epoch can independently establish sustained recovery")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        for index in 0...8 {
            let now = 10 + Double(index) * 0.25
            let timing = frame(UInt64(index + 1), at: now - 0.01)
            state.observe(timing, at: now)
            state.observe(timing, at: now + 0.125)
        }
        check(state.failed() == 1, "ordinary repeated status polls between new frames preserve continuous recovery")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 6)
        state.observe(frame(6, at: 11.74), at: 11.75)
        for index in 0...6 {
            let now = 12 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 20), at: now - 0.01), at: now)
        }
        check(state.failed() == 2, "a regressing source sequence cannot extend prior recovery time")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 6)
        state.observe(frame(8, at: 11.48), at: 11.75)
        for index in 0...6 {
            let now = 12 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 20), at: now - 0.01), at: now)
        }
        check(state.failed() == 2, "a regressing source time cannot extend prior recovery time")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        stream(&state, through: 6)
        check(state.failed() == 2, "failure during the recovery window retains retry progression")
        stream(&state, from: 12, through: 6)
        check(state.failed() == 3, "retry failure clears partial healthy time from the previous connection")

        state = RobotVideoReconnectBackoff()
        _ = state.failed()
        state.observe(frame(1, at: 10), at: 10)
        for index in 1...8 {
            let now = 10 + Double(index) * 0.25
            state.observe(frame(UInt64(index + 1), at: now - 0.24), at: now)
        }
        check(state.consecutiveFailures == 1, "wall duration alone cannot replace two seconds of advancing source time")
        state.observe(frame(10, at: 12.01), at: 12.25)
        check(state.failed() == 1, "both source and arrival duration establish recovery")

        check(!frame(1, at: 9.5).isFresh(at: 10), "the existing conservative 500 ms freshness threshold is unchanged")
        print("\(checks) reconnect checks passed")
    }
}
