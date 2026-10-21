import CoreAccounting
import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The layers after the accounts — cards and cashback, planning, references, a later count —:
/// their own sequence of draws, pinned, and the history and the accounts under them left exactly
/// as they drew.
@Suite("The layers of the sample after its accounts")
struct SampleFeatureLayersTests {
  static let seed: UInt64 = 20_260_920

  static func history(language: String = "en") -> SampleDataSet {
    SampleAccountsTests.history(seed: seed, language: language)
  }

  static func layered(
    language: String = "en", now: Date? = nil, demo: Bool = false
  ) -> SampleDataSet {
    history(language: language).withEveryFeature(
      seed: seed, calendar: .moscow, language: language, now: now, demo: demo)
  }

  /// The layers from the cards through the later count, without the ones written after them.
  static func throughTheCounts(language: String = "en", demo: Bool = false) -> SampleDataSet {
    history(language: language).withAccounts(seed: seed, calendar: .moscow, language: language)
      .withLayersThroughTheCounts(
        seed: seed, calendar: .moscow, language: language, now: nil, demo: demo)
  }

  /// What the layers' draws decide: the cards and rules, which operations name a card and what
  /// cashback was typed, the operations, transfers and counts they add, the planning, places and
  /// events they add, and the money they expect at the end.
  static func digest(_ set: SampleDataSet, over accounts: SampleDataSet) -> String {
    let before = Set(accounts.entries.map(\.id))
    var text = ""
    for card in set.cards {
      text += "card \(card.id.uuidString.lowercased())|\(card.accountId.uuidString.lowercased())\n"
    }
    for rule in set.cashbackRules {
      text += "rule \(rule.id.uuidString.lowercased())|\(rule.cardId?.uuidString ?? "-")"
      text += "|\(rule.categoryId?.uuidString ?? "-")|\(rule.month?.iso ?? "-")"
      text += "|\(rule.percent.e4)\n"
    }
    for entry in set.entries {
      let transaction = entry.transaction
      if let card = transaction.cardId {
        text += "named \(transaction.id.uuidString.lowercased())|\(card.uuidString.lowercased())"
        text += "|\(transaction.cashback?.amount.raw ?? -1)\n"
      }
      guard !before.contains(entry.id) else { continue }
      text += transaction.id.uuidString.lowercased()
      text += "|\(Int(transaction.occurredAt.timeIntervalSince1970))"
      text += "|\(Int(transaction.createdAt.timeIntervalSince1970))"
      text += "|\(transaction.amountE4.raw)"
      text += "|\(transaction.paymentMethodId?.uuidString.lowercased() ?? "-")\n"
      for part in entry.parts {
        text += "  \(part.id.uuidString.lowercased())|\(part.amountE4.raw)\n"
      }
    }
    let transfers = Set(accounts.transfers.map(\.id))
    for transfer in set.transfers where !transfers.contains(transfer.id) {
      text += "transfer \(transfer.id.uuidString.lowercased())"
      text += "|\(Int(transfer.occurredAt.timeIntervalSince1970))|\(transfer.fromAmountE4.raw)\n"
    }
    for balance in set.reconciledBalances.dropFirst(accounts.reconciledBalances.count) {
      text += "count \(balance.id.uuidString.lowercased())|\(balance.actualE4.raw)"
      text += "|\(balance.expectedE4?.raw ?? 0)|\(balance.transactionId?.uuidString ?? "-")\n"
    }
    let planning = set.planning
    for payment in planning.scheduled {
      text += "payment \(payment.id.uuidString.lowercased())|\(payment.amountE4.raw)"
      text += "|\(payment.nextDate?.iso ?? "-")\n"
    }
    for income in planning.expected {
      text += "expected \(income.id.uuidString.lowercased())|\(income.dueDate?.iso ?? "-")\n"
    }
    for place in set.places.dropFirst(accounts.places.count) {
      text += "place \(place.id.uuidString.lowercased())\n"
    }
    for event in set.events where !accounts.events.contains(where: { $0.id == event.id }) {
      text += "event \(event.id.uuidString.lowercased())|\(event.startDate.iso)\n"
    }
    for (key, amount) in set.accountExpectations.sorted(by: { $0.key < $1.key }) {
      text += "end \(key.accountId.uuidString.lowercased())|\(key.currency.code)|\(amount.raw)\n"
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  /// The layers through the later count; the ones after it pin their own draws
  /// (`SampleLoanAndSavingsTests`).
  @Test func theLayersDrawTheSameSequence() {
    let accounts = Self.history().withAccounts(seed: Self.seed, calendar: .moscow, language: "en")
    let set = Self.throughTheCounts()

    #expect(set.entries.count - accounts.entries.count == 9, "the number of added operations")
    #expect(
      Self.digest(set, over: accounts)
        == "514ead3a369a14c2db621607d44a0eec8eab9ae3a7681c6670d8d90443a7740b",
      """
      The layers after the accounts drew a different sequence. If this was meant — a new
      feature, another amount — put the digest printed by the failure here and say why in the
      commit. If it was not, something asked a layer's random source for one more value.
      """)
  }

  /// Every layer draws from streams of its own: the history keeps the digest the generator pins,
  /// and the accounts under the layers keep theirs — every operation, transfer and count they
  /// wrote is there as they wrote it, whatever card it names now.
  @Test func theHistoryAndTheAccountsKeepTheirDraws() {
    let history = Self.history()
    let accounts = history.withAccounts(seed: Self.seed, calendar: .moscow, language: "en")
    let set = Self.layered()

    let historyIds = Set(history.entries.map(\.id))
    var kept = history
    kept.entries = set.entries.filter { historyIds.contains($0.id) }
    #expect(kept.entries.count == history.entries.count)
    #expect(SampleSequenceTests.digest(kept) == SampleSequenceTests.digest(history))

    let accountIds = Set(accounts.entries.map(\.id))
    var stripped = accounts
    stripped.entries = set.entries.filter { accountIds.contains($0.id) }.map { entry in
      var entry = entry
      entry.transaction.cardId = nil
      entry.transaction.cashback = nil
      return entry
    }
    #expect(stripped.entries == accounts.entries)
    let transferIds = Set(accounts.transfers.map(\.id))
    stripped.transfers = set.transfers.filter { transferIds.contains($0.id) }
    stripped.reconciledBalances = Array(
      set.reconciledBalances.prefix(accounts.reconciledBalances.count))
    #expect(
      SampleAccountsTests.digest(stripped, over: history)
        == SampleAccountsTests.digest(accounts, over: history))
    #expect(
      Array(set.reconciliations.prefix(accounts.reconciliations.count)) == accounts.reconciliations)
    // The capital layer marks the essential spending; nothing else of a category changes.
    let unmarked = set.categories.map { category in
      var category = category
      category.essential = nil
      return category
    }
    #expect(Array(unmarked.prefix(accounts.categories.count)) == accounts.categories)
    #expect(Array(set.places.prefix(accounts.places.count)) == accounts.places)
    // The credit layer gives the main account its main card; nothing else of an account changes.
    let withoutMainCards = set.paymentMethods.map { account in
      var account = account
      account.mainCardId = nil
      return account
    }
    #expect(
      Array(withoutMainCards.prefix(accounts.paymentMethods.count)) == accounts.paymentMethods)
  }

  /// Every live account of the kind «card» has a card named like it, with the id the update of
  /// the database gives it; the main account has a second one.
  @Test func everyLiveCardAccountHasACard() throws {
    let set = Self.layered()
    for account in set.paymentMethods where account.kind == .card && !account.archived {
      let card = try #require(
        set.cards.first { $0.id == CardsMigration.cardId(forAccount: account.id) })
      #expect(card.accountId == account.id)
      #expect(card.name == account.name)
    }
    let main = try #require(set.paymentMethods.first { $0.isDefault })
    #expect(set.cards.filter { $0.accountId == main.id }.map(\.name).contains("Virtual"))
    #expect(
      !set.cards.contains { card in
        set.paymentMethods.first { $0.id == card.accountId }?.kind == .cash
      })
    let russian = Self.layered(language: "ru")
    #expect(russian.cards.contains { $0.name == "Виртуальная" })
  }

  /// About a third of the main account's own purchases name one of its cards.
  @Test func aThirdOfTheMainAccountsPurchasesNameACard() throws {
    let set = Self.layered()
    let main = try #require(set.paymentMethods.first { $0.isDefault })
    let purchases = set.entries.filter { SampleDataSet.namesACard($0, account: main.id) }
    let named = purchases.filter { $0.transaction.cardId != nil }
    #expect(purchases.count > 100)
    #expect(named.count * 100 > purchases.count * 20, "\(named.count) of \(purchases.count)")
    #expect(named.count * 100 < purchases.count * 45, "\(named.count) of \(purchases.count)")
    let cards = Set(set.cards.filter { $0.accountId == main.id }.map(\.id))
    #expect(named.allSatisfy { cards.contains($0.transaction.cardId ?? UUID()) })
    #expect(Set(named.compactMap(\.transaction.cardId)) == cards, "both cards are used")
  }

  /// Applied again, the layers change nothing; the same seed gives the same set.
  @Test func theLayersAreAppliedOnce() {
    let first = Self.layered()
    let again = first.withEveryFeature(seed: Self.seed, calendar: .moscow, language: "en")
    #expect(again.entries == first.entries)
    #expect(again.cards == first.cards)
    #expect(again.reconciledBalances == first.reconciledBalances)
    #expect(again.planning == first.planning)
    let second = Self.layered()
    #expect(second.entries == first.entries)
    #expect(second.accountExpectations == first.accountExpectations)
    #expect(second.expectations == first.expectations)
  }

  /// The demo adds one payment due before the last day and not paid, and nothing else.
  @Test func theDemoAddsOnlyAnOverdueDue() {
    let sample = Self.layered()
    let demo = Self.layered(demo: true)
    #expect(demo.entries == sample.entries)
    #expect(demo.reconciledBalances == sample.reconciledBalances)
    let added = demo.planning.scheduled.filter { payment in
      !sample.planning.scheduled.contains(payment)
    }
    #expect(added.count == 1)
    #expect(added.first.flatMap(\.nextDate).map { $0 < demo.lastDay } == true)
    #expect(!sample.planning.scheduled.contains { ($0.nextDate ?? demo.lastDay) < demo.lastDay })
  }

  /// A set made during its last day holds nothing later than that moment: not an operation, not
  /// the moment one was written, not a transfer or a count.
  @Test func nothingComesAfterTheMomentTheSetIsMade() {
    let day = SampleAccountsTests.endingOn
    for hours in [1, 9, 20] {
      let now = CalendarContext.moscow.startOfDay(day).addingTimeInterval(
        TimeInterval(hours * 3_600))
      let set = SampleAccountsTests.history(seed: Self.seed).withEveryFeature(
        seed: Self.seed, calendar: .moscow, language: "en", now: now)
      #expect(!set.entries.contains { $0.transaction.occurredAt > now }, "\(hours)h")
      #expect(!set.entries.contains { $0.transaction.createdAt > now }, "\(hours)h")
      #expect(!set.transfers.contains { $0.occurredAt > now }, "\(hours)h")
      #expect(!set.reconciliations.contains { ($0.reconciledAt ?? now) > now }, "\(hours)h")
    }
  }

  /// A history of one day has no count to follow and no room for the layers' operations: it gets
  /// its cards and the planning that needs no history, and nothing after the moment it is made.
  @Test func aShortHistoryGetsWhatFits() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let now = CalendarContext.moscow.startOfDay(day).addingTimeInterval(10 * 3_600)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, now: now, calendar: .moscow, language: "en")
    let accounts = history.withAccounts(seed: 3, calendar: .moscow, language: "en", now: now)
    let set = history.withEveryFeature(seed: 3, calendar: .moscow, language: "en", now: now)
    #expect(!set.cards.isEmpty)
    #expect(set.reconciliations == accounts.reconciliations)
    #expect(set.paymentMethods == accounts.paymentMethods)
    #expect(!set.entries.contains { $0.transaction.occurredAt > now })
  }
}
