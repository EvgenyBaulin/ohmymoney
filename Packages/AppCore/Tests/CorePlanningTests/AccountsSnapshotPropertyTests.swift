import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Счета» on random books: accounts with several currencies, groups in and out of the
/// summary, archived accounts and groups, counts in some currencies only, rates missing for
/// some. Every total is the sum of what could be counted and converted — each balance at
/// today's rate, rounded on its own — and «Всего» is the groups in the summary.
@Suite("Accounts and their totals on random books")
struct AccountsSnapshotPropertyTests {
  static let seeds: [UInt64] = Array(1...30)

  static func uid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "ACC00000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  struct Book {
    var accounts: [PaymentMethod] = []
    var groups: [AccountGroup] = []
    var reconciliation = Reconciliation(
      id: uid(1), date: DateOnly(year: 2026, month: 9, day: 10),
      reconciledAt: CalendarContext.utc.noon(of: DateOnly(year: 2026, month: 9, day: 10)),
      actualTotalRubE4: .zero, kind: .accounts)
    var counts: [ReconciledBalance] = []
    var rates: [CurrencyCode: Decimal] = [:]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      let currencies: [CurrencyCode] = [.rub, .usd, .eur, CurrencyCode("KZT"), CurrencyCode("GEL")]
      for currency in currencies where currency != .rub && random.chance(3, outOf: 4) {
        rates[currency] = Decimal(random.int(in: 1...20_000)) / 100
      }
      for index in 0..<random.int(in: 0...3) {
        groups.append(
          AccountGroup(
            id: uid(10 + index), name: "Group \(index)", inSummary: random.chance(1, outOf: 2),
            archived: random.chance(1, outOf: 5)))
      }
      for index in 0..<random.int(in: 1...6) {
        var held = [random.choice(from: currencies)]
        for other in currencies where !held.contains(other) && random.chance(1, outOf: 4) {
          held.append(other)
        }
        accounts.append(
          PaymentMethod(
            id: uid(100 + index), name: "Account \(index)", currency: held[0],
            isDefault: index == 0, archived: index > 0 && random.chance(1, outOf: 6),
            groupId: index > 0 && !groups.isEmpty && random.chance(1, outOf: 2)
              ? random.choice(from: groups).id : nil,
            otherCurrencies: Array(held.dropFirst())))
        for currency in held where random.chance(2, outOf: 3) {
          counts.append(
            ReconciledBalance(
              id: uid(1_000 + counts.count), reconciliationId: reconciliation.id,
              accountId: uid(100 + index), currency: currency,
              actualE4: AmountE4(raw: Int64(random.int(in: -10_000_000...900_000_000)) * 100)))
        }
      }
    }

    var snapshot: AccountsSnapshot {
      let balances = AccountBalances.build(
        entries: [], transfers: [], debtEntries: [], debts: [:],
        reconciliations: [reconciliation], balances: counts, accounts: accounts,
        tree: CategoryTree([]),
        now: CalendarContext.utc.noon(of: DateOnly(year: 2026, month: 9, day: 19)),
        calendar: .utc)
      return AccountsSnapshot.build(
        balances: balances, accounts: accounts, groups: groups, rubPerUnit: rates,
        locale: Locale(identifier: "en"))
    }

    /// The group an account counts under: its group while that group is live.
    func group(of account: PaymentMethod) -> AccountGroup? {
      groups.first { $0.id == account.groupId && !$0.archived }
    }

    func inSummary(_ account: PaymentMethod) -> Bool { group(of: account)?.inSummary ?? true }

    /// The rubles of an account's counted balances, and whether any was converted.
    func rubles(of account: PaymentMethod) -> (total: AmountE4, converted: Bool, counted: Bool) {
      var total = AmountE4.zero
      var converted = false
      var counted = false
      for count in counts where count.accountId == account.id {
        counted = true
        if let rub = SubscriptionMath.rubles(
          count.actualE4, in: count.currency, rubPerUnit: rates)
        {
          total += rub
          converted = true
        }
      }
      return (total, converted, counted)
    }
  }

  /// Every live account is in exactly one section — its live group's, or the one of no
  /// group — and no archived account is in any.
  @Test(arguments: seeds)
  func everyLiveAccountIsInItsSection(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.snapshot
    let listed = snapshot.sections.flatMap(\.accounts).map(\.account.id)
    #expect(Set(listed).count == listed.count, "seed \(seed)")
    #expect(Set(listed) == Set(book.accounts.filter { !$0.archived }.map(\.id)), "seed \(seed)")
    for section in snapshot.sections {
      for line in section.accounts {
        #expect(book.group(of: line.account)?.id == section.group?.id, "seed \(seed)")
      }
      #expect(section.inSummary == (section.group?.inSummary ?? true))
    }
    // The main account is the first row.
    #expect(snapshot.sections.first?.accounts.first?.account.isDefault == true, "seed \(seed)")
  }

  /// An account's total, its section's and «Всего» are the sums of the counted balances that
  /// have a rate, each converted and rounded on its own; a total that converted nothing is no
  /// total, and «Всего» waits only for a first count.
  @Test(arguments: seeds)
  func theTotalsAreTheSumsOfWhatCouldBeConverted(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.snapshot
    var all = AmountE4.zero
    var anyCounted = false
    for section in snapshot.sections {
      var sectionTotal = AmountE4.zero
      var sectionConverted = false
      for line in section.accounts {
        let model = book.rubles(of: line.account)
        #expect(line.totalRub == (model.converted ? model.total : nil), "seed \(seed)")
        sectionTotal += model.total
        sectionConverted = sectionConverted || model.converted
        if section.inSummary, model.counted { anyCounted = true }
      }
      #expect(section.totalRub == (sectionConverted ? sectionTotal : nil), "seed \(seed)")
      if section.inSummary { all += sectionTotal }
    }
    #expect(snapshot.inSummaryTotalRub == (anyCounted ? all : nil), "seed \(seed)")
  }

  /// What is kept out of «Всего» is decided by the account's live group — archived accounts
  /// too, so a payment still pointing at one follows its money; an account of no group, of an
  /// archived group, or none at all counts.
  @Test(arguments: seeds)
  func whatIsInTheSummary(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.snapshot
    for account in book.accounts {
      #expect(snapshot.isInSummary(account.id) == book.inSummary(account), "seed \(seed)")
    }
    #expect(snapshot.isInSummary(nil))
    #expect(snapshot.isInSummary(Self.uid(999)))
  }

  /// The balances never counted are listed as waiting for a count — the held currencies of
  /// live accounts, in the order of the sidebar — and are in no total.
  @Test(arguments: seeds)
  func whatWasNeverCountedIsListed(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.snapshot
    var model: [BalanceKey] = []
    for line in snapshot.sections.flatMap(\.accounts) {
      for currency in line.account.currencies
      where !book.counts.contains(where: {
        $0.accountId == line.account.id && $0.currency == currency
      }) {
        model.append(BalanceKey(accountId: line.account.id, currency: currency))
      }
    }
    #expect(snapshot.unanchored == model, "seed \(seed)")
  }
}
