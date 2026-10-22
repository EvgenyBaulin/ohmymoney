import CoreKit
import Foundation
import Testing

@testable import CoreCSV

private func day(_ d: Int, month: Int = 9) -> DateOnly {
  DateOnly(year: 2026, month: month, day: d)
}

private func op(
  _ whole: Int64, d: Int = 14, minute: Int? = 615, text: String = "SAMPLE CAFE",
  status: StatementStatus = .posted, kind: StatementOperationKind = .purchase,
  counterparty: StatementCounterparty = .init(), index: Int = 0,
  currency: CurrencyCode = .rub, accountAmount: AmountE4? = nil,
  accountCurrency: CurrencyCode? = nil, cashback: AmountE4? = nil
) -> ImportedOperation {
  ImportedOperation(
    profileID: "p", sourceIndex: index, moment: StatementMoment(day: day(d), minuteOfDay: minute),
    status: status, amount: AmountE4(whole: whole), currency: currency,
    accountAmount: accountAmount, accountCurrency: accountCurrency, kind: kind,
    description: text, counterparty: counterparty, merchant: text, cashbackAccrued: cashback)
}

private func parse(
  _ operations: [ImportedOperation], checks: [StatementCheck] = []
)
  -> StatementParseResult
{
  StatementParseResult(
    profileID: "p", header: StatementHeader(), operations: operations, declined: [],
    unparsed: [], checks: checks, usedLegacyEncoding: false)
}

@Suite("The preview says line by line what loading a statement would do")
struct StatementPreviewTests {
  private let today = day(20)

  @Test func everyLineIsNewOnAnEmptyAccount() {
    let preview = StatementPreviewBuilder.build(
      parse: parse([op(-100, index: 0), op(-200, d: 15, index: 1)]), accountKey: "a",
      existing: [], manual: [], identity: StatementIdentity(), today: today)
    #expect(preview.newCount == 2)
    #expect(preview.duplicateCount == 0 && preview.changedCount == 0)
    #expect(preview.rows.allSatisfy { $0.startsTicked })
  }

  @Test func loadingTheSameLinesAgainMakesThemDuplicatesAndUntickedAll() {
    let lines = [op(-100, index: 0), op(-200, d: 15, index: 1)]
    let stored = lines.enumerated().map { index, line in
      StatementExisting(
        id: "e\(index)", key: StatementDedupKey(account: "a", operation: line),
        status: .posted, day: line.moment.day, amount: line.amount, placeKey: line.placeKey)
    }
    let preview = StatementPreviewBuilder.build(
      parse: parse(lines), accountKey: "a", existing: stored, manual: [],
      identity: StatementIdentity(), today: today)
    #expect(preview.duplicateCount == 2)
    #expect(preview.newCount == 0)
    #expect(preview.rows.allSatisfy { !$0.startsTicked })
  }

  @Test func aHeldLineThatIsNowPostedIsAnUpgradeNotASecondLine() {
    let held = op(-100, status: .pending)
    let posted = op(-100, status: .posted)
    let stored = StatementExisting(
      id: "held", key: StatementDedupKey(account: "a", operation: held), status: .pending,
      day: held.moment.day, amount: held.amount, placeKey: held.placeKey)
    let preview = StatementPreviewBuilder.build(
      parse: parse([posted]), accountKey: "a", existing: [stored], manual: [],
      identity: StatementIdentity(), today: today)
    #expect(preview.rows[0].disposition == .statusUpgrade(existingID: "held"))
    #expect(preview.changedCount == 1 && preview.newCount == 0)
  }

  @Test func aHandTypedLineWithinOnePercentMergesAndAFartherOneAsks() {
    let near = StatementManualEntry(id: "m1", day: day(14), amount: AmountE4(whole: -250))
    let merged = StatementPreviewBuilder.build(
      parse: parse([op(-251)]), accountKey: "a", existing: [], manual: [near],
      identity: StatementIdentity(), today: today)
    #expect(merged.rows[0].disposition == .manualMerge(entryID: "m1"))
    let far = StatementManualEntry(id: "m2", day: day(14), amount: AmountE4(whole: -230))
    let asked = StatementPreviewBuilder.build(
      parse: parse([op(-251)]), accountKey: "a", existing: [], manual: [far],
      identity: StatementIdentity(), today: today)
    #expect(asked.rows[0].disposition == .manualAsk(candidateIDs: ["m2"]))
    #expect(!asked.rows[0].startsTicked)
  }

  @Test func aFailedFooterCheckBlocksTheFile() {
    let failed = StatementCheck(
      kind: .footerTotals, passed: false, blocking: true,
      missingExpense: AmountE4(whole: 10), violations: 1)
    let preview = StatementPreviewBuilder.build(
      parse: parse([op(-100)], checks: [failed]), accountKey: "a", existing: [], manual: [],
      identity: StatementIdentity(), today: today)
    #expect(!preview.isImportable)
    #expect(preview.blockingFailures.count == 1)
  }

