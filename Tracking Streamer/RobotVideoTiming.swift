import Foundation

struct RobotVideoTiming: Sendable {
    let sourceSequence: UInt64
    let sourceEpoch: String
    let timestampKind: String
    let sourceMappedAt: TimeInterval
    let uncertainty: TimeInterval
    let clockValidUntil: TimeInterval

    func isFresh(at now: TimeInterval) -> Bool {
        let age = now - sourceMappedAt
        return now <= clockValidUntil && uncertainty <= 0.1 && age >= -uncertainty && age + uncertainty <= 0.5
    }
}

// Accessed under RobotVideoBuffer's lock; RTP keys retain all 32 bits across wraparound.
struct RobotVideoTimingState {
    private struct Message: Decodable {
        let type: String
        let v: Int
        let rtp_timestamp: UInt32?
        let source_sequence: UInt64?
        let source_monotonic_ns: UInt64?
        let source_epoch: String?
        let timestamp_kind: String?
        let send_monotonic_ns: UInt64?
        let clock_id: String?
        let id: Int?
        let t0_ns: UInt64?
        let receive_monotonic_ns: UInt64?
    }
    private struct Metadata {
        let rtp: UInt32
        let sequence: UInt64
        let sourceTime: TimeInterval
        let sentAt: TimeInterval
        let epoch: String
        let clockID: String
        let receivedAt: TimeInterval
    }
    private struct ClockSample {
        let offset: TimeInterval
        let roundTrip: TimeInterval
        let receivedAt: TimeInterval
        let clockID: String
    }
    enum Match {
        case ready(RobotVideoTiming)
        case duplicate
        case unavailable
    }

    private var metadata: [UInt32: Metadata] = [:]
    private var metadataOrder: [UInt32] = []
    private var samples: [ClockSample] = []
    private var pings: [Int: UInt64] = [:]
    private var pingID = 0
    private var lastPingAt: TimeInterval = -.infinity
    private var acceptedClock: String?
    private var acceptedEpoch: String?
    private var retiredEpochs: [String] = []
    private var highestSequence: UInt64?
    private var newestSourceTime: TimeInterval?
    private var newestSentTime: TimeInterval?
    private(set) var latest: RobotVideoTiming?
    private(set) var duplicateFrames: UInt64 = 0
    private(set) var status = "等待源帧时间信息"

    mutating func ping(at now: TimeInterval) -> Data? {
        guard now - lastPingAt >= (pingID < 3 ? 0.25 : 1) else { return nil }
        lastPingAt = now
        pingID += 1
        let stamp = UInt64(now * 1_000_000_000)
        pings[pingID] = stamp
        pings = pings.filter { Double($0.value) / 1_000_000_000 >= now - 10 }
        return try? JSONSerialization.data(withJSONObject: ["type": "ping", "v": 1, "id": pingID, "t0_ns": stamp])
    }

    mutating func receive(_ data: Data, at now: TimeInterval) {
        guard data.count <= 4096, let message = try? JSONDecoder().decode(Message.self, from: data), message.v == 1 else { return }
        if message.type == "pong" {
            guard let id = message.id, let t0 = message.t0_ns, let expected = pings.removeValue(forKey: id), expected == t0,
                  let t1 = message.receive_monotonic_ns, let t2 = message.send_monotonic_ns, t2 >= t1,
                  let clock = message.clock_id, !clock.isEmpty, clock.utf8.count <= 128 else { return }
            let localSent = Double(t0) / 1_000_000_000
            let remoteReceived = Double(t1) / 1_000_000_000
            let remoteSent = Double(t2) / 1_000_000_000
            let roundTrip = (now - localSent) - (remoteSent - remoteReceived)
            guard now >= localSent, roundTrip >= -0.001, roundTrip <= 1 else { return }
            samples.removeAll { now - $0.receivedAt > 10 }
            samples.append(ClockSample(offset: ((remoteReceived - localSent) + (remoteSent - now)) / 2,
                                       roundTrip: max(0, roundTrip), receivedAt: now, clockID: clock))
            if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        } else if message.type == "frame" {
            guard let rtp = message.rtp_timestamp, let sequence = message.source_sequence,
                  let source = message.source_monotonic_ns, let sent = message.send_monotonic_ns, source <= sent,
                  let clock = message.clock_id, !clock.isEmpty, clock.utf8.count <= 128,
                  let epoch = message.source_epoch, !epoch.isEmpty, epoch.utf8.count <= 128,
                  message.timestamp_kind == "pc2_rtp_decoded_receive" else { return }
            if metadata[rtp] != nil { return }
            metadata[rtp] = Metadata(rtp: rtp, sequence: sequence, sourceTime: Double(source) / 1_000_000_000,
                                     sentAt: Double(sent) / 1_000_000_000, epoch: epoch, clockID: clock, receivedAt: now)
            metadataOrder.append(rtp)
            while metadataOrder.count > 128 {
                metadata.removeValue(forKey: metadataOrder.removeFirst())
            }
            metadata = metadata.filter { now - $0.value.receivedAt <= 2 }
            metadataOrder.removeAll { metadata[$0] == nil }
        }
    }

