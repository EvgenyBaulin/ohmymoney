import Foundation

/// CRC-32 (IEEE 802.3, reflected polynomial `0xEDB88320`) — the checksum zip stores for
/// every entry, in both the local header and the central directory.
///
/// The 256-entry table is built once, at first use, and never changes afterwards.
public enum CRC32 {
  private static let table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
      }
      table[index] = value
    }
    return table
  }()

  public static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32
  where Bytes.Element == UInt8 {
    let table = CRC32.table
    var register: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      register = (register >> 8) ^ table[Int((register ^ UInt32(byte)) & 0xFF)]
    }
    return register ^ 0xFFFF_FFFF
  }

  public static func checksum(_ text: String) -> UInt32 {
    checksum(text.utf8)
  }
}
