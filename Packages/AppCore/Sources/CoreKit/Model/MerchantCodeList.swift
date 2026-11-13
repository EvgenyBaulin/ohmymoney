import Foundation

/// A set of merchant codes the owner types as «5411, 5811-5814»: single codes and inclusive
/// ranges, kept sorted and merged so that the same set always reads back the same way.
public struct MerchantCodeList: Hashable, Sendable, Codable {
  /// Sorted, non-overlapping, non-adjacent inclusive ranges within 0…9999.
  public private(set) var ranges: [ClosedRange<Int>]

  public static let empty = MerchantCodeList(ranges: [])

  public var isEmpty: Bool { ranges.isEmpty }

  public init(ranges: [ClosedRange<Int>]) {
    let valid = ranges.filter { $0.lowerBound >= 0 && $0.upperBound <= 9999 }
    var merged: [ClosedRange<Int>] = []
    for range in valid.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
        merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    self.ranges = merged
  }

  public init(codes: [Int]) {
    self.init(ranges: codes.map { $0...$0 })
  }

  /// Reads «5411, 5811-5814» (commas, semicolons or spaces between items; «–» and «—» as a
  /// dash); `nil` when any item is not a code or a range of codes. An empty text is the empty
  /// list.
  public init?(parsing text: String) {
    let normalized = text.replacingOccurrences(of: "–", with: "-")
      .replacingOccurrences(of: "—", with: "-")
      .replacingOccurrences(of: "−", with: "-")
    let items = normalized.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init)
    var found: [ClosedRange<Int>] = []
    for item in items {
      let ends = item.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
      guard ends.count <= 2, let low = Self.code(ends[0]),
        let high = ends.count == 2 ? Self.code(ends[1]) : low, low <= high
      else { return nil }
      found.append(low...high)
    }
    self.init(ranges: found)
  }

  private static func code(_ text: String) -> Int? {
    guard let normalized = MerchantCode.normalized(text) else { return nil }
    return Int(normalized)
  }

  public func contains(_ code: Int) -> Bool {
    ranges.contains { $0.contains(code) }
  }

  /// `true` when `mcc` (four digits, `Transaction.mcc`) is in the list; `false` for no code.
  public func contains(_ mcc: String?) -> Bool {
    guard let mcc = MerchantCode.normalized(mcc), let code = Int(mcc) else { return false }
    return contains(code)
  }

  /// The list as it is typed back: «5411, 5811-5814».
  public var text: String {
    ranges.map { range in
      let low = Self.four(range.lowerBound)
      return range.count == 1 ? low : "\(low)-\(Self.four(range.upperBound))"
    }.joined(separator: ", ")
  }

  private static func four(_ code: Int) -> String {
    let digits = String(code)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  // Stored as the typed text, so the file format does not depend on how ranges are kept.
  public init(from decoder: Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let list = MerchantCodeList(parsing: text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "not a list of merchant codes"))
    }
    self = list
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(text)
  }
}
