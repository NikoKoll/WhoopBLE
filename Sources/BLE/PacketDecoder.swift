import Foundation

enum PacketDecoder {
    static func decode(_ data: Data) -> WhoopMetrics? {
        // Must reach byte[11] (RR count). Smallest accepted type (0x57) is 20 bytes.
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data)

        // 0x57 = dominant stream packet (20B), 0xab = short health (32B), 0x52 = extended (48B).
        // Other types (0x03 cmd ACKs, 0xfa, …) are rejected.
        guard bytes[0] == 0xaa,
              bytes[3] == 0x57 || bytes[3] == 0xab || bytes[3] == 0x52 else { return nil }

        // Byte layout per GitHub RE post:
        // [0-3] header | [4-7] WHOOP internal timestamp | [8-9] Metric1 | [10] HR | [11] RR count
        // Note: bytes[10] ≈ 0xe2 (WHOOP clock high byte) on observed 0x57 packets — consistently
        // rejected by the heartRate guard below. HR comes from std HR service (0x2A37) in practice.
        let metric1 = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let heartRate = Int(bytes[10])
        // Log metric1 every packet — per HANDOFF TODO #1, bytes[8-9] may be device step count.
        // Walk 50 steps and watch whether metric1 increments proportionally.
        print("📊 metric1=\(metric1) hr_raw=\(heartRate)")
        guard heartRate >= 30, heartRate <= 220 else { return nil }

        let rrCount = min(Int(bytes[11]), 4)
        var rrIntervals: [Double] = []
        for i in 0..<rrCount {
            let base = 12 + i * 2
            guard base + 1 < bytes.count else { break }
            let raw = UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
            if raw >= 300, raw <= 2000 { rrIntervals.append(Double(raw) / 1000.0) }
        }

        return WhoopMetrics(timestamp: Date(), heartRate: heartRate, rrIntervals: rrIntervals)
    }
}