  @Test func ownTransfersAreRecognisedByTheContractAndByIdentity() {
    let identity = StatementIdentity(phones: ["+7 900 000-00-01"])
    let contract = op(-500, kind: .ownContractTransferOut)
    let byPhone = op(
      -700, kind: .sbpTransferOut, counterparty: StatementCounterparty(phone: "89000000001"))
    let stranger = op(
      -700, kind: .sbpTransferOut, counterparty: StatementCounterparty(phone: "89000000002"))
    #expect(StatementPreviewBuilder.isOwnTransfer(contract, identity: identity))
    #expect(StatementPreviewBuilder.isOwnTransfer(byPhone, identity: identity))
    #expect(!StatementPreviewBuilder.isOwnTransfer(stranger, identity: identity))
    #expect(!StatementPreviewBuilder.isOwnTransfer(op(-5), identity: identity))
  }

  @Test func staleHeldLinesAreOffered() {
    let old = StatementExisting(
      id: "old", key: StatementDedupKey(value: "v1:x"), status: .pending, day: day(1),
      amount: AmountE4(whole: -9), placeKey: "x")
    let preview = StatementPreviewBuilder.build(
      parse: parse([op(-100)]), accountKey: "a", existing: [old], manual: [],
      identity: StatementIdentity(), today: day(28))
    #expect(preview.staleHeld.map(\.id) == ["old"])
  }
}

@Suite("Two statements loaded together find the transfer between their accounts")
struct StatementSessionTests {
  private func file(
    _ key: Int, account: String, bank: String, _ operations: [ImportedOperation],
    identity: StatementIdentity
  ) -> StatementSessionFile {
    StatementSessionFile(
      key: key, accountKey: account, bankName: bank, ownReferences: [],
      preview: StatementPreviewBuilder.build(
        parse: parse(operations), accountKey: account, existing: [], manual: [],
        identity: identity, today: day(20)))
  }

  @Test func equalAmountsAMinuteApartFormOnePair() {
    let identity = StatementIdentity(phones: ["+7 900 000-00-01"])
    let own = StatementCounterparty(phone: "89000000001")
    let out = op(-5000, minute: 600, kind: .sbpTransferOut, counterparty: own, index: 0)
    let into = op(5000, minute: 601, kind: .sbpTransferIn, counterparty: own, index: 0)
    let result = StatementSessionPlanner.pairTransfers(
      files: [
        file(0, account: "a", bank: "A", [out], identity: identity),
        file(1, account: "b", bank: "B", [into], identity: identity),
      ], identity: identity, today: day(20))
    #expect(result.pairs.count + result.softPairs.count == 1)
    let pair = (result.pairs + result.softPairs)[0]
    #expect(pair.outgoing.file == 0 && pair.incoming.file == 1)
    #expect(result.withoutStatement.isEmpty)
  }

  @Test func anUnpairedTransferToAnOwnAccountIsOneQuestionPerBank() {
    let identity = StatementIdentity(phones: ["+7 900 000-00-01"])
    let own = StatementCounterparty(phone: "89000000001", bankName: "Other Bank")
    let lines = [
      op(-1000, d: 10, kind: .sbpTransferOut, counterparty: own, index: 0),
      op(-2000, d: 11, kind: .sbpTransferOut, counterparty: own, index: 1),
    ]
    let result = StatementSessionPlanner.pairTransfers(
      files: [file(0, account: "a", bank: "A", lines, identity: identity)], identity: identity,
      today: day(28))
    #expect(result.withoutStatement.count == 1)
    #expect(result.withoutStatement[0].lines.count == 2)
    #expect(result.withoutStatement[0].total == AmountE4(whole: 3000))
    #expect(result.overdue.count == 2 && result.onTheWay.isEmpty)
  }

  @Test func aRecentUnpairedSendIsOnTheWay() {
    let identity = StatementIdentity(phones: ["+7 900 000-00-01"])
    let own = StatementCounterparty(phone: "89000000001")
    let result = StatementSessionPlanner.pairTransfers(
      files: [
        file(
          0, account: "a", bank: "A",
          [op(-1000, d: 18, kind: .sbpTransferOut, counterparty: own)], identity: identity)
      ], identity: identity, today: day(20))
    #expect(result.onTheWay.count == 1 && result.overdue.isEmpty)
  }
}

@Suite("A line becomes an operation of the books")
struct StatementEntryBuilderTests {
  private let account = UUID()
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func rubles(_ operation: ImportedOperation) -> StatementRubles {
    StatementRubleResolver.resolve(operation) { _, _ in nil }!
  }

