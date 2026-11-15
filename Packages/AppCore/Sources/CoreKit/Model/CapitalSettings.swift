import Foundation

/// Settings of the capital and the safety cushion, kept in the `settings` table under these
/// keys. A key that is not there means its default, so nothing is ever inserted for them up
/// front; they travel inside the database of the archive.
public struct CapitalSettings: Hashable, Sendable, Codable {
  /// How many months of obligatory spending the cushion should cover, 1…24; absent — no goal.
  public static let targetMonthsKey = "cushion.targetMonths"
  /// The month the cushion should be complete by, `YYYY-MM`; absent — not said.
  public static let targetMonthKey = "cushion.targetMonth"
  /// `1`: the cushion money is kept out of the free sum; default `1`. A stored `0` keeps it in.
  public static let outOfFreeMoneyKey = "cushion.outOfFreeMoney"
  /// How many full months the obligatory spending is taken over, 3…12; default 6.
  public static let historyMonthsKey = "cushion.historyMonths"

  /// The rough sum on all accounts the owner named for the chart of the capital before the
  /// books began, in rubles as a decimal string; absent — not said.
  public static let pastCashKey = "capital.pastCash"
  /// The day (`YYYY-MM-DD`) `pastCashKey` was asked about; the sum means nothing without it.
  public static let pastCashDayKey = "capital.pastCash.on"

  /// Every key these settings live under, and write.
  public static let storageKeys = [
    targetMonthsKey, targetMonthKey, outOfFreeMoneyKey, historyMonthsKey, pastCashKey,
    pastCashDayKey,
  ]

  /// The months a cushion goal can ask for.
  public static let targetMonthsRange = 1...24
  /// The full months the obligatory spending can be taken over.
  public static let historyMonthsRange = 3...12
  /// The months the obligatory spending is taken over when the owner never said.
  public static let defaultHistoryMonths = 6

  /// `nil`: no cushion goal.
  public var targetMonths: Int?
  /// `nil`: no month to be complete by.
  public var targetMonth: MonthKey?
  public var outOfFreeMoney: Bool
  public var historyMonths: Int
  /// `nil`: the owner has not said what was on the accounts before the books began.
  public var pastCash: PastCash?

  public init(
    targetMonths: Int? = nil, targetMonth: MonthKey? = nil, outOfFreeMoney: Bool = true,
    historyMonths: Int = CapitalSettings.defaultHistoryMonths, pastCash: PastCash? = nil
  ) {
    self.pastCash = pastCash
    self.targetMonths = targetMonths
    self.targetMonth = targetMonth
    self.outOfFreeMoney = outOfFreeMoney
    self.historyMonths = historyMonths
  }

  public static let standard = CapitalSettings()

  /// The settings the rows give. A value that does not read or lies outside its range keeps
  /// its default: a damaged value must not stop anything from being computed.
  public init(storedValues values: [String: String]) {
    self.init(
      targetMonths: values[Self.targetMonthsKey].flatMap(Self.number)
        .flatMap { Self.targetMonthsRange.contains($0) ? $0 : nil },
      targetMonth: values[Self.targetMonthKey].flatMap(Self.month),
      outOfFreeMoney: values[Self.outOfFreeMoneyKey].flatMap(Self.switchValue) ?? true,
      historyMonths: values[Self.historyMonthsKey].flatMap(Self.number)
        .flatMap { Self.historyMonthsRange.contains($0) ? $0 : nil }
        ?? Self.defaultHistoryMonths,
      pastCash: PastCash(
        dayText: values[Self.pastCashDayKey], amountText: values[Self.pastCashKey]))
  }

  /// The rows to write. A setting at nothing deletes its key (`nil`): the table keeps no empty
  /// values.
  public var storedValues: [String: String?] {
    [
      Self.targetMonthsKey: targetMonths.map { String($0) },
      Self.targetMonthKey: targetMonth?.iso,
      Self.outOfFreeMoneyKey: outOfFreeMoney ? "1" : "0",
      Self.historyMonthsKey: String(historyMonths),
      Self.pastCashKey: pastCash.map { "\($0.amountE4.decimal)" },
      Self.pastCashDayKey: pastCash?.day.iso,
    ]
  }

  private static func number(_ text: String) -> Int? {
    Int(text.trimmingCharacters(in: .whitespaces))
  }

  /// `YYYY-MM` exactly; a day after it or anything else is not a month.
  private static func month(_ text: String) -> MonthKey? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return nil }
    return MonthKey(iso: trimmed)
  }

  /// `1`/`0` as the app writes switches; `true`/`false` as a person or the Windows port might.
  private static func switchValue(_ text: String) -> Bool? {
    switch text.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true": true
    case "0", "false": false
    default: nil
    }
  }
}

/// What the owner said was on all his accounts, together, on one day before the books began —
/// a rough sum in rubles that only the chart of the capital reads. It is never a balance.
public struct PastCash: Hashable, Sendable, Codable {
  public var day: DateOnly
  /// Never below zero.
  public var amountE4: AmountE4

  public init(day: DateOnly, amountE4: AmountE4) {
    self.day = day
    self.amountE4 = amountE4
  }

  /// Both texts must read, and the sum must not be below zero; anything else is «not said».
  init?(dayText: String?, amountText: String?) {
    guard let dayText, let amountText,
      let day = DateOnly(iso: dayText.trimmingCharacters(in: .whitespaces)),
      let decimal = DecimalMath.parse(amountText.trimmingCharacters(in: .whitespaces)),
      let amount = try? AmountE4(decimal: decimal), !amount.isNegative
    else { return nil }
    self.init(day: day, amountE4: amount)
  }
}
