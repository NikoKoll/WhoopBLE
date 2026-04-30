import Foundation

enum WhoopCRC {

    // Reflected CRC-32, init=0x0, poly=0x04C11DB7 (reflect-in + reflect-out).
    // Right-shift form uses reversed polynomial 0xEDB88320 — mathematically identical.
    // Verified against all three §0.4 test vectors.
    private static func calculate(_ data: [UInt8], xorOut: UInt32) -> UInt32 {
        let poly: UInt32 = 0xEDB88320  // bit-reversal of 0x04C11DB7
        var crc: UInt32 = 0x00000000
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ poly
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ xorOut
    }

    // Inspects the first 5 header bytes to select the correct XOR output (§0.4).
    // Verified test vectors:
    //   8-byte  [aa 08 00 a8 23] → xorOut 0x6971BE68  (activity, HR broadcast, sync trigger …)
    //   16-byte [aa 10 00 57 23] → xorOut 0xF43F44AC  (alarm, batch request …)
    //   28-byte [aa 18 00 ff 28] → xorOut 0xE02CCD0E  (DATA_FROM_STRAP activity packets)
    static func whoopCRC(_ data: [UInt8]) -> UInt32 {
        guard data.count >= 5 else { return calculate(data, xorOut: 0xF43F44AC) }
        let h = Array(data.prefix(5))
        let xorOut: UInt32
        if      h == [0xaa, 0x08, 0x00, 0xa8, 0x23] { xorOut = 0x6971BE68 }
        else if h == [0xaa, 0x10, 0x00, 0x57, 0x23] { xorOut = 0xF43F44AC }
        else if h == [0xaa, 0x18, 0x00, 0xff, 0x28] { xorOut = 0xE02CCD0E }
        else                                          { xorOut = 0xF43F44AC }
        return calculate(data, xorOut: xorOut)
    }

    // Builds a short (8-byte + CRC) command packet.
    // Header aa 08 00 a8 23 → xorOut 0x6971BE68
    static func buildCommand(category: UInt8, value: UInt8, count: UInt8 = 0x70) -> Data {
        var msg: [UInt8] = [0xaa, 0x08, 0x00, 0xa8, 0x23, count, category, value]
        let crc = whoopCRC(msg)
        withUnsafeBytes(of: crc.littleEndian) { msg.append(contentsOf: $0) }
        return Data(msg)
    }

    static let enableHealth      = buildCommand(category: 0x03, value: 0x01)
    static let disableHealth     = buildCommand(category: 0x03, value: 0x00)
    static let enableHRBroadcast = buildCommand(category: 0x0E, value: 0x01)
    // Triggers historical batch enumeration on DATA_FROM_STRAP (category=0x16).
    // 8-byte format confirmed working on device; repo suggests 16-byte but unverified.
    static let syncTrigger = buildCommand(category: 0x16, value: 0x00)

    // Requests a specific historical batch by ID.
    // §6.4 format: 16-byte command [aa 10 00 57 23] → xorOut 0xF43F44AC
    //   [header 5B][counter 1B][17 01][batch_id 4B LE][padding 4B] + CRC
    static func buildBatchRequest(batchID: UInt32) -> Data {
        var msg: [UInt8] = [0xaa, 0x10, 0x00, 0x57, 0x23, 0x70, 0x17, 0x01]
        withUnsafeBytes(of: batchID.littleEndian) { msg.append(contentsOf: $0) }
        msg.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let crc = whoopCRC(msg)
        withUnsafeBytes(of: crc.littleEndian) { msg.append(contentsOf: $0) }
        return Data(msg)
    }
}