  @Test func anExpenseKeepsTheBanksStatusKeyAndImport() {
    let line = op(-1234, status: .pending, cashback: AmountE4(whole: 12))
    let importID = UUID()
    let entry = StatementEntryBuilder.entry(
      for: line, accountID: account, accountKey: "a", importID: importID,
      zoneID: TravelDay.moscowId, rubles: rubles(line),
      choice: StatementEntryChoice(categoryID: UUID(), quality: .good), now: now)
    let transaction = entry.transaction
    #expect(transaction.kind == .expense)
    #expect(transaction.amountE4 == AmountE4(whole: 1234))
    #expect(transaction.source == "statement" && transaction.bankStatus == "pending")
    #expect(transaction.importBatchId == importID)
    #expect(transaction.dedupKey == StatementDedupKey(account: "a", operation: line).value)
    #expect(transaction.cashback?.amount == AmountE4(whole: 12))
    #expect(transaction.timeZoneId == nil)
    #expect(entry.isBalanced && entry.parts.count == 1)
    #expect(entry.parts[0].quality == .good)
  }

  @Test func incomeAndRefundKindsFollowTheSignAndTheBanksWording() {
    #expect(StatementEntryBuilder.kind(of: op(500)) == .income)
    #expect(StatementEntryBuilder.kind(of: op(500, kind: .purchaseRefund)) == .refund)
    #expect(StatementEntryBuilder.kind(of: op(-500, kind: .purchaseRefund)) == .expense)
  }

  @Test func aLineWithoutATimeSitsAtNoonOfItsDay() {
    let moment = StatementMoment(day: day(14), minuteOfDay: nil)
    let date = StatementEntryBuilder.occurredAt(moment, zoneID: TravelDay.moscowId)
    #expect(TravelDay.day(of: date, zoneId: nil) == day(14))
    #expect(TravelDay.timeOfDay(of: date, zoneId: nil).hour == 12)
  }

  @Test func aForeignLineTakesTheBanksRubleFigureAndItsRate() {
    let line = op(
      -10, currency: CurrencyCode("USD"), accountAmount: AmountE4(whole: -900),
      accountCurrency: .rub)
    let resolved = StatementRubleResolver.resolve(line) { _, _ in nil }
    #expect(resolved?.amount == AmountE4(whole: 900))
    #expect(resolved?.source == .imported)
    #expect(resolved?.rate == Decimal(90))
  }

  @Test func aForeignLineWithoutAnyRateWaitsInsteadOfBeingGuessed() {
    let line = op(-10, currency: CurrencyCode("USD"))
    #expect(StatementRubleResolver.resolve(line) { _, _ in nil } == nil)
    let rated = StatementRubleResolver.resolve(line) { _, _ in (Decimal(95), true) }
    #expect(rated?.amount == AmountE4(whole: 950))
    #expect(rated?.isProvisional == true)
  }

  @Test func mergingKeepsTheCategoryAndTheCommentAndTakesTheBanksFigure() {
    let line = op(-251)
    let categoryID = UUID()
    let typed = StatementEntryBuilder.entry(
      for: op(-250), accountID: account, accountKey: "a", importID: nil,
      zoneID: TravelDay.moscowId, rubles: rubles(op(-250)),
      choice: StatementEntryChoice(categoryID: categoryID, categorySource: .manual), now: now)
    var hand = typed
    hand.transaction.dedupKey = nil
    hand.transaction.note = "my note"
    let merged = StatementEntryBuilder.merged(
      hand, with: line, accountKey: "a", zoneID: TravelDay.moscowId, rubles: rubles(line),
      now: now)
    #expect(merged.transaction.amountE4 == AmountE4(whole: 251))
    #expect(merged.parts[0].amountE4 == AmountE4(whole: 251))
    #expect(merged.parts[0].categoryId == categoryID)
    #expect(merged.transaction.note == "my note")
    #expect(merged.transaction.dedupKey == StatementDedupKey(account: "a", operation: line).value)
    #expect(merged.transaction.importBatchId == nil)
    #expect(merged.isBalanced)
  }

  @Test func aTransferTakesBothAccountsAndBothFigures() {
    let out = op(-5000, kind: .sbpTransferOut)
    let into = op(5000, d: 16, kind: .sbpTransferIn)
    let other = UUID()
    let transfer = StatementEntryBuilder.transfer(
      outgoing: out, from: account, incoming: into, to: other, zoneID: TravelDay.moscowId,
      now: now)
    #expect(transfer.fromAccountId == account && transfer.toAccountId == other)
    #expect(transfer.fromAmountE4 == AmountE4(whole: 5000))
    #expect(transfer.toAmountE4 == AmountE4(whole: 5000))
    #expect(transfer.arrivedAt != nil)
    #expect(transfer.externalId?.hasPrefix("stmt:") == true)
  }

  @Test func theExternalIdOfATransferTellsEqualTransfersApartAndFindsTheSameOneAgain() {
    let out = op(-5000, kind: .sbpTransferOut)
    let into = op(5000, kind: .sbpTransferIn)
    let other = UUID()
    func id(_ ordinal: Int, from: UUID? = nil) -> String {
      StatementEntryBuilder.transferExternalID(
        outgoing: out, from: from ?? account, incoming: into, to: other, ordinal: ordinal)
    }
    #expect(id(0) == id(0))
    #expect(id(0) != id(1))
    #expect(id(0) != id(0, from: UUID()))
    #expect(id(0).hasPrefix("stmt:"))
  }
}
