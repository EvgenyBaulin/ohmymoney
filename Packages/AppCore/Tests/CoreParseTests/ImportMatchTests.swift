import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Matching what a recogniser read off a screenshot or a receipt against the books. Every
/// operation here is synthetic; the clock is UTC.
struct ImportMatchTests {
  private let account = UUID()
  private let otherAccount = UUID()
  private let day = DateOnly(year: 2026, month: 9, day: 15)
  private let calendar = CalendarContext.utc

  private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
    calendar.moment(calendar.adding(days: dayOffset, to: day), hour: hour, minute: minute)
  }

  /// An operation typed without a time sits at the app's noon of its day.
  private func timeless(dayOffset: Int = 0) -> Date {
    calendar.noon(of: calendar.adding(days: dayOffset, to: day))
  }

  private func candidate(
    _ amount: Int64, at moment: Date? = nil, account: UUID? = nil,
    currency: CurrencyCode = .rub, kind: TransactionKind = .expense,
    charged: (CurrencyCode, Int64)? = nil, transfer: Bool = false
  ) -> ScreenshotCandidate {
    ScreenshotCandidate(
      id: UUID(), accountID: account ?? self.account, kind: kind, currency: currency,
      amount: AmountE4(whole: amount), occurredAt: moment ?? timeless(), isTransfer: transfer,
      chargedCurrency: charged?.0, chargedAmount: charged.map { AmountE4(whole: $0.1) })
  }

  private func item(
    _ amount: Int64 = 1_000, time: TimeOfDay? = nil, currency: CurrencyCode = .rub,
    account: UUID?? = nil
  ) -> RecognizedPurchase {
    RecognizedPurchase(
      kind: .expense, amount: AmountE4(whole: amount), currency: currency, day: day, time: time,
      merchant: "Кофейня", accountID: account ?? self.account)
  }

  private func propose(
    _ item: RecognizedPurchase, _ candidates: [ScreenshotCandidate], holding: Set<UUID> = []
  ) -> ImportMatchOutcome {
    ImportMatch.propose(item, among: candidates, holdingFile: holding, calendar: calendar)
  }

  // MARK: The three branches

  @Test func oneExactOperationIsOfferedToSupplement() {
    let found = candidate(1_000)
    let other = candidate(999)
    #expect(propose(item(), [found, candidate(2_000)]) == .one(found, isSimilar: false))
    #expect(propose(item(), [found, other]) == .one(found, isSimilar: false))
  }

  @Test func severalExactOperationsAreAListWithNothingChosen() {
    let first = candidate(1_000, at: at(9))
    let second = candidate(1_000, at: at(18))
    guard case .several(let list, let similar) = propose(item(), [first, second]) else {
      Issue.record("expected a list")
      return
    }
    #expect(Set(list) == [first, second])
    #expect(!similar)
    // Nothing is preselected: the only way to go on with a list is to name one of it.
    #expect(
      ImportMatch.resolve(.supplement(UUID()), for: .several(list, isSimilar: false))
        == .failure(.notOffered))
  }

  @Test func nothingFitsMeansANewOperation() {
    let outcome = propose(item(), [candidate(3_000), candidate(1_000, kind: .income)])
    #expect(outcome == .none)
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: false), for: outcome)
        == .success(.create))
  }

  @Test func withoutAnAccountNothingIsMatchedAndNothingIsWritten() {
    let outcome = propose(item(account: .some(nil)), [candidate(1_000)])
    #expect(outcome == .needsAccount)
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: true), for: outcome)
        == .failure(.needsAccount))
  }

  // MARK: Time refines

  /// An operation at the app's noon has no time of its own: a screenshot at 12:05 is not
  /// «closer» to it than to an operation the owner typed at 12:30.
  @Test func anInventedNoonIsNoTimeWhenOrderingTheList() {
    let typed = candidate(1_000, at: at(12, 30))
    let noTime = candidate(1_000)
    let farTyped = candidate(1_000, at: at(20))
    let outcome = propose(item(time: TimeOfDay(hour: 12, minute: 5)), [noTime, farTyped, typed])
    #expect(outcome == .several([typed, noTime, farTyped], isSimilar: false))
    // The same order comes from the screenshot matcher the sheet uses.
    let bare = ScreenshotMatch.propose(
      amount: AmountE4(whole: 1_000), kind: .expense, currency: .rub, accountID: account,
      day: day, time: TimeOfDay(hour: 12, minute: 5), among: [noTime, farTyped, typed],
      calendar: calendar)
    #expect(bare.matches == [typed, noTime, farTyped])
  }

  @Test func timeOnlyOrdersItNeverPicksOneOfSeveral() {
    let exactMinute = candidate(1_000, at: at(14, 7))
    let morning = candidate(1_000, at: at(8))
    let outcome = propose(item(time: TimeOfDay(hour: 14, minute: 7)), [morning, exactMinute])
    #expect(outcome == .several([exactMinute, morning], isSimilar: false))
  }

  @Test func aTimelessOperationOfTheNextDayIsOnlySimilar() {
    let nextDay = candidate(1_000, at: timeless(dayOffset: 1))
    let twoDaysOff = candidate(1_000, at: timeless(dayOffset: 2))
    #expect(
      propose(item(time: TimeOfDay(hour: 23, minute: 0)), [nextDay, twoDaysOff])
        == .one(nextDay, isSimilar: true))
  }

  @Test func similarSumsNeedTheReceiptTolerances() {
    let near = candidate(1_040, at: at(13))
    let far = candidate(1_060, at: at(13))
    let outcome = propose(item(time: TimeOfDay(hour: 12, minute: 0)), [near, far])
    #expect(outcome == .one(near, isSimilar: true))
    // A similar operation is no probable duplicate: a new one is written without a second ask.
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: false), for: outcome)
        == .success(.create))
  }

  // MARK: Currency and account

  @Test func anotherCurrencyIsAnotherOperation() {
    #expect(propose(item(), [candidate(1_000, currency: .usd)]) == .none)
    #expect(propose(item(currency: .usd), [candidate(1_000)]) == .none)
  }

  /// A bank screenshot of a purchase abroad shows what the account was charged.
  @Test func whatTheAccountWasChargedMatchesTooForAPurchaseInAnotherCurrency() {
    let abroad = candidate(12, currency: .usd, charged: (.rub, 1_000))
    #expect(propose(item(), [abroad]) == .one(abroad, isSimilar: false))
    #expect(propose(item(12, currency: .usd), [abroad]) == .one(abroad, isSimilar: false))
  }

  @Test func anOperationOfAnotherAccountIsNotOffered() {
    let elsewhere = candidate(1_000, account: otherAccount)
    #expect(propose(item(), [elsewhere]) == .none)
    #expect(propose(item(time: TimeOfDay(hour: 12, minute: 0)), [elsewhere]) == .none)
  }

  @Test func theCardDigitsNameTheAccountOnlyWhenOneAccountHasThem() {
    let card = PaymentCard(accountId: account, name: "Visa", last4: "1234")
    let twin = PaymentCard(accountId: otherAccount, name: "Mir", last4: "1234")
    let old = PaymentCard(accountId: otherAccount, name: "Old", archived: true, last4: "5678")
    #expect(ImportMatch.account(forCard: "1234", cards: [card]) == account)
    #expect(ImportMatch.account(forCard: "*1234", cards: [card]) == account)
    #expect(ImportMatch.account(forCard: "1234", cards: [card, twin]) == nil)
    #expect(ImportMatch.account(forCard: "5678", cards: [old]) == nil)
    #expect(ImportMatch.account(forCard: nil, cards: [card]) == nil)
  }

  // MARK: Duplicates

  @Test func anotherPurchaseOverAnExactMatchNeedsASecondYes() {
    let found = candidate(1_000)
    let outcome = propose(item(), [found])
    #expect(outcome.isProbableDuplicate)
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: false), for: outcome)
        == .failure(.duplicateNeedsConfirmation))
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: true), for: outcome)
        == .success(.create))
    #expect(
      ImportMatch.resolve(.supplement(found.id), for: outcome)
        == .success(.supplement(found.id)))
  }

  @Test func theSameFileOnAnOperationComesBeforeEveryMatch() {
    let holder = candidate(5_000, at: at(9))
    let exact = candidate(1_000)
    let outcome = propose(item(), [exact, holder], holding: [holder.id])
    #expect(outcome == .alreadyAttached(holder))
    #expect(outcome.isProbableDuplicate)
    #expect(ImportMatch.resolve(.supplement(holder.id), for: outcome) == .success(.open(holder.id)))
    #expect(ImportMatch.resolve(.supplement(exact.id), for: outcome) == .failure(.notOffered))
    #expect(
      ImportMatch.resolve(.createNew(confirmedDuplicate: false), for: outcome)
        == .failure(.duplicateNeedsConfirmation))
    // A holder that is not among the live operations (deleted) holds nothing.
    #expect(propose(item(), [exact], holding: [UUID()]) == .one(exact, isSimilar: false))
  }

  @Test func aTransferIsOpenedNotSupplemented() {
    let transfer = candidate(1_000, transfer: true)
    let outcome = propose(item(), [transfer])
    #expect(outcome == .one(transfer, isSimilar: false))
    #expect(
      ImportMatch.resolve(.supplement(transfer.id), for: outcome)
        == .success(.open(transfer.id)))
  }

  // MARK: Split operations

  @Test func aSplitOperationIsMatchedByItsWholeSumNotByAPart() throws {
    let entry = try split(total: 1_000, parts: [600, 400], at: timeless())
    let candidates = ScreenshotMatch.candidates(entries: [entry], transfers: [])
    #expect(propose(item(), candidates) == .one(candidates[0], isSimilar: false))
    #expect(propose(item(600), candidates) == .none)
  }

  // MARK: Supplement fills only what is empty

  @Test func supplementFillsTheEmptyNoteTimeAndCode() throws {
    let entry = try split(total: 1_000, parts: [1_000], at: timeless())
    var recognised = item(time: TimeOfDay(hour: 9, minute: 41))
    recognised.mcc = "5814"
    let (filled, fields) = ImportSupplement.fill(entry, with: recognised, calendar: calendar)
    #expect(fields == [.note, .time, .mcc])
    #expect(filled.transaction.note == "Кофейня")
    #expect(filled.transaction.mcc == "5814")
    #expect(filled.transaction.occurredAt == at(9, 41))
    #expect(filled.transaction.amountE4 == entry.transaction.amountE4)
    #expect(filled.transaction.paymentMethodId == entry.transaction.paymentMethodId)
    #expect(filled.transaction.kind == entry.transaction.kind)
    #expect(filled.parts == entry.parts)
  }

  @Test func supplementKeepsWhatTheOwnerAlreadyWrote() throws {
    var entry = try split(total: 1_000, parts: [1_000], at: at(18, 15))
    entry.transaction.note = "Обед с Аней"
    entry.transaction.mcc = "5812"
    var recognised = item(time: TimeOfDay(hour: 9, minute: 41))
    recognised.mcc = "5814"
    let (filled, fields) = ImportSupplement.fill(entry, with: recognised, calendar: calendar)
    #expect(fields.isEmpty)
    #expect(filled == entry)
  }

  @Test func supplementNeverMovesAnOperationToAnotherDay() throws {
    let entry = try split(total: 1_000, parts: [1_000], at: timeless(dayOffset: 1))
    let (filled, fields) = ImportSupplement.fill(
      entry, with: item(time: TimeOfDay(hour: 23, minute: 50)), calendar: calendar)
    #expect(fields == [.note])
    #expect(filled.transaction.occurredAt == entry.transaction.occurredAt)
  }

  @Test func supplementReadsTheTimeOnTheClockTheOperationWasRecordedIn() throws {
    let bali = try #require(TimeZone(identifier: "Asia/Makassar"))
    let local = CalendarContext(timeZone: bali)
    var entry = try split(total: 1_000, parts: [1_000], at: local.noon(of: day))
    entry.transaction.timeZoneId = bali.identifier
    let (filled, fields) = ImportSupplement.fill(
      entry, with: item(time: TimeOfDay(hour: 21, minute: 0)), calendar: calendar)
    #expect(fields.contains(.time))
    #expect(filled.transaction.occurredAt == local.moment(day, hour: 21, minute: 0))
  }

  @Test func aSplitOperationKeepsItsPartsWhenSupplemented() throws {
    let entry = try split(total: 1_000, parts: [600, 400], at: timeless())
    let (filled, _) = ImportSupplement.fill(
      entry, with: item(time: TimeOfDay(hour: 9, minute: 0)), calendar: calendar)
    #expect(filled.parts == entry.parts)
    #expect(filled.isBalanced)
  }

  @Test func aBlankMerchantOrABadCodeFillsNothing() throws {
    let entry = try split(total: 1_000, parts: [1_000], at: at(10))
    var recognised = item()
    recognised.merchant = "  "
    recognised.mcc = "54115"
    let (_, fields) = ImportSupplement.fill(entry, with: recognised, calendar: calendar)
    #expect(fields.isEmpty)
  }

  // MARK: Helpers

  private func split(total: Int64, parts: [Int64], at moment: Date) throws -> TransactionEntry {
    let id = UUID()
    let transaction = Transaction(
      id: id, kind: .expense, occurredAt: moment, amountE4: AmountE4(whole: total),
      paymentMethodId: account)
    return TransactionEntry(
      transaction: transaction,
      parts: parts.map {
        TransactionPart(transactionId: id, categoryId: UUID(), amountE4: AmountE4(whole: $0))
      })
  }
}
