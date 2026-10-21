import Foundation

/// The journal file format — a contract (only forward, with a new `formatVersion`).
///
/// A journal file is immutable and written whole: first under a temporary name, then renamed.
/// Its name is `journal-<deviceId>-<sequence, 10 digits>.json`; the same two values are inside.
/// Content is one JSON object (keys sorted, no trailing newline, so every proper prefix of a
/// file is invalid JSON and a torn file can never pass for a whole one):
///
///     { "deviceId": "…", "deviceName": "…", "entries": [ … ], "formatVersion": 1,
///       "sequence": 7 }
///
/// An entry carries the *whole row* (`fields`), never a diff: money as integer `*_e4`
/// (`SyncValue.int`), instants as UTC text `YYYY-MM-DDTHH:MM:SSZ` (`SyncInstant`), UUIDs as
/// text. A delete is soft: an entry with `op = deleted` and the row as it stands deleted.
public enum SyncFormat {
  /// The newest format this build reads and writes.
  public static let currentVersion = 1
  public static let filePrefix = "journal-"
  public static let fileSuffix = ".json"
  /// The name a file has while it is being written; readers never look at it.
  public static let temporaryPrefix = ".writing-"

  public static func fileName(deviceId: String, sequence: Int) -> String {
    let digits = String(sequence)
    let padded = String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    return "\(filePrefix)\(deviceId)-\(padded)\(fileSuffix)"
  }

  /// `nil` for a name that is not a journal file (temporary files, strangers).
  public static func parse(fileName: String) -> (deviceId: String, sequence: Int)? {
    guard fileName.hasPrefix(filePrefix), fileName.hasSuffix(fileSuffix) else { return nil }
    let core = fileName.dropFirst(filePrefix.count).dropLast(fileSuffix.count)
    guard let dash = core.lastIndex(of: "-") else { return nil }
    let device = String(core[core.startIndex..<dash])
    let digits = core[core.index(after: dash)...]
    guard SyncDevice.isValid(id: device), digits.count == 10,
      digits.allSatisfy({ $0.isASCII && $0.isNumber }), let sequence = Int(digits)
    else { return nil }
    return (device, sequence)
  }
}

public enum SyncDevice {
  /// Letters, digits and hyphens: it sits inside a file name.
  public static func isValid(id: String) -> Bool {
    !id.isEmpty && id.count <= 64
      && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }
}

/// A moment in UTC, `YYYY-MM-DDTHH:MM:SSZ` — the form the database stores. The fixed width makes
/// the text order the time order.
public struct SyncInstant: Hashable, Comparable, Sendable, Codable {
  public let text: String

  public init?(_ text: String) {
    let c = Array(text.utf8)
    guard c.count == 20 else { return nil }
    for (i, b) in c.enumerated() {
      switch i {
      case 4, 7: if b != UInt8(ascii: "-") { return nil }
      case 10: if b != UInt8(ascii: "T") { return nil }
      case 13, 16: if b != UInt8(ascii: ":") { return nil }
      case 19: if b != UInt8(ascii: "Z") { return nil }
      default: if !(48...57).contains(b) { return nil }
      }
    }
    self.text = text
  }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let value = SyncInstant(raw) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "not a UTC instant"))
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(text)
  }

  public static func < (a: SyncInstant, b: SyncInstant) -> Bool { a.text < b.text }
}

/// A field value. No floating point exists here on purpose: money is `*_e4` integers.
public enum SyncValue: Hashable, Sendable, Codable {
  case null
  case bool(Bool)
  case int(Int64)
  case string(String)

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int64.self) {
      self = .int(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unsupported field value"))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    }
  }
}

public enum SyncOp: String, Hashable, Sendable, Codable {
  case created, updated, deleted
}

/// A table and a row id: what a change is about.
public struct RecordKey: Hashable, Comparable, Sendable, Codable {
  public var table: String
  public var uuid: String
  public init(table: String, uuid: String) {
    self.table = table
    self.uuid = uuid
  }
  public static func < (a: RecordKey, b: RecordKey) -> Bool {
    (a.table, a.uuid) < (b.table, b.uuid)
  }
}

