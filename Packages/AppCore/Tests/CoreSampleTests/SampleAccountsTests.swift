import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The accounts layer over a history: its own sequence of draws, pinned, and the history under
/// it left exactly as the generator drew it.
@Suite("The accounts layer of the sample")
struct SampleAccountsTests {
  static let endingOn = DateOnly(year: 2026, month: 9, day: 18)

  static func history(seed: UInt64 = 20_260_920, language: String = "en") -> SampleDataSet {
    SampleDataGenerator(seed: seed).generate(
      months: 6, endingOn: endingOn, calendar: .moscow, language: language)
  }

  static func layered(seed: UInt64 = 20_260_920, language: String = "en") -> SampleDataSet {
    history(seed: seed, language: language).withAccounts(
      seed: seed, calendar: .moscow, language: language)
  }

  /// What the layer's draws decide: the ids, moments and money of the operations it adds, the
  /// charge of every operation, its transfers, its counts and the balances it expects.
  static func digest(_ set: SampleDataSet, over history: SampleDataSet) -> String {
    let before = Set(history.entries.map(\.id))
    var text = ""
    for entry in set.entries {
      let transaction = entry.transaction
      if let charged = transaction.accountCurrency, let amount = transaction.accountAmountE4 {
        text += "leg \(transaction.id.uuidString.lowercased())|\(charged.code)|\(amount.raw)\n"
      }
      guard !before.contains(entry.id) else { continue }
      text += transaction.id.uuidString.lowercased()
      text += "|\(Int(transaction.occurredAt.timeIntervalSince1970))"
      text += "|\(transaction.kind.rawValue)|\(transaction.currency.code)"
      text += "|\(transaction.amountE4.raw)|\(transaction.amountRubE4.raw)"
      text += "|\(transaction.paymentMethodId?.uuidString.lowercased() ?? "-")\n"
      for part in entry.parts {
        text += "  \(part.id.uuidString.lowercased())|\(part.amountE4.raw)"
        text += "|\(part.refundOfPartId?.uuidString.lowercased() ?? "-")\n"
      }
    }
    for transfer in set.transfers {
      text += "transfer \(transfer.id.uuidString.lowercased())"
      text += "|\(Int(transfer.occurredAt.timeIntervalSince1970))"
      text += "|\(transfer.fromAccountId.uuidString.lowercased())|\(transfer.fromCurrency.code)"
      text += "|\(transfer.fromAmountE4.raw)"
      text += "|\(transfer.toAccountId.uuidString.lowercased())|\(transfer.toCurrency.code)"
      text += "|\(transfer.toAmountE4.raw)\n"
    }
    for balance in set.reconciledBalances {
      text += "count \(balance.id.uuidString.lowercased())|\(balance.currency.code)"
      text += "|\(balance.actualE4.raw)|\(balance.expectedE4?.raw ?? 0)\n"
    }
    for (key, amount) in set.accountExpectations.sorted(by: { $0.key < $1.key }) {
      text += "end \(key.accountId.uuidString.lowercased())|\(key.currency.code)|\(amount.raw)\n"
    }
    for link in set.links {
      text += "link \(link.id.uuidString.lowercased())|\(link.amountE4.raw)\n"
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  /// The starting balances say they are the setup of the accounts, and every row of the sheet
  /// records its difference: the short one has its operation, the others are at zero. Neither
  /// is a draw, so the sequence above does not move.
  @Test func theSheetRecordsAndTheOpeningIsTheSetup() throws {
    let set = Self.layered()
    let opening = try #require(set.reconciliations.first { $0.kind == .opening })
    #expect(opening.origin == .setup)
    let sheet = try #require(set.reconciliations.first { $0.kind == .accounts })
    #expect(sheet.origin == nil)
    let openingRows = set.reconciledBalances.filter { $0.reconciliationId == opening.id }
    let sheetRows = set.reconciledBalances.filter { $0.reconciliationId == sheet.id }
    #expect(!openingRows.isEmpty)
    #expect(openingRows.allSatisfy { $0.recordsDifference == nil && $0.expectedE4 == nil })
    #expect(!sheetRows.isEmpty)
    #expect(sheetRows.allSatisfy { $0.recordsDifference == true && $0.expectedE4 != nil })
    #expect(sheetRows.filter { $0.transactionId != nil }.count == 1)
  }

  @Test func theLayerDrawsTheSameSequence() {
    let history = Self.history()
    let set = history.withAccounts(seed: 20_260_920, calendar: .moscow, language: "en")

    #expect(set.entries.count - history.entries.count == 43, "the number of added operations")
    #expect(set.transfers.count == 13, "the number of transfers")
    #expect(
      Self.digest(set, over: history)
        == "53fb408bfdc931b116036342c426bb19f10fcf3ba01ea1cf16a47fe4b3cb333b",
      """
      The accounts layer drew a different sequence. If this was meant — a new feature, another
      amount — put the digest printed by the failure here and say why in the commit. If it was
      not, something asked the layer's random source for one more value.
      """)
  }

  /// The layer draws from a stream of its own: every operation of the history keeps its id, its
  /// moment, its money and its category, and the digest the generator pins is still the same.
  @Test func theHistoryUnderTheLayerKeepsItsDraws() {
    let history = Self.history()
    let set = Self.layered()
    let ids = Set(history.entries.map(\.id))
    var kept = history
    kept.entries = set.entries.filter { ids.contains($0.id) }
    #expect(kept.entries.count == history.entries.count)
    #expect(SampleSequenceTests.digest(kept) == SampleSequenceTests.digest(history))
    #expect(Array(set.categories.prefix(history.categories.count)) == history.categories)
    #expect(Array(set.people.prefix(history.people.count)) == history.people)
    #expect(Array(set.debtEntries.prefix(history.debtEntries.count)) == history.debtEntries)
    #expect(Array(set.links.prefix(history.links.count)) == history.links)
    #expect(set.paymentMethods.map(\.id).prefix(3) == history.paymentMethods.map(\.id).prefix(3))
  }

  /// What the history knew stays known, and the layer adds only what its own rows spend: no
  /// income, no cashback, no surplus; a purchase in its month and root category, a refund taken
  /// off the month and category of the part it takes back, a part paid for somebody else in
  /// nobody's spending.
  @Test func theLayerOnlyAddsWhatItsOwnRowsSpend() {
    let history = Self.history()
    let set = Self.layered()
    let calendar = CalendarContext.moscow
    let before = Set(history.entries.map(\.id))
    let categories = Dictionary(uniqueKeysWithValues: set.categories.map { ($0.id, $0) })
    var parts: [UUID: (entry: TransactionEntry, part: TransactionPart)] = [:]
    for entry in set.entries {
      for part in entry.parts { parts[part.id] = (entry, part) }
    }
    var spent: [MonthKey: AmountE4] = [:]
    var byRoot: [MonthKey: [UUID?: AmountE4]] = [:]
    func add(_ amount: AmountE4, in month: MonthKey, category: UUID?) {
      spent[month, default: .zero] += amount
      let root = category.flatMap { categories[$0] }.map { $0.parentId ?? $0.id }
      byRoot[month, default: [:]][root, default: .zero] += amount
    }
    for entry in set.entries where !before.contains(entry.id) {
      let month = calendar.day(of: entry.transaction.occurredAt).monthKey
      switch entry.transaction.kind {
      case .expense:
        for part in entry.parts where !part.reimbursable {
          add(part.amountRubE4, in: month, category: part.categoryId)
        }
      case .refund:
        for part in entry.parts {
          guard let target = part.refundOfPartId.flatMap({ parts[$0] }) else {
            Issue.record("a refund of the layer takes back no part")
            continue
          }
          add(
            -part.amountRubE4, in: calendar.day(of: target.entry.transaction.occurredAt).monthKey,
            category: target.part.categoryId)
        }
      default:
        continue
      }
    }
    #expect(!spent.isEmpty)
    func nonZero(_ values: [UUID?: AmountE4]) -> [UUID?: AmountE4] {
      values.filter { !$0.value.isZero }
    }
    for month in Set(history.expectations.monthKeys + set.expectations.monthKeys) {
      let known = history.expectations[month]
      let now = set.expectations[month]
      #expect(now.income == known.income, "\(month.iso): income")
      #expect(now.surplus == known.surplus, "\(month.iso): surplus")
      #expect(now.cashbackByMethod == known.cashbackByMethod, "\(month.iso): cashback")
      #expect(
        now.myExpenses == known.myExpenses + (spent[month] ?? .zero), "\(month.iso): spending")
      var expected = known.byRootCategory
      for (root, amount) in byRoot[month] ?? [:] { expected[root, default: .zero] += amount }
      #expect(nonZero(now.byRootCategory) == nonZero(expected), "\(month.iso): by category")
    }
  }

