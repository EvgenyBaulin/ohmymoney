import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What the banks took in a month: fees and the interest on credits.
public struct BankFeesMonth: Hashable, Sendable, Identifiable {
  public var month: MonthKey
  /// «Комиссии» with its subcategories, the fee for service among them, in rubles.
  public var feesRub: AmountE4
  /// Interest paid on loans and credit cards, in rubles.
  public var interestRub: AmountE4

  public init(month: MonthKey, feesRub: AmountE4, interestRub: AmountE4) {
    self.month = month
    self.feesRub = feesRub
    self.interestRub = interestRub
  }

  public var id: MonthKey { month }
  public var totalRub: AmountE4 { feesRub + interestRub }
}

/// «Банкам за год»: the fees and the interest of a year, month by month.
public struct BankFeesYear: Hashable, Sendable {
  public var year: Int
  public var months: [BankFeesMonth]

  public init(year: Int, months: [BankFeesMonth]) {
    self.year = year
    self.months = months
  }

  public var feesRub: AmountE4 { AmountE4.sum(months.map(\.feesRub)) }
  public var interestRub: AmountE4 { AmountE4.sum(months.map(\.interestRub)) }
  public var totalRub: AmountE4 { feesRub + interestRub }
  public var isEmpty: Bool { totalRub.isZero }
}

public enum BankFeesReport {
  /// The prefixes of the operations the app writes for interest it was told of.
  static let interestPrefixes = ["ccinterest:", "debtinterest:", "debtmarkup:"]

  /// The year `year` month by month.
  ///
  /// Fees are the expense parts filed under «Комиссии» (the category the transfer fees go to) or
  /// its subcategories, net of refunds. Interest is the operations the app wrote for interest
  /// (`ccinterest:`, `debtinterest:`, `debtmarkup:`) plus the interest the payments of a loan that
  /// accrues it paid, those the app did not write down on their own counted once.
  public static func year(
    _ year: Int, ledger: Ledger, rubPerUnit: [CurrencyCode: Decimal]
  ) -> BankFeesYear {
    let dataset = ledger.dataset
    var fees: [MonthKey: AmountE4] = [:]
    var interest: [MonthKey: AmountE4] = [:]
    var feeIds = Set<UUID>()
    if case .existing(let id) = TransferRules.feeCategory(
      categories: dataset.categories, remembered: dataset.accountSettings.transferFeeCategoryId)
    {
      feeIds.insert(id)
      for category in dataset.categories where category.parentId == id {
        feeIds.insert(category.id)
      }
    }
    for row in ledger.rows where row.month.year == year && row.kind == .expense {
      guard let id = row.categoryId, feeIds.contains(id) else { continue }
      fees[row.month, default: .zero] += row.contribution
    }
    var written = Set<String>()
    for entry in dataset.entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        let external = transaction.externalId,
        interestPrefixes.contains(where: { external.hasPrefix($0) })
      else { continue }
      let month = ledger.calendar.day(
        of: transaction.occurredAt, recordedIn: transaction.timeZoneId
      )
      .monthKey
      guard month.year == year else { continue }
      interest[month, default: .zero] += transaction.amountRubE4
      let fields = external.split(separator: ":")
      if fields.count >= 2, fields[0] == "debtinterest" { written.insert(String(fields[1])) }
    }
    let journal = dataset.planning.debtEntries
    for debt in dataset.debts
    where debt.direction == .iOwe && debt.accruesInterest && !debt.isDeleted {
      let mine = journal.filter { $0.debtId == debt.id }
      let paid = DebtInterest.interestPaid(
        debt: debt, journal: mine, through: DateOnly(year: year, month: 12, day: 31),
        calendar: ledger.calendar)
      let rate = debt.currency == .rub ? Decimal(1) : (rubPerUnit[debt.currency] ?? 0)
      for entry in mine where entry.kind == .payment {
        guard let day = entry.date, day.year == year,
          let amount = paid[entry.id], amount.raw > 0
        else { continue }
        if let transactionId = entry.transactionId,
          written.contains(transactionId.uuidString.lowercased())
        {
          continue
        }
        let rub = debt.currency == .rub ? amount : InterestMath.cents(amount.decimal * rate)
        interest[day.monthKey, default: .zero] += rub
      }
    }
    let months = (1...12).map { MonthKey(year: year, month: $0) }.map {
      BankFeesMonth(
        month: $0, feesRub: fees[$0] ?? .zero, interestRub: interest[$0] ?? .zero)
    }
    return BankFeesYear(year: year, months: months)
  }

  /// The report as a CSV in the shape of the other reports (`ReportCSV`): `row_type` is `item`
  /// for a month and `total` for the year; `name` is the month `YYYY-MM`, `Total` for the year.
  public static func csv(_ report: BankFeesYear) -> Data {
    var lines = [
      "row_type,name,fees_rub,fees_rub_exact,interest_rub,interest_rub_exact,total_rub,total_rub_exact"
    ]
    // Every field is a token, a month or a number, so none needs quoting.
    func line(_ type: String, _ name: String, _ fees: AmountE4, _ interest: AmountE4) -> String {
      let total = fees + interest
      return [
        type, name, String(fees.wholeRubles), ReportCSV.exact(fees),
        String(interest.wholeRubles), ReportCSV.exact(interest), String(total.wholeRubles),
        ReportCSV.exact(total),
      ].joined(separator: ",")
    }
    for month in report.months {
      lines.append(line("item", month.month.iso, month.feesRub, month.interestRub))
    }
    lines.append(line("total", "Total", report.feesRub, report.interestRub))
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }
}
