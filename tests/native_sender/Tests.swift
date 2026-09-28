import Foundation
import QuartzCore
import SwiftProtobuf

actor TestWriter {
    var packets: [Handtracking_HandUpdate] = []
    var times: [Double] = []
    let firstDelay: UInt64
    var writesInProgress = 0
    var maxConcurrentWrites = 0
    init(firstDelay: UInt64 = 0) { self.firstDelay = firstDelay }
    func write(_ update: Handtracking_HandUpdate) async throws {
        writesInProgress += 1
        maxConcurrentWrites = max(maxConcurrentWrites, writesInProgress)
        defer { writesInProgress -= 1 }
        packets.append(update)
        times.append(CACurrentMediaTime())
        if packets.count == 1 && firstDelay > 0 { try await Task.sleep(nanoseconds: firstDelay) }
    }
}

@main struct SenderTests {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        let manager = DataManager.shared
        func good() {
            manager.robotVideoRequired = false
            manager.latestHandTrackingData.headValid = true
            manager.latestHandTrackingData.leftValid = true
            manager.latestHandTrackingData.rightValid = true
            manager.latestHandTrackingData.headTime = 42
            manager.latestHandTrackingData.leftTime = 41
            manager.latestHandTrackingData.rightTime = 40
        }
        func stream(_ writer: TestWriter) -> (UUID, Task<Void,Never>) {
            let id = UUID()
            manager.handTrackingStreamID = id
            manager.robotTrackingLastWriteMs = 0
            manager.robotTrackingPacketsSent = 0
            return (id, Task { await runStream(writer, streamID: id) })
        }
        good()
        let initial = fill_handUpdate()
        check(initial.trackingProtocolVersion == 1 && initial.diagnosticsVersion == 1, "additive diagnostics capability preserves protocol v1")
        check(initial.headAnchorValid && initial.videoReady && !initial.videoRequired, "passthrough needs no video")
        let headStart = manager.headLossSeq
        let leftStart = manager.leftLossSeq
        let rightStart = manager.rightLossSeq
        manager.latestHandTrackingData.headValid = false
        manager.latestHandTrackingData.headValid = true
        manager.latestHandTrackingData.leftValid = false
        manager.latestHandTrackingData.leftValid = false
        manager.latestHandTrackingData.leftValid = true
        manager.latestHandTrackingData.rightValid = false
        manager.latestHandTrackingData.rightValid = true
        let recovered = fill_handUpdate()
        check(recovered.headValid && recovered.headLossSeq == headStart + 1, "short head loss retained after recovery before serialization")
        check(recovered.headLossReason == "head_untracked", "head loss reason retained after recovery")
        check(recovered.leftValid && recovered.leftLossSeq == leftStart + 1, "left loss source edge retained without duplicate counting")
        check(recovered.rightValid && recovered.rightLossSeq == rightStart + 1, "right loss source edge retained independently")
        manager.robotVideoReason = "ready"
        manager.robotVideoPresentedAt = CACurrentMediaTime()
        manager.robotVideoRequired = true
        let beforeVideoLoss = manager.headLossSeq
        manager.robotVideoReason = "stream_inactive"
        manager.robotVideoPresentedAt = 0
        manager.robotVideoReason = "ready"
        manager.robotVideoPresentedAt = CACurrentMediaTime()
        check(manager.headLossSeq == beforeVideoLoss + 1 && manager.headLossReason == "video_stream_inactive", "short video loss retained across source display recovery")
        manager.observeTrackingValidity(at: manager.robotVideoPresentedAt + 0.501)
        check(manager.headLossSeq == beforeVideoLoss + 2 && manager.headLossReason == "video_source_stale", "true 500ms presentation timeout preserved")
        check(!manager.robotVideoReady(at: manager.robotVideoPresentedAt - 0.1), "future presentation timestamp stays invalid")
        manager.robotVideoRequired = false
        let decoded = try Handtracking_HandUpdate(serializedBytes: recovered.serializedData())
        check(decoded == recovered && decoded.headLossSeq == headStart + 1, "new protobuf diagnostic fields round trip")

