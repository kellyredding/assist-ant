import Foundation
import Security

/// Generates canonical lowercase, hyphenated UUIDv7 strings (RFC 9562): a
/// 48-bit big-endian Unix-millisecond timestamp followed by the version and
/// variant nibbles and random bits. The result is time-ordered (sortable by
/// creation time) and collision-safe at any realistic scale.
///
/// NOTE: the embedded timestamp reflects the *generating device's* clock, so
/// it is suitable only for local creation-order display — never as a sync
/// cursor or conflict-ordering authority (the server's `updatedAt` owns that).
/// Foundation's `UUID` only generates v4, which is why this exists.
enum UUIDv7 {
    /// A new UUIDv7 string, e.g. "0190e4d2-8c1a-7f3b-9a2c-1d4e5f6a7b8c".
    static func generate(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit big-endian Unix epoch milliseconds.
        let millis = UInt64((date.timeIntervalSince1970 * 1000).rounded(.down))
        bytes[0] = UInt8((millis >> 40) & 0xff)
        bytes[1] = UInt8((millis >> 32) & 0xff)
        bytes[2] = UInt8((millis >> 24) & 0xff)
        bytes[3] = UInt8((millis >> 16) & 0xff)
        bytes[4] = UInt8((millis >> 8) & 0xff)
        bytes[5] = UInt8(millis & 0xff)

        // Random for the remaining 10 bytes.
        var random = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        for i in 0..<random.count { bytes[6 + i] = random[i] }

        // Version 7 (high nibble of byte 6) and variant 10xx (high bits of byte 8).
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()  // 32 chars
        let g1 = String(hex.prefix(8))
        let g2 = String(hex.dropFirst(8).prefix(4))
        let g3 = String(hex.dropFirst(12).prefix(4))
        let g4 = String(hex.dropFirst(16).prefix(4))
        let g5 = String(hex.dropFirst(20))
        return "\(g1)-\(g2)-\(g3)-\(g4)-\(g5)"
    }
}
