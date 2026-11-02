import Foundation

/// Why a compressed stream could not be read back.
public enum InflateError: Error, Equatable, Sendable {
  /// The stream ended in the middle of a block.
  case truncated
  /// A block type, a code length or a distance that no valid stream has.
  case corrupt
  /// The output would grow past the limit the caller gave: a zip bomb is refused, not expanded.
  case tooLarge
}

/// Raw DEFLATE (RFC 1951) decompression on plain Swift, for the parts of an `.xlsx` file. The
/// application's platforms have zlib, the Linux build of the core does not promise it, and the
/// core stands on Foundation alone; a spreadsheet is small, so a straightforward decoder is fast
/// enough.
public enum Inflate {
  /// Decompresses `data`. `limit` caps the size of the output.
  public static func decompress(_ data: [UInt8], limit: Int = 256 << 20) throws -> [UInt8] {
    var reader = BitReader(bytes: data)
    var output: [UInt8] = []
    output.reserveCapacity(min(limit, data.count * 4))
    var isFinal = false
    while !isFinal {
      isFinal = try reader.bits(1) == 1
      switch try reader.bits(2) {
      case 0:
        reader.alignToByte()
        let length = try reader.bits(16)
        let complement = try reader.bits(16)
        guard length == ~complement & 0xFFFF else { throw InflateError.corrupt }
        guard output.count + length <= limit else { throw InflateError.tooLarge }
        output.append(contentsOf: try reader.take(length))
      case 1:
        try inflateBlock(&reader, &output, Self.fixedLiterals, Self.fixedDistances, limit)
      case 2:
        let (literals, distances) = try dynamicTables(&reader)
        try inflateBlock(&reader, &output, literals, distances, limit)
      default:
        throw InflateError.corrupt
      }
    }
    return output
  }

  // MARK: Huffman tables

  /// A canonical Huffman code: how many codes there are of each length, and the symbols in
  /// the order of their codes.
  struct Huffman {
    var counts: [Int]
    var symbols: [Int]

    init(lengths: [Int]) throws {
      counts = Array(repeating: 0, count: 16)
      for length in lengths { counts[length] += 1 }
      counts[0] = 0
      var left = 1
      for length in 1..<16 {
        left <<= 1
        left -= counts[length]
        guard left >= 0 else { throw InflateError.corrupt }
      }
      var offsets = Array(repeating: 0, count: 16)
      for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
      symbols = Array(repeating: 0, count: lengths.count)
      for (symbol, length) in lengths.enumerated() where length != 0 {
        symbols[offsets[length]] = symbol
        offsets[length] += 1
      }
    }
  }

  static let fixedLiterals: Huffman = {
    var lengths = Array(repeating: 8, count: 288)
    for index in 144..<256 { lengths[index] = 9 }
    for index in 256..<280 { lengths[index] = 7 }
    // A fixed table is valid by construction.
    return (try? Huffman(lengths: lengths)) ?? Huffman.empty
  }()

  static let fixedDistances: Huffman = {
    (try? Huffman(lengths: Array(repeating: 5, count: 30))) ?? Huffman.empty
  }()

  private static let lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
  ]
  private static let lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  private static let distanceBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
  ]
  private static let codeLengthOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  ]

  private static func dynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
    let literalCount = try reader.bits(5) + 257
    let distanceCount = try reader.bits(5) + 1
    let codeCount = try reader.bits(4) + 4
    guard literalCount <= 286, distanceCount <= 30 else { throw InflateError.corrupt }
    var codeLengths = Array(repeating: 0, count: 19)
    for index in 0..<codeCount { codeLengths[codeLengthOrder[index]] = try reader.bits(3) }
    let codeTable = try Huffman(lengths: codeLengths)
    var lengths: [Int] = []
    lengths.reserveCapacity(literalCount + distanceCount)
    while lengths.count < literalCount + distanceCount {
      let symbol = try decode(&reader, codeTable)
      switch symbol {
      case 0..<16:
        lengths.append(symbol)
      case 16:
        guard let previous = lengths.last else { throw InflateError.corrupt }
        lengths += Array(repeating: previous, count: 3 + (try reader.bits(2)))
      case 17:
        lengths += Array(repeating: 0, count: 3 + (try reader.bits(3)))
      case 18:
        lengths += Array(repeating: 0, count: 11 + (try reader.bits(7)))
      default:
        throw InflateError.corrupt
      }
    }
    guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else {
      throw InflateError.corrupt
    }
    return (
      try Huffman(lengths: Array(lengths[0..<literalCount])),
      try Huffman(lengths: Array(lengths[literalCount...]))
    )
  }

  private static func decode(_ reader: inout BitReader, _ table: Huffman) throws -> Int {
    var code = 0
    var first = 0
    var index = 0
    for length in 1..<16 {
      code |= try reader.bits(1)
      let count = table.counts[length]
      if code - count < first { return table.symbols[index + (code - first)] }
      index += count
      first += count
      first <<= 1
      code <<= 1
    }
    throw InflateError.corrupt
  }

  private static func inflateBlock(
    _ reader: inout BitReader, _ output: inout [UInt8], _ literals: Huffman,
    _ distances: Huffman, _ limit: Int
  ) throws {
    while true {
      let symbol = try decode(&reader, literals)
      if symbol < 256 {
        guard output.count < limit else { throw InflateError.tooLarge }
        output.append(UInt8(symbol))
        continue
      }
      if symbol == 256 { return }
      let lengthIndex = symbol - 257
      guard lengthIndex < lengthBase.count else { throw InflateError.corrupt }
      let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtra[lengthIndex]))
      let distanceSymbol = try decode(&reader, distances)
      guard distanceSymbol < distanceBase.count else { throw InflateError.corrupt }
      let distance =
        distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
      guard distance <= output.count else { throw InflateError.corrupt }
      guard output.count + length <= limit else { throw InflateError.tooLarge }
      let start = output.count - distance
      // Byte by byte: a copy may overlap the bytes it is writing (a run).
      for offset in 0..<length { output.append(output[start + offset]) }
    }
  }
}

extension Inflate.Huffman {
  static let empty = Inflate.Huffman(counts: Array(repeating: 0, count: 16), symbols: [])

  init(counts: [Int], symbols: [Int]) {
    self.counts = counts
    self.symbols = symbols
  }
}

/// Reads a DEFLATE stream bit by bit, least significant bit first.
struct BitReader {
  let bytes: [UInt8]
  private var position = 0
  private var buffer = 0
  private var count = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func bits(_ needed: Int) throws -> Int {
    while count < needed {
      guard position < bytes.count else { throw InflateError.truncated }
      buffer |= Int(bytes[position]) << count
      position += 1
      count += 8
    }
    let value = buffer & ((1 << needed) - 1)
    buffer >>= needed
    count -= needed
    return value
  }

  mutating func alignToByte() {
    buffer = 0
    count = 0
  }

  mutating func take(_ length: Int) throws -> ArraySlice<UInt8> {
    guard position + length <= bytes.count else { throw InflateError.truncated }
    defer { position += length }
    return bytes[position..<position + length]
  }
}