        good()
        let idle = TestWriter()
        let (_, idleTask) = stream(idle)
        try await Task.sleep(nanoseconds: 270_000_000)
        idleTask.cancel(); await idleTask.value
        let idlePackets = await idle.packets
        check(idlePackets.count >= 3 && idlePackets.count <= 4, "unchanged anchors use 100ms heartbeat, not 200Hz duplicate snapshots")
        check(idlePackets.allSatisfy { $0.headTime == 42 && $0.leftTime == 41 && $0.rightTime == 40 }, "heartbeats do not retimestamp old anchors")
        check(idlePackets.enumerated().allSatisfy { $0.element.packetsSent == UInt64($0.offset+1) }, "packet ordinals are per stream and contiguous")
        check(idlePackets.first?.lastWriteMs == 0 && idlePackets.dropFirst().allSatisfy { $0.lastWriteMs > 0 }, "write duration reports previous completed local write")
        let idleCount = idlePackets.count
        try await Task.sleep(nanoseconds: 120_000_000)
        check(await idle.packets.count == idleCount, "cancelled stream has no orphan producer")

        good()
        let edgeOnly = TestWriter()
        let (_, edgeTask) = stream(edgeOnly)
        try await Task.sleep(nanoseconds: 20_000_000)
        let edgeHeadStart = manager.headLossSeq
        manager.latestHandTrackingData.headValid = false
        manager.latestHandTrackingData.headValid = true
        try await Task.sleep(nanoseconds: 30_000_000)
        edgeTask.cancel(); await edgeTask.value
        let edgePackets = await edgeOnly.packets
        check(edgePackets.count == 2, "loss counter alone sends before next heartbeat with unchanged anchor times")
        check(edgePackets[1].headValid && edgePackets[1].headLossSeq == edgeHeadStart + 1 && edgePackets[1].headLossReason == "head_untracked", "counter-only packet retains recovered loss reason")

        good()
        let slow = TestWriter(firstDelay: 180_000_000)
        let (_, slowTask) = stream(slow)
        try await Task.sleep(nanoseconds: 20_000_000)
        let slowLossStart = manager.leftLossSeq
        manager.latestHandTrackingData.leftValid = false
        manager.latestHandTrackingData.leftTime = 101
        try await Task.sleep(nanoseconds: 15_000_000)
        manager.latestHandTrackingData.leftValid = true
        manager.latestHandTrackingData.leftTime = 102
        try await Task.sleep(nanoseconds: 30_000_000)
        manager.latestHandTrackingData.leftTime = 103
        try await Task.sleep(nanoseconds: 150_000_000)
        slowTask.cancel(); await slowTask.value
        let slowPackets = await slow.packets
        check(slowPackets.count >= 2 && slowPackets[1].leftTime == 103, "slow write next sends newest source, skips intermediate poses")
        check(slowPackets[1].leftValid && slowPackets[1].leftLossSeq == slowLossStart + 1, "slow write preserves intervening invalid-to-valid edge")
        check(slowPackets[1].lastWriteMs >= 170, "backpressure write wait measured")
        check(await slow.maxConcurrentWrites == 1, "only one pending pose write")
        check(slowPackets[1].sampleTime > slowPackets[0].sampleTime + 0.17, "new sample serialized after blocked write, without stamping queued old sample")

        good()
        let fast = TestWriter()
        let (_, fastTask) = stream(fast)
        for i in 0..<50 {
            manager.latestHandTrackingData.leftTime = 200 + Double(i)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        fastTask.cancel(); await fastTask.value
        let fastTimes = await fast.times
        check(fastTimes.count <= 18, "busy source remains capped near 120Hz")
        check(zip(fastTimes,fastTimes.dropFirst()).allSatisfy { $1-$0 >= 0.007 }, "no replay burst after scheduling gaps")

        good()
        let old = TestWriter(firstDelay: 250_000_000)
        let (_, oldTask) = stream(old)
        try await Task.sleep(nanoseconds: 20_000_000)
        let fresh = TestWriter()
        let (newID, freshTask) = stream(fresh)
        try await Task.sleep(nanoseconds: 40_000_000)
        oldTask.cancel(); await oldTask.value
        check(manager.handTrackingStreamID == newID, "old cancellation preserves new stream identity")
        check(manager.robotTrackingLastWriteMs < 100, "old blocked stream cannot overwrite new stream metrics")
        freshTask.cancel(); await freshTask.value
        check(manager.handTrackingStreamID == nil, "current stream cancellation cleans its own connection identity")
        check(await old.packets.count == 1, "blocked cancelled stream never emits a later queued pose")
        let freshPackets = await fresh.packets
        check(freshPackets.first?.packetsSent == 1 && freshPackets.first?.lastWriteMs == 0, "new stream metrics reset and do not inherit old backpressure")
        print("RESULT: \(passed)/\(passed) checks passed")
    }
}
