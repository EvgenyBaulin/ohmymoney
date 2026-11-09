import CoreKit
import Foundation

/// A receipt split by hand into categories: the QR carries only the total, so the owner says how
/// much of it went to which category. Pure arithmetic over `AmountE4`; the lines become the parts
/// of one operation. Nothing goes to the network (a receipt's own lines are not fetched).
public struct ReceiptSplit: Hashable, Sendable {
  public struct Line: Hashable, Sendable {
    public var categoryId: UUID
    public var amountE4: AmountE4

    public init(categoryId: UUID, amountE4: AmountE4) {
      self.categoryId = categoryId
      self.amountE4 = amountE4
    }
  }

  public enum Problem: Error, Hashable, Sendable {
    /// A line is zero or negative.
    case nonPositiveLine
    /// The lines add up to more than the receipt.
    case exceedsTotal
    /// The lines add up to less than the receipt and no remainder category was chosen.
    case notAllAssigned
  }

  public var total: AmountE4
  public var lines: [Line]

  public init(total: AmountE4, lines: [Line] = []) {
    self.total = total
    self.lines = lines
  }

  /// What the lines leave of the receipt (negative when they exceed it).
  public var remainder: AmountE4 { total - AmountE4.sum(lines.map(\.amountE4)) }

  /// The lines of one category merged, in the order the categories first appear; empty lines
  /// dropped.
  public var merged: [Line] {
    var order: [UUID] = []
    var sums: [UUID: AmountE4] = [:]
    for line in lines where !line.amountE4.isZero {
      if sums[line.categoryId] == nil { order.append(line.categoryId) }
      sums[line.categoryId, default: .zero] += line.amountE4
    }
    return order.map { Line(categoryId: $0, amountE4: sums[$0] ?? .zero) }
  }

  /// The lines that make the operation's parts, with what is left put on `remainderCategory`
  /// when one is given. `nil` category and a remainder: the split is not complete.
  public func parts(remainderCategory: UUID? = nil) -> Result<[Line], Problem> {
    guard lines.allSatisfy({ !$0.amountE4.isNegative }) else { return .failure(.nonPositiveLine) }
    var split = self
    let left = remainder
    if left.isNegative { return .failure(.exceedsTotal) }
    if !left.isZero {
      guard let remainderCategory else { return .failure(.notAllAssigned) }
      split.lines.append(Line(categoryId: remainderCategory, amountE4: left))
    }
    return .success(split.merged)
  }

  /// The total shared equally between the categories; the cents that do not divide go to the
  /// first ones, so the parts always add up to the total.
  public static func evenly(total: AmountE4, among categories: [UUID]) -> ReceiptSplit {
    guard !categories.isEmpty else { return ReceiptSplit(total: total) }
    let shares = total.split(into: categories.count)
    return ReceiptSplit(
      total: total,
      lines: zip(categories, shares).map { Line(categoryId: $0, amountE4: $1) })
  }
}
