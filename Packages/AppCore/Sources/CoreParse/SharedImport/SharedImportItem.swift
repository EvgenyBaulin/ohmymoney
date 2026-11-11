import Foundation

/// The transient handoff between a share extension and the app. Parsing a bank message or
/// reading a receipt still uses the same core readers as a paste or a photo chosen in the app.
public struct SharedImportItem: Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case image, pdf, text }
  public enum Failure: Error, Equatable, Sendable { case invalid, newerVersion }

  public let kind: Kind
  public let data: Data
  public let filename: String
  public var text: String? { kind == .text ? String(data: data, encoding: .utf8) : nil }

  public init(kind: Kind, data: Data, filename: String = "message.txt") throws {
    guard !data.isEmpty, !filename.isEmpty, filename != ".", filename != "..",
      !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0")
    else { throw Failure.invalid }
    if kind == .text {
      guard let text = String(data: data, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw Failure.invalid }
    }
    self.kind = kind
    self.data = data
    self.filename = filename
  }

  private struct Envelope: Codable {
    var version: Int
    var kind: Kind
    var data: Data
    var filename: String
  }

  public func encoded() throws -> Data {
    try JSONEncoder().encode(Envelope(version: 1, kind: kind, data: data, filename: filename))
  }

  public static func decode(_ data: Data) throws -> SharedImportItem {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version <= 1 else { throw Failure.newerVersion }
    guard envelope.version == 1 else { throw Failure.invalid }
    return try SharedImportItem(
      kind: envelope.kind, data: envelope.data, filename: envelope.filename)
  }
}
