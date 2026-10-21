import Foundation

/// SHA-256 exactly as specified by FIPS 180-4.
///
/// `AppCore` may not link CryptoKit: the package has to build on macOS, on Linux and later
/// on Windows, so the digest that guards every file inside a transfer archive is written
/// here in plain Swift. Correctness is pinned by the RFC 6234 vectors in `SHA256Tests`.
///
/// The type is a value: copying a hasher forks its state, which is what `HMACSHA256` uses
/// to keep the precomputed pad blocks.
public struct SHA256: Sendable {
  public static let digestByteCount = 32
  public static let blockByteCount = 64

  /// First 32 bits of the fractional parts of the square roots of the first eight primes.
  private static let initialState: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]

  /// First 32 bits of the fractional parts of the cube roots of the first sixty-four primes.
  private static let roundConstants: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
    0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
    0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
    0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
    0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
    0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
    0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
    0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
    0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
  ]

  private var state: [UInt32] = SHA256.initialState
  private var pending: [UInt8] = [UInt8](repeating: 0, count: SHA256.blockByteCount)
  private var pendingCount = 0
  private var messageByteCount: UInt64 = 0

  public init() {}

  // MARK: - One-shot helpers

  public static func hash(_ bytes: [UInt8]) -> [UInt8] {
    var hasher = SHA256()
    hasher.update(bytes)
    return hasher.finalize()
  }

  public static func hash(_ data: Data) -> [UInt8] {
    hash([UInt8](data))
  }

  public static func hash(_ text: String) -> [UInt8] {
    hash([UInt8](text.utf8))
  }

  /// Lower-case hexadecimal digest, the spelling used inside `manifest.json`.
  public static func hexDigest(_ data: Data) -> String {
    hexString(hash(data))
  }

  public static func hexDigest(_ bytes: [UInt8]) -> String {
    hexString(hash(bytes))
  }

  public static func hexDigest(_ text: String) -> String {
    hexString(hash(text))
  }

  public static func hexString(_ bytes: [UInt8]) -> String {
    let alphabet: [UInt8] = [UInt8]("0123456789abcdef".utf8)
    var characters = [UInt8]()
    characters.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      characters.append(alphabet[Int(byte >> 4)])
      characters.append(alphabet[Int(byte & 0x0F)])
    }
    return String(decoding: characters, as: UTF8.self)
  }

  // MARK: - Incremental interface

  public mutating func update(_ data: Data) {
    update([UInt8](data))
  }

  public mutating func update(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    messageByteCount &+= UInt64(bytes.count)
    var index = 0
    if pendingCount > 0 {
      let taken = min(SHA256.blockByteCount - pendingCount, bytes.count)
      for offset in 0..<taken { pending[pendingCount + offset] = bytes[index + offset] }
      pendingCount += taken
      index += taken
      if pendingCount == SHA256.blockByteCount {
        SHA256.compress(&state, pending, 0)
        pendingCount = 0
      }
    }
    while bytes.count - index >= SHA256.blockByteCount {
      SHA256.compress(&state, bytes, index)
      index += SHA256.blockByteCount
    }
    if index < bytes.count {
      let taken = bytes.count - index
      for offset in 0..<taken { pending[offset] = bytes[index + offset] }
      pendingCount = taken
    }
  }

  /// Appends the FIPS 180-4 padding and returns the 32-byte digest.
  /// The hasher must not be updated again afterwards.
  public mutating func finalize() -> [UInt8] {
    let bitCount = messageByteCount &* 8
    pending[pendingCount] = 0x80
    pendingCount += 1
    if pendingCount > SHA256.blockByteCount - 8 {
      for offset in pendingCount..<SHA256.blockByteCount { pending[offset] = 0 }
      SHA256.compress(&state, pending, 0)
      pendingCount = 0
    }
    for offset in pendingCount..<(SHA256.blockByteCount - 8) { pending[offset] = 0 }
    for offset in 0..<8 {
      pending[SHA256.blockByteCount - 8 + offset] =
        UInt8(truncatingIfNeeded: bitCount >> (56 - 8 * offset))
    }
    SHA256.compress(&state, pending, 0)

    var digest = [UInt8](repeating: 0, count: SHA256.digestByteCount)
    for word in 0..<8 {
      let value = state[word]
      digest[word * 4] = UInt8(truncatingIfNeeded: value >> 24)
      digest[word * 4 + 1] = UInt8(truncatingIfNeeded: value >> 16)
      digest[word * 4 + 2] = UInt8(truncatingIfNeeded: value >> 8)
      digest[word * 4 + 3] = UInt8(truncatingIfNeeded: value)
    }
    return digest
  }

  // MARK: - Compression function

  @inline(__always)
  private static func rotateRight(_ value: UInt32, _ places: UInt32) -> UInt32 {
    (value >> places) | (value << (32 - places))
  }

  /// Mixes one 64-byte block, read from `bytes` starting at `offset`, into `state`.
  private static func compress(_ state: inout [UInt32], _ bytes: [UInt8], _ offset: Int) {
    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { schedule in
      for index in 0..<16 {
        let base = offset + index * 4
        schedule[index] =
          UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
          | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
      }
      for index in 16..<64 {
        let previous = schedule[index - 15]
        let recent = schedule[index - 2]
        let sigma0 =
          rotateRight(previous, 7) ^ rotateRight(previous, 18) ^ (previous >> 3)
        let sigma1 = rotateRight(recent, 17) ^ rotateRight(recent, 19) ^ (recent >> 10)
        schedule[index] =
          schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
      }

      var a = state[0]
      var b = state[1]
      var c = state[2]
      var d = state[3]
      var e = state[4]
      var f = state[5]
      var g = state[6]
      var h = state[7]

      for index in 0..<64 {
        let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
        let choice = (e & f) ^ (~e & g)
        let temp1 = h &+ sum1 &+ choice &+ roundConstants[index] &+ schedule[index]
        let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = sum0 &+ majority
        h = g
        g = f
        f = e
        e = d &+ temp1
        d = c
        c = b
        b = a
        a = temp1 &+ temp2
      }

      state[0] &+= a
      state[1] &+= b
      state[2] &+= c
      state[3] &+= d
      state[4] &+= e
      state[5] &+= f
      state[6] &+= g
      state[7] &+= h
    }
  }
}
