import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// An SMS of a bank uses and teaches the same memory as the statements. Texts are made up.
@Suite("An SMS of a bank uses what the statements learned, and teaches them")
struct AutoEntryMemoryTests {
  private let account = UUID()
  private let bank = UUID()
  private let place = UUID()
  private let category = UUID()
  private let today = DateOnly(year: 2026, month: 9, day: 14)

  private var scope: BankTextMemory.Scope { .init(accountId: account, bankId: bank) }

  private func message(_ text: String) -> BankMessage? {
    BankTextParser().parse(text, today: today)
  }

  private func typed(
    _ whole: Int64, source: String? = nil, account: UUID? = nil, deleted: Bool = false
  ) -> TransactionEntry {
    let id = UUID()
    var transaction = Transaction(
      id: id, kind: .expense, occurredAt: Date(timeIntervalSince1970: 0), currency: .rub,
      amountE4: AmountE4(whole: whole), note: "Кофе", placeId: place,
      paymentMethodId: account ?? self.account, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0))
    transaction.source = source
    if deleted { transaction.deletedAt = Date(timeIntervalSince1970: 1) }
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category, amountE4: AmountE4(whole: whole),
          forWhom: .partner)
      ])
  }

  @Test func smsUsesThePairAStatementLineTaught() throws {
    var memory = BankTextMemory()
    // What a statement line «Оплата в KOFEMANIYA MOSCOW RUS» merged with taught.
    let taught1 = memory.learn(
      scope: scope, kind: .expense, text: "KOFEMANIYA",
      fill: BankTextFill(placeId: place, note: "Кофе", categoryId: category, forWhom: .partner))
    #expect(taught1)
    let sms = try #require(message("MIR-4417 07:55 Покупка 450р KOFEMANIYA Баланс: 12300р"))
    let fill = try #require(AutoEntryMemory.fill(memory, message: sms, scope: scope))
    #expect(fill.placeId == place)
    #expect(fill.categoryId == category)
    // The same shop on a card of another bank is not filled.
    let foreign = BankTextMemory.Scope(accountId: UUID(), bankId: UUID())
    #expect(AutoEntryMemory.fill(memory, message: sms, scope: foreign) == nil)
    // An income of the same name is not either.
    let income = try #require(message("MIR-4417 10:00 Перевод от KOFEMANIYA 2500р Баланс: 15000р"))
    #expect(AutoEntryMemory.fill(memory, message: income, scope: scope) == nil)
  }

  @Test func smsOfAnOperationTypedByHandTeachesTheStatement() throws {
    let sms = try #require(message("Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽"))
    let mine = typed(450)
    let found = try #require(
      AutoEntryMemory.handTyped(
        for: sms, account: account, on: today, entries: [mine, typed(451)], dayOf: { _ in today }))
    #expect(found.id == mine.id)
    var memory = BankTextMemory()
    let taught2 = AutoEntryMemory.learn(&memory, message: sms, entry: found, scope: scope)
    #expect(taught2)
    // A statement's spelling of the same shop finds it.
    let fill = try #require(memory.fill(scope: scope, kind: .expense, text: "Kofemaniya"))
    #expect(fill.note == "Кофе")
    #expect(fill.forWhom == .partner)
    #expect(memory.remembers(operation: mine.id))
  }

  @Test func onlyOneHandTypedOperationOfTheAccountIsAMatch() throws {
    let sms = try #require(message("Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽"))
    func find(_ entries: [TransactionEntry]) -> TransactionEntry? {
      AutoEntryMemory.handTyped(
        for: sms, account: account, on: today, entries: entries, dayOf: { _ in today })
    }
    #expect(find([typed(450), typed(450)]) == nil)
    #expect(find([typed(450, source: "statement")]) == nil)
    #expect(find([typed(450, account: UUID())]) == nil)
    #expect(find([typed(450, deleted: true)]) == nil)
    #expect(
      AutoEntryMemory.handTyped(
        for: sms, account: account, on: today, entries: [typed(450)],
        dayOf: { _ in DateOnly(year: 2026, month: 9, day: 13) }) == nil)
  }
}