  /// A row of the layer is the same row whichever day the history ends on. The Debug menu
  /// writes its sample again over the rows it wrote before: an id that meant a purchase with
  /// its parts one day must not mean another purchase, with other parts, the next — the
  /// database refuses to take away a part a refund points at, and the whole sample with it.
  /// Only the difference the sheet writes moves, with the sheet it belongs to.
  @Test func aRowOfTheLayerIsTheSameRowOnAnyDay() {
    let calendar = CalendarContext.moscow
    func layered(endingOn day: Int) -> (set: SampleDataSet, history: Set<UUID>) {
      let history = SampleDataGenerator(seed: 20_260_918).generate(
        months: 6, endingOn: DateOnly(year: 2026, month: 8, day: day), calendar: calendar,
        language: "en")
      return (
        history.withAccounts(seed: 20_260_918, calendar: calendar, language: "en"),
        Set(history.entries.map(\.id))
      )
    }
    for (first, second) in [(6, 20), (11, 29), (1, 31)] {
      let early = layered(endingOn: first)
      let late = layered(endingOn: second)
      var rows: [UUID: TransactionEntry] = [:]
      for entry in late.set.entries where !late.history.contains(entry.id) {
        rows[entry.id] = entry
      }
      var shared = 0
      for entry in early.set.entries where !early.history.contains(entry.id) {
        guard let again = rows[entry.id],
          entry.transaction.externalId?.hasPrefix("reconcile:") != true
        else { continue }
        shared += 1
        let label = "\(first) → \(second): \(entry.id)"
        #expect(again.transaction.kind == entry.transaction.kind, "\(label)")
        #expect(
          calendar.day(of: again.transaction.occurredAt)
            == calendar.day(of: entry.transaction.occurredAt), "\(label)")
        #expect(again.transaction.paymentMethodId == entry.transaction.paymentMethodId, "\(label)")
        #expect(again.parts.map(\.id) == entry.parts.map(\.id), "\(label)")
        #expect(again.parts.map(\.refundOfPartId) == entry.parts.map(\.refundOfPartId), "\(label)")
      }
      #expect(shared > 20, "\(first) → \(second): the rows of the days both histories hold")
      let transfers = Dictionary(uniqueKeysWithValues: late.set.transfers.map { ($0.id, $0) })
      for transfer in early.set.transfers {
        guard let again = transfers[transfer.id] else { continue }
        #expect(
          calendar.day(of: again.occurredAt) == calendar.day(of: transfer.occurredAt)
            && again.from == transfer.from && again.to == transfer.to,
          "\(first) → \(second): transfer \(transfer.id)")
      }
      let links = Dictionary(uniqueKeysWithValues: late.set.links.map { ($0.id, $0) })
      for link in early.set.links {
        guard let again = links[link.id] else { continue }
        #expect(again.partId == link.partId && again.reimbursementTxId == link.reimbursementTxId)
      }
    }
  }

  /// The goal in dollars is on its way on the last day of a history of any length: more than a
  /// third of it is put aside, never all of it.
  @Test(arguments: [6, 12, 24])
  func theGoalInDollarsIsOnItsWay(months: Int) throws {
    for seed: UInt64 in [1, 7, 20_260_918] {
      let set = SampleDataGenerator(seed: seed).generate(
        months: months, endingOn: Self.endingOn, calendar: .moscow, language: "en"
      ).withAccounts(seed: seed, calendar: .moscow, language: "en")
      let goal = try #require(set.goals.first { $0.currency == .usd })
      var saved = Decimal(0)
      for entry in set.entries {
        for part in entry.parts where part.goalId == goal.id {
          saved +=
            entry.transaction.currency == .usd
            ? part.amountE4.decimal : part.amountRubE4.decimal / SampleAccountsWriter.usdRate
        }
      }
      let label = "\(months) months, seed \(seed): \(saved) of \(goal.targetE4.decimal)"
      #expect(saved < goal.targetE4.decimal, "\(label)")
      #expect(saved * 3 > goal.targetE4.decimal, "\(label)")
    }
  }

  /// The money on the card in tenge and in the cash follows what is spent from them: the card
  /// is topped up by about what it spent, cash is taken out for about what cash paid, so
  /// neither piles up money nobody spends however long the history is.
  @Test(arguments: [6, 12, 24])
  func theCardInTengeAndTheCashFollowTheirSpending(months: Int) throws {
    for seed: UInt64 in [1, 7, 20_260_918] {
      let set = SampleDataGenerator(seed: seed).generate(
        months: months, endingOn: Self.endingOn, calendar: .moscow, language: "en"
      ).withAccounts(seed: seed, calendar: .moscow, language: "en")
      let opening = try #require(set.reconciliations.first { $0.kind == .opening })
      let tenge = try #require(
        set.paymentMethods.first { $0.currencies == [SampleAccountsWriter.kzt] })
      let cash = try #require(set.paymentMethods.first { $0.kind == .cash })
      let borrowed = AmountE4.sum(
        set.debtEntries.filter { $0.paymentMethodId == cash.id }.map(\.amountE4))
      for (key, extra) in [
        (BalanceKey(accountId: tenge.id, currency: SampleAccountsWriter.kzt), AmountE4.zero),
        (BalanceKey(accountId: cash.id, currency: .rub), borrowed),
      ] {
        let start = try #require(
          set.reconciledBalances.first {
            $0.reconciliationId == opening.id && $0.key == key
          }
        ).actualE4
        let end = try #require(set.accountExpectations[key])
        let label =
          "\(months) months, seed \(seed), \(key.currency.code): \(start.raw) → \(end.raw)"
        #expect(end.raw <= start.raw * 2 + extra.raw, "\(label)")
      }
    }
  }

  /// Of the two groups, the one in the summary comes first, in either language: the order is
  /// the groups' own, not their names'.
  @Test(arguments: ["en", "ru"])
  func theGroupInTheSummaryComesFirst(language: String) {
    let groups = Self.layered(language: language).accountGroups.sorted { left, right in
      left.sort != right.sort ? left.sort < right.sort : left.name < right.name
    }
    #expect(groups.map(\.inSummary) == [true, false])
  }

  /// Giving the history its accounts draws nothing: rubles stay, and every operation is on an
  /// account that holds its currency or says what that account was charged — in rubles, the
  /// operation's own rubles. Done twice, nothing more changes.
  @Test func assigningAccountsDrawsNothingAndMovesNoRuble() {
    let history = Self.history()
    let assigned = history.assigningAccounts()
    #expect(assigned.assigningAccounts().entries == assigned.entries)
    #expect(assigned.assigningAccounts().paymentMethods == assigned.paymentMethods)
    #expect(assigned.expectations == history.expectations)

    let accounts = Dictionary(uniqueKeysWithValues: assigned.paymentMethods.map { ($0.id, $0) })
    #expect(assigned.paymentMethods.allSatisfy { $0.currency == .rub })
    #expect(assigned.paymentMethods.filter { $0.otherCurrencies == [.usd] }.count == 2)
    for (entry, before) in zip(assigned.entries, history.entries) {
      #expect(entry.id == before.id)
      #expect(entry.transaction.amountRubE4 == before.transaction.amountRubE4)
      #expect(entry.parts == before.parts)
      guard let account = entry.transaction.paymentMethodId.flatMap({ accounts[$0] }) else {
        Issue.record("\(entry.id) is on no account")
        continue
      }
      if account.holds(entry.transaction.currency) {
        #expect(entry.transaction.accountCurrency == nil)
      } else {
        #expect(entry.transaction.accountCurrency == .rub)
        #expect(entry.transaction.accountAmountE4 == entry.transaction.amountRubE4)
      }
    }
    #expect(assigned.entries.contains { $0.transaction.accountCurrency != nil })
  }

  @Test func theSameSeedGivesTheSameLayerAndItIsAppliedOnce() {
    let first = Self.layered()
    let second = Self.layered()
    #expect(first.entries == second.entries)
    #expect(first.transfers == second.transfers)
    #expect(first.reconciledBalances == second.reconciledBalances)
    #expect(first.accountExpectations == second.accountExpectations)
    #expect(first.expectations == second.expectations)

    let again = first.withAccounts(seed: 1, calendar: .moscow, language: "en")
    #expect(again.entries == first.entries)
    #expect(again.paymentMethods == first.paymentMethods)
    #expect(Self.layered(seed: 7).transfers != first.transfers)
  }

  /// Names follow the language of the set; the people and places stay made-up.
  @Test func theNamesFollowTheLanguage() {
    let russian = Self.layered(language: "ru")
    #expect(russian.accountGroups.map(\.name).sorted() == ["Казахстан", "Россия"])
    #expect(russian.paymentMethods.contains { $0.name == "Мультивалютный счёт" })
    #expect(russian.categories.contains { $0.name == "Сверка" && $0.kind == .expense })
    let english = Self.layered()
    #expect(english.accountGroups.map(\.name).sorted() == ["Kazakhstan", "Russia"])
    #expect(english.paymentMethods.contains { $0.name == "Tenge card" })
  }

  /// The birthday with its budget is still to come on the last day of any history, and the New
  /// Year under way or next has a budget — also one the history holds none of, which is under
  /// way on the 28th and 29th of December, before the history's shopping on the 30th. Each is
  /// the only one of its series on its date.
  @Test(arguments: [
    (12, 27, 0), (12, 28, 0), (12, 29, 0), (12, 30, 0), (12, 31, 0), (1, 1, -1), (1, 2, 0),
    (9, 18, 0),
  ])
  func theEventsWithBudgetsAreUnderWayOrToCome(month: Int, day: Int, yearsAhead: Int) {
    let last = DateOnly(year: 2026, month: month, day: day)
    let set = SampleDataGenerator(seed: 11).generate(
      months: 3, endingOn: last, calendar: .moscow, language: "en"
    ).withAccounts(seed: 11, calendar: .moscow, language: "en")
    let birthdays = set.events.filter { $0.kind == .birthday && $0.budgetE4 != nil }
    #expect(birthdays.contains { $0.startDate > last }, "ending \(last)")
    let newYear = DateOnly(year: last.year + yearsAhead, month: 12, day: 28)
    let budgeted = set.events.filter {
      $0.kind == .newYear && $0.budgetE4 != nil && $0.endDate >= last
    }
    #expect(budgeted.map(\.startDate).min() == newYear, "ending \(last)")
    for kind in [EventKind.birthday, .newYear] {
      let starts = set.events.filter { $0.kind == kind }.map(\.startDate)
      #expect(starts.count == Set(starts).count, "\(kind) twice on one date")
    }
  }

  /// A history of a single day has no room for the features: it still gets its accounts, its
  /// opening count and nothing after the moment it is made.
  @Test func aShortHistoryGetsWhatFits() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let now = CalendarContext.moscow.startOfDay(day).addingTimeInterval(10 * 3_600)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, now: now, calendar: .moscow, language: "en")
    let set = history.withAccounts(seed: 3, calendar: .moscow, language: "en", now: now)
    #expect(set.accountGroups.count == 2)
    #expect(set.reconciliations.map(\.kind) == [.opening])
    #expect(set.transfers.isEmpty)
    #expect(!set.entries.contains { $0.transaction.occurredAt > now })
    #expect(set.reconciledBalances.count == 10)
  }
}
