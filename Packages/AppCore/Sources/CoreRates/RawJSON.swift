import CoreKit
import Foundation

/// A JSON tree in which numbers keep the exact text the document carried.
///
/// `JSONSerialization` and `Codable` both hand numbers back as binary floating point, which
/// would put a rounding error between the published rate and the `Decimal` the ledger stores
/// — money in this project never passes through floating point. Keeping the digits verbatim
/// lets `Decimal(string:)` read the published value with no intermediate step.
indirect enum RawJSON: Equatable {
  case object([String: RawJSON])
  case array([RawJSON])
  case string(String)
  /// The number exactly as written, converted by the caller.
  case number(String)
  case bool(Bool)
  case null

  var objectValue: [String: RawJSON]? {
    if case .object(let members) = self { return members }
    return nil
  }

  var stringValue: String? {
    if case .string(let text) = self { return text }
    return nil
  }

  /// Digits of a number, or of a string that holds one: some mirrors quote their values.
  var numberText: String? {
    switch self {
    case .number(let digits): return digits
    case .string(let text): return text
    default: return nil
    }
  }

  /// Reads the number as a `Decimal`, accepting the exponent form JSON allows.
  var decimalValue: Decimal? {
    guard let text = numberText else { return nil }
    if text.contains("e") || text.contains("E") {
      return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
    return DecimalMath.parse(text)
  }

  var intValue: Int? {
    guard let text = numberText else { return nil }
    return Int(text)
  }

  /// How deep objects and arrays may nest. Both are read by recursion, so without a ceiling
  /// a document of a few hundred thousand brackets — the mirror is somebody else's server,
  /// and a captive portal can answer in its place — runs the stack out and kills the app
  /// instead of raising an error. The mirror's own document nests three levels.
  static let maxDepth = 64

  /// Minimal reader for the subset of JSON the rate mirrors emit. It is deliberately small:
  /// objects, arrays, strings with escapes, numbers as text, the three literals.
  static func parse(_ data: Data) throws -> RawJSON {
    var reader = Reader(bytes: Array(data))
    let value = try reader.value()
    reader.skipWhitespace()
    guard reader.isAtEnd else { throw CoreError.malformedExpression(position: reader.offset) }
    return value
  }

  static func parse(_ text: String) throws -> RawJSON {
    try parse(Data(text.utf8))
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    /// Objects and arrays open around the current position.
    private var depth = 0

    init(bytes: [UInt8]) {
      self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func skipWhitespace() {
      while offset < bytes.count {
        switch bytes[offset] {
        case 0x20, 0x09, 0x0A, 0x0D: offset += 1
        default: return
        }
      }
    }

    mutating func value() throws -> RawJSON {
      skipWhitespace()
      guard offset < bytes.count else {
        throw CoreError.malformedExpression(position: offset)
      }
      switch bytes[offset] {
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        guard depth < RawJSON.maxDepth else {
          throw CoreError.malformedExpression(position: offset)
        }
        depth += 1
        defer { depth -= 1 }
        return bytes[offset] == UInt8(ascii: "{") ? try object() : try array()
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"): return .bool(try literal("true", value: true))
      case UInt8(ascii: "f"): return .bool(try literal("false", value: false))
      case UInt8(ascii: "n"):
        _ = try literal("null", value: true)
        return .null
      default: return .number(try number())
      }
    }

    private mutating func literal(_ text: String, value: Bool) throws -> Bool {
      let wanted = Array(text.utf8)
      guard offset + wanted.count <= bytes.count else {
        throw CoreError.malformedExpression(position: offset)
      }
      for index in 0..<wanted.count where bytes[offset + index] != wanted[index] {
        throw CoreError.malformedExpression(position: offset)
      }
      offset += wanted.count
      return value
    }

    private mutating func object() throws -> RawJSON {
      offset += 1
      var members: [String: RawJSON] = [:]
      skipWhitespace()
      if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
        offset += 1
        return .object(members)
      }
      while true {
        skipWhitespace()
        guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
          throw CoreError.malformedExpression(position: offset)
        }
        let key = try string()
        skipWhitespace()
        guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
          throw CoreError.malformedExpression(position: offset)
        }
        offset += 1
        members[key] = try value()
        skipWhitespace()
        guard offset < bytes.count else {
          throw CoreError.malformedExpression(position: offset)
        }
        if bytes[offset] == UInt8(ascii: ",") {
          offset += 1
          continue
        }
        if bytes[offset] == UInt8(ascii: "}") {
          offset += 1
          return .object(members)
        }
        throw CoreError.malformedExpression(position: offset)
      }
    }

    private mutating func array() throws -> RawJSON {
      offset += 1
      var items: [RawJSON] = []
      skipWhitespace()
      if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
        offset += 1
        return .array(items)
      }
      while true {
        items.append(try value())
        skipWhitespace()
        guard offset < bytes.count else {
          throw CoreError.malformedExpression(position: offset)
        }
        if bytes[offset] == UInt8(ascii: ",") {
          offset += 1
          continue
        }
        if bytes[offset] == UInt8(ascii: "]") {
          offset += 1
          return .array(items)
        }
        throw CoreError.malformedExpression(position: offset)
      }
    }

    private mutating func number() throws -> String {
      let start = offset
      if offset < bytes.count, bytes[offset] == UInt8(ascii: "-") { offset += 1 }
      var digits = 0
      while offset < bytes.count {
        let byte = bytes[offset]
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
          digits += 1
          offset += 1
        case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
          UInt8(ascii: "+"), UInt8(ascii: "-"):
          offset += 1
        default:
          guard digits > 0 else { throw CoreError.malformedExpression(position: start) }
          return text(from: start, to: offset)
        }
      }
      guard digits > 0 else { throw CoreError.malformedExpression(position: start) }
      return text(from: start, to: offset)
    }

    private mutating func string() throws -> String {
      let start = offset
      offset += 1
      var scalars = String.UnicodeScalarView()
      var utf8: [UInt8] = []

      func flush() {
        guard !utf8.isEmpty else { return }
        scalars.append(contentsOf: String(decoding: utf8, as: UTF8.self).unicodeScalars)
        utf8.removeAll(keepingCapacity: true)
      }

      while offset < bytes.count {
        let byte = bytes[offset]
        if byte == UInt8(ascii: "\"") {
          offset += 1
          flush()
          return String(scalars)
        }
        if byte != UInt8(ascii: "\\") {
          utf8.append(byte)
          offset += 1
          continue
        }
        flush()
        offset += 1
        guard offset < bytes.count else {
          throw CoreError.malformedExpression(position: start)
        }
        let escape = bytes[offset]
        offset += 1
        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append(Unicode.Scalar(0x08)!)
        case UInt8(ascii: "f"): scalars.append(Unicode.Scalar(0x0C)!)
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"): scalars.append(try escapedScalar(from: start))
        default: throw CoreError.malformedExpression(position: offset - 1)
        }
      }
      throw CoreError.malformedExpression(position: start)
    }

    /// Reads `\uXXXX`, joining a surrogate pair when one follows.
    private mutating func escapedScalar(from start: Int) throws -> Unicode.Scalar {
      let first = try hexQuad(from: start)
      guard first >= 0xD800, first <= 0xDBFF else {
        guard let scalar = Unicode.Scalar(first) else {
          throw CoreError.malformedExpression(position: start)
        }
        return scalar
      }
      guard offset + 1 < bytes.count, bytes[offset] == UInt8(ascii: "\\"),
        bytes[offset + 1] == UInt8(ascii: "u")
      else { throw CoreError.malformedExpression(position: start) }
      offset += 2
      let second = try hexQuad(from: start)
      guard second >= 0xDC00, second <= 0xDFFF else {
        throw CoreError.malformedExpression(position: start)
      }
      let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
      guard let scalar = Unicode.Scalar(combined) else {
        throw CoreError.malformedExpression(position: start)
      }
      return scalar
    }

    private mutating func hexQuad(from start: Int) throws -> UInt32 {
      guard offset + 4 <= bytes.count else {
        throw CoreError.malformedExpression(position: start)
      }
      var code: UInt32 = 0
      for _ in 0..<4 {
        let byte = bytes[offset]
        let digit: UInt32
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
        default: throw CoreError.malformedExpression(position: start)
        }
        code = code << 4 | digit
        offset += 1
      }
      return code
    }

    private func text(from start: Int, to end: Int) -> String {
      String(decoding: bytes[start..<end], as: UTF8.self)
    }
  }
}
