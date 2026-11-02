import Foundation

/// The files inside a zip, read from its central directory: what an `.xlsx` is made of. Only
/// stored and deflated entries are read — the two methods every spreadsheet program writes.
/// Sizes come from the central directory, because Excel writes the local headers with the
/// «sizes follow the data» flag and zeros in them.
public struct ZipEntries: Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case notAZip
    case corrupt
    case unsupportedMethod
  }

  struct Entry: Sendable {
    var method: Int
    var compressedSize: Int
    var size: Int
    var localOffset: Int
  }

  private let bytes: [UInt8]
  private let entries: [String: Entry]

  public var names: [String] { entries.keys.sorted() }

  public init(_ data: [UInt8]) throws {
    bytes = data
    entries = try Self.directory(of: data)
  }

  public func contains(_ name: String) -> Bool { entries[name] != nil }

  /// The contents of one file, `nil` when the zip has no such file.
  public func data(_ name: String, limit: Int = 256 << 20) throws -> [UInt8]? {
    guard let entry = entries[name] else { return nil }
    let offset = entry.localOffset
    guard offset + 30 <= bytes.count, Self.u32(bytes, offset) == 0x0403_4B50 else {
      throw Failure.corrupt
    }
    let start = offset + 30 + Self.u16(bytes, offset + 26) + Self.u16(bytes, offset + 28)
    guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt }
    let body = Array(bytes[start..<start + entry.compressedSize])
    switch entry.method {
    case 0:
      return body
    case 8:
      guard entry.size <= limit else { throw InflateError.tooLarge }
      return try Inflate.decompress(body, limit: limit)
    default:
      throw Failure.unsupportedMethod
    }
  }

  /// Whether the bytes start like a zip.
  public static func looksLikeZip(_ data: [UInt8]) -> Bool {
    data.count >= 4 && u32(data, 0) == 0x0403_4B50
  }

  private static func directory(of data: [UInt8]) throws -> [String: Entry] {
    guard looksLikeZip(data), data.count >= 22 else { throw Failure.notAZip }
    // The end record sits in the last 22 bytes plus a comment of at most 64 KiB.
    let lowest = max(0, data.count - 22 - 0xFFFF)
    var end = -1
    var index = data.count - 22
    while index >= lowest {
      if u32(data, index) == 0x0605_4B50 {
        end = index
        break
      }
      index -= 1
    }
    guard end >= 0 else { throw Failure.corrupt }
    let count = u16(data, end + 10)
    var cursor = u32(data, end + 16)
    var result: [String: Entry] = [:]
    for _ in 0..<count {
      guard cursor + 46 <= data.count, u32(data, cursor) == 0x0201_4B50 else {
        throw Failure.corrupt
      }
      let nameLength = u16(data, cursor + 28)
      let extraLength = u16(data, cursor + 30)
      let commentLength = u16(data, cursor + 32)
      guard cursor + 46 + nameLength <= data.count else { throw Failure.corrupt }
      let name = String(decoding: data[cursor + 46..<cursor + 46 + nameLength], as: UTF8.self)
      result[name] = Entry(
        method: u16(data, cursor + 10), compressedSize: u32(data, cursor + 20),
        size: u32(data, cursor + 24), localOffset: u32(data, cursor + 42))
      cursor += 46 + nameLength + extraLength + commentLength
    }
    return result
  }

  static func u16(_ data: [UInt8], _ at: Int) -> Int {
    guard at + 2 <= data.count else { return 0 }
    return Int(data[at]) | Int(data[at + 1]) << 8
  }

  static func u32(_ data: [UInt8], _ at: Int) -> Int {
    guard at + 4 <= data.count else { return 0 }
    return Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16
      | Int(data[at + 3]) << 24
  }
}
