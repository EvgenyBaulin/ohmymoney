import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Now» of the capital on random books — accounts with several currencies, deposits, groups in
/// and out of the summary, archived accounts and groups, counts in some currencies only,
/// operations and transfers after them, rates missing for some — adds up exactly what the
/// sidebar shows: the accounts and deposits in the summary are «Всего», the groups left out are
/// their totals, and an archived account adds only the money still on it.
@Suite("Net worth now equals the money of the accounts")
struct NetWorthNowEqualsAccountsSnapshotPropertyTest {
  static let seeds: [UInt64] = Array(1...40)

  static func uid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "CA920000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  let today = DateOnly(year: 2026, month: 10, day: 11)

  struct Book {
    var dataset: Dataset
    var rates: [CurrencyCode: Decimal] = [:]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      let calendar = CalendarContext.utc
      let currencies: [CurrencyCode] = [.rub, .usd, .eur, CurrencyCode("KZT")]
      var rates: [CurrencyCode: Decimal] = [:]
      for currency in currencies where currency != .rub && random.chance(3, outOf: 4) {
        rates[currency] = Decimal(random.int(in: 1...20_000)) / 100
      }
      var groups: [AccountGroup] = []
      for index in 0..<random.int(in: 0...3) {
        groups.append(
          AccountGroup(
            id: uid(10 + index), name: "Group \(index)", inSummary: random.chance(1, outOf: 2),
            archived: random.chance(1, outOf: 5)))
      }
      var accounts: [PaymentMethod] = []
      var reconciliations: [Reconciliation] = []
      var counts: [ReconciledBalance] = []
      var entries: [TransactionEntry] = []
      var transfers: [Transfer] = []
      for month in 6...9 where random.chance(2, outOf: 3) || reconciliations.isEmpty {
        let day = DateOnly(year: 2026, month: month, day: random.int(in: 1...28))
        reconciliations.append(
          Reconciliation(
            id: uid(1_000 + month), date: day, reconciledAt: calendar.noon(of: day),
            actualTotalRubE4: .zero, kind: .accounts))
      }
      for index in 0..<random.int(in: 1...6) {
        var held = [random.choice(from: currencies)]
        for other in currencies where !held.contains(other) && random.chance(1, outOf: 4) {
          held.append(other)
        }
        let account = PaymentMethod(
          id: uid(100 + index), name: "Account \(index)", currency: held[0],
          isDefault: index == 0, archived: index > 0 && random.chance(1, outOf: 5),
          groupId: index > 0 && !groups.isEmpty && random.chance(1, outOf: 2)
            ? random.choice(from: groups).id : nil,
          otherCurrencies: Array(held.dropFirst()),
          interest: random.chance(1, outOf: 4)
            ? DepositTerms(rate: Decimal(random.int(in: 1...20)), period: .monthly) : nil,
          cushion: random.chance(1, outOf: 3))
        accounts.append(account)
        for currency in held {
          for reconciliation in reconciliations where random.chance(1, outOf: 2) {
            counts.append(
              ReconciledBalance(
                id: uid(10_000 + counts.count), reconciliationId: reconciliation.id,
                accountId: account.id, currency: currency,
                actualE4: AmountE4(raw: Int64(random.int(in: -1_000_000...90_000_000)) * 100)))
          }
          for _ in 0..<random.int(in: 0...3) {
            let day = DateOnly(
              year: 2026, month: random.int(in: 6...10), day: random.int(in: 1...28))
            let number = entries.count
            let id = uid(100_000 + number)
            let amount = AmountE4(raw: Int64(random.int(in: 1...5_000_000)) * 100)
            let kind: TransactionKind = random.chance(1, outOf: 3) ? .income : .expense
            entries.append(
              TransactionEntry(
                transaction: Transaction(
                  id: id, kind: kind, occurredAt: calendar.noon(of: day), currency: currency,
                  amountE4: amount, paymentMethodId: account.id,
                  createdAt: calendar.noon(of: day), updatedAt: calendar.noon(of: day)),
                parts: [
                  TransactionPart(
                    id: uid(200_000 + number), transactionId: id,
                    quality: kind.hasQuality ? .neutral : nil,
                    qualitySource: kind.hasQuality ? .category : nil, amountE4: amount)
                ]))
          }
        }
      }
      for number in 0..<random.int(in: 0...4) where accounts.count > 1 {
        let from = random.choice(from: accounts)
        let to = random.choice(from: accounts.filter { $0.id != from.id })
        let day = DateOnly(year: 2026, month: random.int(in: 6...10), day: random.int(in: 1...28))
        let amount = AmountE4(raw: Int64(random.int(in: 1...1_000_000)) * 100)
        transfers.append(
          Transfer(
            id: uid(300_000 + number), occurredAt: calendar.noon(of: day),
            fromAccountId: from.id, fromCurrency: from.mainCurrency, fromAmountE4: amount,
            toAccountId: to.id, toCurrency: to.mainCurrency, toAmountE4: amount))
      }
      dataset = Dataset(
        entries: entries, paymentMethods: accounts,
        planning: PlanningBook(reconciliations: reconciliations, reconciledBalances: counts),
        transfers: transfers, accountGroups: groups)
      self.rates = rates
    }
  }

  @Test(arguments: seeds)
  func nowAddsUpWhatTheSidebarShows(_ seed: UInt64) {
    let book = Book(seed: seed)
    let now = CalendarContext.utc.noon(of: today)
    let accounts = AccountsSnapshot.build(
      dataset: book.dataset, now: now, calendar: .utc, rubPerUnit: book.rates,
      localeIdentifier: "en")
    let capital = CapitalFx.capital(book.dataset, today: today, rates: book.rates)

    // The money still on archived accounts, by whether their group keeps it out of the summary.
    let leftOutGroups = Set(
      book.dataset.accountGroups.filter { !$0.archived && !$0.inSummary }.map(\.id))
    var archivedIn = AmountE4.zero
    var archivedOut = AmountE4.zero
    for account in book.dataset.paymentMethods where account.archived {
      for key in accounts.balances.keys where key.accountId == account.id {
        guard let amount = accounts.balances[key]?.amountE4,
          let rub = NetWorth.rubles(amount, in: key.currency, rate: book.rates[key.currency])
        else { continue }
        if account.groupId.map(leftOutGroups.contains) ?? false {
          archivedOut += rub
        } else {
          archivedIn += rub
        }
      }
    }

    let inSummary = accounts.inSummaryTotalRub ?? .zero
    let excluded = AmountE4.sum(accounts.excluded.compactMap(\.totalRub))
    #expect(
      capital.now.accountsRub + capital.now.depositsRub == inSummary + archivedIn, "seed \(seed)")
    #expect(capital.now.outOfSummaryRub == excluded + archivedOut, "seed \(seed)")

    // Deposits are the accounts with interest terms in the summary.
    var deposits = AmountE4.zero
    var cushion = AmountE4.zero
    for section in accounts.sections {
      for line in section.accounts {
        if section.inSummary, line.account.interest != nil { deposits += line.totalRub ?? .zero }
        if line.account.cushion { cushion += line.totalRub ?? .zero }
      }
    }
    let archivedDeposits = book.dataset.paymentMethods.contains {
      $0.archived && $0.interest != nil
    }
    let archivedCushion = book.dataset.paymentMethods.contains { $0.archived && $0.cushion }
    if !archivedDeposits {
      #expect(capital.now.depositsRub == deposits, "seed \(seed)")
    }
    if !archivedCushion {
      #expect(capital.now.cushionRub == cushion, "seed \(seed)")
    }

    // The breakdown adds up to the figures of «now».
    let have = AmountE4.sum(capital.breakdown.have.compactMap(\.amountRub))
    #expect(have == capital.now.haveRub, "seed \(seed)")
    #expect(capital.now.unanchored.count == Set(capital.now.unanchored).count, "seed \(seed)")
    for key in accounts.unanchored {
      #expect(capital.now.unanchored.contains(key), "seed \(seed)")
    }
  }

  /// Every month end is what the balances held at its last instant, at the rate of its day.
  @Test(arguments: seeds)
  func aMonthEndIsTheBalancesAtItsLastInstant(_ seed: UInt64) {
    let book = Book(seed: seed)
    let now = CalendarContext.utc.noon(of: today)
    let balances = AccountsSnapshot.build(
      dataset: book.dataset, now: now, calendar: .utc, rubPerUnit: book.rates,
      localeIdentifier: "en"
    ).balances
    let dayRates = DayRates(
      series: book.rates.mapValues {
        [DayRate(day: DateOnly(year: 2026, month: 1, day: 1), perUnit: $0)]
      })
    let capital = CapitalFx.capital(
      book.dataset, today: today, rates: book.rates, dayRates: dayRates, months: nil)
    for point in capital.points where !point.isNow {
      let instant = CalendarContext.utc.endOfDay(point.day)
      var total = AmountE4.zero
      for key in balances.keys {
        guard let amount = balances.balance(key, at: instant),
          let rub = NetWorth.rubles(amount, in: key.currency, rate: book.rates[key.currency])
        else { continue }
        total += rub
      }
      #expect(
        point.accountsRub + point.depositsRub + point.outOfSummaryRub == total,
        "seed \(seed) \(point.day)")
    }
  }
}
