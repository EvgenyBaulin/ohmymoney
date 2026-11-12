import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Archived financial names offer choices by identity")
struct FinancialNamesakeTests {
  @Test func accountAndBankPeriodsIncludeTransfersAndBalanceHistory() throws {
    let bank = Bank(name: "Reserve", archived: true)
    let old = PaymentMethod(name: "Reserve", archived: true, bankId: bank.id)
    let opening = Reconciliation(
      date: SchedFx.day("2020-01-01"), actualTotalRubE4: .zero,
      kind: .opening)
    let book = PlanningBook(
      reconciliations: [opening],
      reconciledBalances: [
        ReconciledBalance(
          reconciliationId: opening.id, accountId: old.id, currency: .rub, actualE4: .zero)
      ])
    let transfer = Transfer(
      occurredAt: SchedFx.noon("2026-03-01"), fromAccountId: old.id,
      fromCurrency: .rub, fromAmountE4: SchedFx.money("10"), toAccountId: UUID(),
      toCurrency: .rub, toAmountE4: SchedFx.money("10"))
    let records = Namesakes.financialRecords(
      accounts: [old], cards: [], banks: [bank],
      entries: [], transfers: [transfer], planning: book, calendar: .utc)
    for record in records {
      #expect(record.record.period?.first == SchedFx.day("2020-01-01").monthKey)
      #expect(record.record.period?.last == SchedFx.day("2026-03-01").monthKey)
    }
  }

  @Test func namesAndAliasesMatchAcrossAccountsAndCardsOnlyInTheArchive() throws {
    let old = PaymentMethod(name: "Old", aliases: ["Travel"], archived: true)
    let live = PaymentMethod(name: "Travel")
    let own = NamesakeRecord(kind: .card, id: UUID(), name: "travel")
    let records = Namesakes.financialRecords(
      accounts: [old, live], cards: [], banks: [],
      entries: [], calendar: .utc)
    let proposal = try #require(Namesakes.financialProposals(for: own, among: records).first)
    #expect(proposal.existing.id == old.id)
    #expect(proposal.existingSpelling == "Travel")
    #expect(proposal.choices == [.renameNew, .renameArchived, .restoreArchived])
    let hidden = Namesakes.hiding(proposal.id, in: "")
    #expect(Namesakes.financialProposals(for: own, among: records, hidden: hidden).isEmpty)
    #expect(
      Namesakes.financialProposals(
        for: NamesakeRecord(kind: .bank, id: UUID(), name: "Travel"),
        among: records
      ).isEmpty)
  }

  @Test func theWarningRemembersWhichAliasOfTheDraftMatched() throws {
    let old = PaymentMethod(name: "Reserve", archived: true)
    let own = NamesakeRecord(kind: .account, id: UUID(), name: "New")
    let records = Namesakes.financialRecords(
      accounts: [old], cards: [], banks: [],
      entries: [], calendar: .utc)
    let proposal = try #require(
      Namesakes.financialProposals(
        for: own, aliases: ["reserve"],
        among: records
      ).first)
    #expect(proposal.newSpelling == "reserve")
    #expect(proposal.existingSpelling == nil)
  }

  @Test func aCardUnderAnArchivedAccountIsArchivedForNamesAndKeepsItsPeriod() throws {
    let old = PaymentMethod(name: "Old", archived: true)
    let card = PaymentCard(accountId: old.id, name: "Gold")
    var entry = SchedFx.operation(1, "2024-05-01", "100", method: old.id)
    entry.transaction.cardId = card.id
    let records = Namesakes.financialRecords(
      accounts: [old], cards: [card], banks: [],
      entries: [entry], calendar: .utc)
    let own = NamesakeRecord(kind: .account, id: UUID(), name: "Gold")
    let proposal = try #require(Namesakes.financialProposals(for: own, among: records).first)
    #expect(proposal.existing.archived)
    #expect(proposal.restoresAccount)
    #expect(proposal.archivedName(locale: Locale(identifier: "en")) == "Gold (May 2024)")
    let related = NamesakeRecord(kind: .account, id: old.id, name: "Gold")
    #expect(Namesakes.financialProposals(for: related, among: records).isEmpty)
  }
}
