import CoreKit
import Foundation

/// The kind of settlement a Russian fiscal receipt reports (`n=` of its QR code).
public enum ReceiptOperation: Int, Hashable, Sendable {
  /// Приход: the shop took money — an ordinary purchase.
  case sale = 1
  /// Возврат прихода: the shop gave the money back — a refund of a purchase.
  case saleReturn = 2
  /// Расход: the shop paid money out.
  case payout = 3
  /// Возврат расхода.
  case payoutReturn = 4

  /// The kind of operation the owner would have written down for it.
  public var transactionKind: TransactionKind {
    switch self {
    case .sale, .payout: .expense
    case .saleReturn, .payoutReturn: .refund
    }
  }
}

/// What the QR code of a cash receipt says, and nothing more: the sum, the day and the minute.
/// The lines of the receipt are not in the code (they are fetched from the tax service by a
/// request to the network, which this app does not make).
public struct ReceiptQR: Hashable, Sendable {
  /// The calendar day printed on the receipt: a clock reading of the shop, with no zone.
  public var day: DateOnly
  public var time: TimeOfDay
  public var second: Int?
  public var amountE4: AmountE4
  public var operation: ReceiptOperation
  /// Fiscal drive number (`fn`), document number (`i`) and fiscal sign (`fp`) when present.
  public var fiscalDrive: String?
  public var documentNumber: String?
  public var fiscalSign: String?

  public var isRefund: Bool { operation.transactionKind == .refund }

  /// The moment the receipt names on the clock of `calendar` — the owner's zone, which is
  /// where a shop on a trip is read too: the receipt carries no zone of its own.
  public func moment(in calendar: CalendarContext) -> Date {
    calendar.moment(day, hour: time.hour, minute: time.minute)
      .addingTimeInterval(TimeInterval(second ?? 0))
  }
}

public enum ReceiptQRParser {
  /// Reads the text of a QR code. Anything that is not a receipt — a link to a site, a
  /// number, a half of a code — is `nil`. The order of the parameters does not matter, extra
  /// ones are ignored, seconds in the time are optional, the sum may have a point or a comma.
  public static func parse(_ text: String) -> ReceiptQR? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let question = body.lastIndex(of: "?") {
      body = String(body[body.index(after: question)...])
    }
    guard !body.isEmpty, body.count < 1_000 else { return nil }
    var values: [String: String] = [:]
    for pair in body.split(separator: "&") {
      let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard halves.count == 2 else { continue }
      let key = halves[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(halves[1]).removingPercentEncoding ?? String(halves[1])
      if values[key] == nil { values[key] = value.trimmingCharacters(in: .whitespaces) }
    }
    guard let moment = values["t"].flatMap(readMoment), let amount = values["s"].flatMap(readSum)
    else { return nil }
    var operation = ReceiptOperation.sale
    if let code = values["n"] {
      guard let number = Int(code), let known = ReceiptOperation(rawValue: number) else {
        return nil
      }
      operation = known
    }
    return ReceiptQR(
      day: moment.day, time: moment.time, second: moment.second, amountE4: amount,
      operation: operation, fiscalDrive: values["fn"].flatMap(nonEmpty),
      documentNumber: values["i"].flatMap(nonEmpty), fiscalSign: values["fp"].flatMap(nonEmpty))
  }

  private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

  /// `20261029T1832` or `20261029T183245`; `-` and `:` between the parts are tolerated.
  private static func readMoment(_ text: String) -> (day: DateOnly, time: TimeOfDay, second: Int?)?
  {
    let compact = text.uppercased().filter { $0 != "-" && $0 != ":" }
    let halves = compact.split(separator: "T", omittingEmptySubsequences: false)
    guard halves.count == 2, halves[0].count == 8, [4, 6].contains(halves[1].count),
      halves.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
    else { return nil }
    func number(_ part: Substring) -> Int { Int(part) ?? -1 }
    let date = halves[0]
    let year = number(date.prefix(4))
    let month = number(date.dropFirst(4).prefix(2))
    let dayOfMonth = number(date.suffix(2))
    let clock = halves[1]
    let hour = number(clock.prefix(2))
    let minute = number(clock.dropFirst(2).prefix(2))
    let second = clock.count == 6 ? number(clock.suffix(2)) : nil
    guard (2000...2100).contains(year), (1...12).contains(month), (0...23).contains(hour),
      (0...59).contains(minute), second.map({ (0...59).contains($0) }) ?? true
    else { return nil }
    let day = DateOnly(year: year, month: month, day: dayOfMonth)
    // A day that is not on the calendar (31 February) comes back as another one.
    guard (1...31).contains(dayOfMonth),
      CalendarContext.utc.day(of: CalendarContext.utc.startOfDay(day)) == day
    else { return nil }
    return (day, TimeOfDay(hour: hour, minute: minute), second)
  }

  /// A sum in roubles with at most four decimals, `1250.50` or `1250,5`; never a sign, never
  /// two separators, never zero.
  private static func readSum(_ text: String) -> AmountE4? {
    let unified = text.replacingOccurrences(of: ",", with: ".")
    let parts = unified.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), !parts[0].isEmpty,
      parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      parts.count == 1 || (1...4).contains(parts[1].count),
      let decimal = Decimal(string: unified, locale: Locale(identifier: "en_US_POSIX")),
      let amount = try? AmountE4(decimal: decimal), amount.raw > 0, amount <= AmountE4.inputLimit
    else { return nil }
    return amount
  }
}