/// A version of a row: when it was made and by whom. Also names the version an edit was made
/// on top of, which is how two edits tell "one followed the other" from "made apart".
public struct VersionStamp: Hashable, Comparable, Sendable, Codable {
  public var updatedAt: SyncInstant
  public var deviceId: String
  public init(updatedAt: SyncInstant, deviceId: String) {
    self.updatedAt = updatedAt
    self.deviceId = deviceId
  }
  public static func < (a: VersionStamp, b: VersionStamp) -> Bool {
    (a.updatedAt, a.deviceId) < (b.updatedAt, b.deviceId)
  }
}

public struct SyncEntry: Hashable, Sendable, Codable {
  public var table: String
  public var uuid: String
  public var op: SyncOp
  public var fields: [String: SyncValue]
  public var updatedAt: SyncInstant
  /// The version this edit replaced, if the writer knew it (`nil` for a creation).
  public var base: VersionStamp?

  public init(
    table: String, uuid: String, op: SyncOp, fields: [String: SyncValue],
    updatedAt: SyncInstant, base: VersionStamp? = nil
  ) {
    self.table = table
    self.uuid = uuid
    self.op = op
    self.fields = fields
    self.updatedAt = updatedAt
    self.base = base
  }

  public var key: RecordKey { RecordKey(table: table, uuid: uuid) }

  var isWellFormed: Bool {
    !uuid.isEmpty && !table.isEmpty
      && table.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }
  }
}

public struct JournalFile: Hashable, Sendable, Codable {
  public var formatVersion: Int
  public var deviceId: String
  public var deviceName: String
  public var sequence: Int
  public var entries: [SyncEntry]

  public init(
    deviceId: String, deviceName: String, sequence: Int, entries: [SyncEntry],
    formatVersion: Int = SyncFormat.currentVersion
  ) {
    self.formatVersion = formatVersion
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.sequence = sequence
    self.entries = entries
  }

  public var name: String { SyncFormat.fileName(deviceId: deviceId, sequence: sequence) }
}

/// Why a file was refused. Never a crash, never a partial application.
public enum SyncError: Error, Hashable, Sendable {
  /// Written by a newer build: update the app. Nothing of the file is used.
  case unsupportedFormatVersion(found: Int, supported: Int)
  /// Not JSON, cut short, or shaped wrong — a torn or damaged file. Retried next time.
  case malformed
  /// The name and the content disagree about device or sequence.
  case nameMismatch
  /// A file already applied is now different bytes.
  case fileChanged(name: String)
  case codec
}

/// Extension point for encryption: the bytes in the file are `codec.encode(json)`. Identity
/// today (the owner's question about encrypting the folder is open); a real codec brings its
/// key and its test vectors later.
public protocol PayloadCodec: Sendable {
  func encode(_ plain: Data) throws -> Data
  func decode(_ stored: Data) throws -> Data
}

public struct IdentityCodec: PayloadCodec {
  public init() {}
  public func encode(_ plain: Data) throws -> Data { plain }
  public func decode(_ stored: Data) throws -> Data { stored }
}

public enum JournalCoder {
  public static func encode(
    _ file: JournalFile, codec: any PayloadCodec = IdentityCodec()
  ) throws
    -> Data
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try codec.encode(try encoder.encode(file))
  }

  private struct Header: Decodable { var formatVersion: Int }

  public static func decode(
    _ data: Data, codec: any PayloadCodec = IdentityCodec()
  ) throws
    -> JournalFile
  {
    let plain: Data
    do { plain = try codec.decode(data) } catch { throw SyncError.codec }
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(Header.self, from: plain) else {
      throw SyncError.malformed
    }
    // A newer file may be shaped differently: refuse by version before reading the rest.
    guard header.formatVersion <= SyncFormat.currentVersion else {
      throw SyncError.unsupportedFormatVersion(
        found: header.formatVersion, supported: SyncFormat.currentVersion)
    }
    guard header.formatVersion >= 1, let file = try? decoder.decode(JournalFile.self, from: plain)
    else { throw SyncError.malformed }
    guard SyncDevice.isValid(id: file.deviceId), file.sequence >= 0,
      file.entries.allSatisfy(\.isWellFormed)
    else { throw SyncError.malformed }
    return file
  }
}