    mutating func match(rtp: UInt32, at now: TimeInterval) -> Match {
        guard let meta = metadata[rtp] else { return .unavailable }
        let identity = meta.clockID + ":" + meta.epoch
        guard !retiredEpochs.contains(identity) else { discard(rtp); duplicateFrames &+= 1; return .duplicate }
        let sameEpoch = meta.clockID == acceptedClock && meta.epoch == acceptedEpoch
        if !sameEpoch, meta.clockID == acceptedClock, let newestSentTime, meta.sentAt <= newestSentTime {
            discard(rtp)
            duplicateFrames &+= 1
            return .duplicate
        }
        if sameEpoch, let highestSequence, meta.sequence <= highestSequence {
            discard(rtp)
            duplicateFrames &+= 1
            return .duplicate
        }
        // A new frame must not lose its clock lease before its 0.5 s source-age gate expires.
        guard let sample = clock(at: now, id: meta.clockID, minimumValidity: 0.5) else {
            status = "等待时钟对齐"
            return .unavailable
        }
        let uncertainty = sample.roundTrip / 2 + 0.001 + max(0, now - sample.receivedAt) * 0.00005
        let mappedAt = meta.sourceTime - sample.offset
        let timing = RobotVideoTiming(sourceSequence: meta.sequence, sourceEpoch: meta.epoch,
                                      timestampKind: "pc2_rtp_decoded_receive", sourceMappedAt: mappedAt,
                                      uncertainty: uncertainty, clockValidUntil: sample.receivedAt + 10)
        if sameEpoch, let newestSourceTime, meta.sourceTime < newestSourceTime {
            discard(rtp)
            status = "源帧时间倒退"
            return .duplicate
        }
        guard timing.isFresh(at: now) else {
            discard(rtp)
            status = uncertainty > 0.1 ? "时钟不确定度过大" : "源画面已过期"
            return .unavailable
        }
        if !sameEpoch {
            if let acceptedClock, let acceptedEpoch {
                retiredEpochs.append(acceptedClock + ":" + acceptedEpoch)
                if retiredEpochs.count > 16 { retiredEpochs.removeFirst() }
            }
            acceptedClock = meta.clockID
            acceptedEpoch = meta.epoch
        }
        highestSequence = meta.sequence
        newestSourceTime = meta.sourceTime
        newestSentTime = meta.sentAt
        latest = timing
        discard(rtp)
        status = "源帧时间已对齐"
        return .ready(timing)
    }

    mutating func refresh(at now: TimeInterval) {
        samples.removeAll { now - $0.receivedAt > 10 }
        guard let acceptedClock, clock(at: now, id: acceptedClock) != nil else {
            latest = nil
            status = "等待时钟对齐"
            return
        }
        if let latest, !latest.isFresh(at: now) { status = "源画面已过期" }
    }

    private func clock(at now: TimeInterval, id: String, minimumValidity: TimeInterval = 0) -> ClockSample? {
        samples.filter { $0.clockID == id && now + minimumValidity <= $0.receivedAt + 10 }
            .min { $0.roundTrip < $1.roundTrip }
    }

    private mutating func discard(_ rtp: UInt32) {
        metadata.removeValue(forKey: rtp)
        metadataOrder.removeAll { $0 == rtp }
    }
}
