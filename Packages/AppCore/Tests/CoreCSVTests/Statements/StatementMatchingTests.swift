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
  doc: String? = nil, merchant: String? = nil, counterparty: StatementCounterparty = .init(),
  index: Int = 0
) -> ImportedOperation {
  ImportedOperation(
    profileID: "p", sourceIndex: index, moment: StatementMoment(day: day(d), minuteOfDay: minute),
    status: status, amount: AmountE4(whole: whole), kind: kind, description: text,
    counterparty: counterparty, merchant: merchant ?? text, documentID: doc)
}

private func existing(
  _ operation: ImportedOperation, id: String, account: String = "acc"
)
  -> StatementExisting
{
  StatementExisting(
    id: id, key: StatementDedupKey(account: account, operation: operation),
    status: operation.status, day: operation.moment.day, amount: operation.amount,
    placeKey: operation.placeKey)
}

@Suite("Loading the same period twice adds nothing, and real repeats are kept")
struct StatementDuplicateTests {
  @Test func keyIsStableVersionedAndHoldsNoText() {
    let operation = op(-150, text: "Секретный магазин")
    let key = StatementDedupKey(account: "acc", operation: operation)
    #expect(key == StatementDedupKey(account: "acc", operation: operation))
    #expect(key.value.hasPrefix("v1:") && key.value.count == 3 + 16)
    #expect(!key.value.contains("Секрет"))
    #expect(key != StatementDedupKey(account: "other", operation: operation))
    #expect(
      key != StatementDedupKey(account: "acc", operation: op(-151, text: "Секретный магазин")))
    #expect(
      key
        != StatementDedupKey(
          account: "acc", operation: op(-150, minute: 616, text: "Секретный магазин")))
    #expect(
      key
        != StatementDedupKey(
          account: "acc", operation: op(-150, text: "Секретный магазин", doc: "X1")))
  }

  @Test func keyIgnoresBlanksCaseAndStatus() {
    let a = op(-150, text: "Sample  Cafe", status: .pending)
    let b = op(-150, text: " sample cafe ", status: .posted)
    #expect(
      StatementDedupKey(account: "a", operation: a) == StatementDedupKey(account: "a", operation: b)
    )
  }

  @Test func theKeyHashDoesNotChange() {
    // Pinned: a changed hash would make every stored key look new. A change needs `v2:`.
    let key = StatementDedupKey(account: "acc", operation: op(-150))
    #expect(
      key.value == "v1:"
        + StatementText.fnv1a(
          "acc\u{1F}2026-09-14\u{1F}615\u{1F}-1500000\u{1F}RUB\u{1F}sample cafe\u{1F}"))
    #expect(StatementText.fnv1a("") == "cbf29ce484222325")
    #expect(StatementText.fnv1a("a") == "af63dc4c8601ec8c")
  }

  @Test func overlappingStatementsAddOnlyTheDifference() {
    let first = (0..<5).map { op(Int64(-100 - $0), d: 10 + $0, index: $0) }
    let stored = first.enumerated().map { existing($1, id: "e\($0)") }
    let second = (3..<8).map { op(Int64(-100 - $0), d: 10 + $0, index: $0 - 3) }
    let diff = StatementDeduplicator.diff(incoming: second, account: "acc", existing: stored)
    #expect(diff.duplicateIndices == [0, 1])
    #expect(diff.newIndices == [2, 3, 4])
  }

  @Test func twoIdenticalPurchasesStayTwoAndAReloadAddsNone() {
    let pair = [op(-150, index: 0), op(-150, index: 1)]
    let fresh = StatementDeduplicator.diff(incoming: pair, account: "acc", existing: [])
    #expect(fresh.newIndices == [0, 1])
    let stored = [existing(pair[0], id: "e0"), existing(pair[1], id: "e1")]
    let reload = StatementDeduplicator.diff(incoming: pair, account: "acc", existing: stored)
    #expect(reload.duplicateIndices == [0, 1] && reload.newIndices.isEmpty)
    // Only one of the two is stored: the second is new, not merged into the first.
    let half = StatementDeduplicator.diff(incoming: pair, account: "acc", existing: [stored[0]])
    #expect(half.duplicateIndices == [0] && half.newIndices == [1])
  }

  @Test func heldLineIsUpgradedNotDuplicated() {
    let held = op(-250, status: .pending)
    let stored = [existing(held, id: "h1")]
    let posted = op(-250, status: .posted)
    let diff = StatementDeduplicator.diff(incoming: [posted], account: "acc", existing: stored)
    #expect(diff.statusUpgrades == [StatementStatusUpgrade(incomingIndex: 0, existingID: "h1")])
    #expect(diff.newIndices.isEmpty && diff.duplicateIndices.isEmpty)
  }

  @Test func stillHeldIsSimplyKnown() {
    let held = op(-250, status: .pending)
    let diff = StatementDeduplicator.diff(
      incoming: [held], account: "acc", existing: [existing(held, id: "h1")])
    #expect(diff.duplicateIndices == [0] && diff.statusUpgrades.isEmpty)
  }

  @Test func postedSelfOfAHeldLineUnderAnotherDayIsAReplacement() {
    let held = op(-1000, d: 12, text: "SAMPLE STORE", status: .pending)
    let posted = op(
      -1000, d: 15, text: "SAMPLE STORE MOSCOW", status: .posted, merchant: "SAMPLE STORE")
    let diff = StatementDeduplicator.diff(
      incoming: [posted], account: "acc", existing: [existing(held, id: "h")])
    #expect(diff.heldReplacements == [StatementStatusUpgrade(incomingIndex: 0, existingID: "h")])
    #expect(diff.newIndices.isEmpty)
    // Too far apart: a different purchase.
    let far = op(-1000, d: 25, text: "SAMPLE STORE", status: .posted)
    let apart = StatementDeduplicator.diff(
      incoming: [far], account: "acc", existing: [existing(held, id: "h")])
    #expect(apart.newIndices == [0] && apart.heldReplacements.isEmpty)
  }

  @Test func heldLinesNobodyPostedAreAskedAboutAfterTwoWeeks() {
    let held = op(-1000, d: 1, status: .pending)
    let stored = [existing(held, id: "h")]
    let diff = StatementDeduplicator.diff(incoming: [], account: "acc", existing: stored)
    #expect(
      StatementDeduplicator.staleHeld(existing: stored, today: day(10), afterDiff: diff).isEmpty)
    #expect(
      StatementDeduplicator.staleHeld(existing: stored, today: day(15), afterDiff: diff).count == 1)
  }

  @Test func fixtureFileLoadedTwiceAddsNothing() {
    guard case .parsed(let result) = StatementImporter.parseCSV(StatementFixtures.raiffeisenCSV())
    else {
      Issue.record("not parsed")
      return
    }
    let stored = result.operations.enumerated().map { existing($1, id: "e\($0)", account: "raif") }
    let diff = StatementDeduplicator.diff(
      incoming: result.operations, account: "raif", existing: stored)
    #expect(diff.newIndices.isEmpty)
    #expect(diff.duplicateIndices.count == result.operations.count)
  }

  @Test func recordsRoundTripThroughStorage() throws {
    let record = StatementImportRecord(
      id: "i1", accountID: "a1", profileID: "raiffeisen-csv-v1", fileName: "statement.csv",
      importedAt: Date(timeIntervalSince1970: 1_800_000_000), periodFrom: day(1), periodTo: day(30),
      rowCount: 10, newCount: 8, duplicateCount: 1, declinedCount: 1, unparsedCount: 0)
    let info = StatementOperationRecord(
      operationID: "o1", source: .statement, importID: "i1", postedOn: day(15), status: .pending,
      dedupKey: StatementDedupKey(value: "v1:0123456789abcdef"))
    let decoder = JSONDecoder()
    #expect(
      try decoder.decode(StatementImportRecord.self, from: JSONEncoder().encode(record)) == record)
    #expect(
      try decoder.decode(StatementOperationRecord.self, from: JSONEncoder().encode(info)) == info)
    #expect(StatementSource(rawValue: "screenshot") == .screenshot)
  }
}

@Suite("Hand-entered operations are matched with the bank's lines")
struct StatementManualMatchTests {
  private let entry = StatementManualEntry(id: "m1", day: day(14), amount: AmountE4(whole: -250))

  @Test func coffeeWithATipMergesWithoutAsking() {
    let bank = op(-251, d: 15)
    let matches = StatementManualMatcher.match(newOperations: [(0, bank)], manual: [entry])
    #expect(
      matches == [StatementManualMatch(incomingIndex: 0, candidateIDs: ["m1"], certainty: .merge)])
  }

  @Test func biggerDifferenceAsks() {
    let bank = op(-270, d: 14)
    let matches = StatementManualMatcher.match(newOperations: [(0, bank)], manual: [entry])
    #expect(matches.first?.certainty == .ask && matches.first?.candidateIDs == ["m1"])
  }

  @Test func farAmountOrDayOrOtherSignIsNoCandidate() {
    #expect(StatementManualMatcher.match(newOperations: [(0, op(-500))], manual: [entry]).isEmpty)
    #expect(
      StatementManualMatcher.match(newOperations: [(0, op(-250, d: 18))], manual: [entry]).isEmpty)
    #expect(StatementManualMatcher.match(newOperations: [(0, op(250))], manual: [entry]).isEmpty)
  }

  @Test func severalEqualCandidatesAreListed() {
    let other = StatementManualEntry(id: "m2", day: day(14), amount: AmountE4(whole: -250))
    let matches = StatementManualMatcher.match(
      newOperations: [(0, op(-250))], manual: [entry, other])
    #expect(
      matches.first?.candidateIDs.sorted() == ["m1", "m2"] && matches.first?.certainty == .ask)
  }

  @Test func oneHandEntryServesOneBankLine() {
    let matches = StatementManualMatcher.match(
      newOperations: [(0, op(-250, d: 14)), (1, op(-251, d: 15))], manual: [entry])
    #expect(matches.count == 1)
    #expect(matches.first?.incomingIndex == 0)
  }
}

@Suite("Transfers between the owner's accounts")
struct StatementTransferTests {
  private func leg(
    _ id: Int, _ account: String, _ operation: ImportedOperation, bank: String? = nil,
    refs: Set<String> = []
  ) -> StatementLeg {
    StatementLeg(
      id: id, accountKey: account, bankName: bank, ownReferences: refs, operation: operation)
  }

  @Test func explicitContractLinkPairs() {
    let out = op(
      -10_000, d: 15, minute: 960, kind: .ownContractTransferOut,
      counterparty: StatementCounterparty(contractRef: "1000000002"))
    let incoming = op(10_000, d: 15, minute: 960, kind: .ownContractTransferIn)
    let result = StatementTransferPairing.pair([
      leg(0, "one", out, refs: ["1000000001"]), leg(1, "two", incoming, refs: ["1000000002"]),
    ])
    #expect(result.pairs == [StatementTransferPair(outgoing: 0, incoming: 1, strength: .explicit)])
  }

  @Test func theMirrorHalfCanNameTheSendingContract() {
    let out = op(-10_000, d: 15, minute: 960, kind: .ownContractTransferOut)
    let incoming = op(
      10_000, d: 15, minute: 961, kind: .ownContractTransferIn,
      counterparty: StatementCounterparty(contractRef: "1000000001"))
    let result = StatementTransferPairing.pair([
      leg(0, "one", out, refs: ["1000000001"]), leg(1, "two", incoming, refs: ["1000000002"]),
    ])
    #expect(result.pairs == [StatementTransferPair(outgoing: 0, incoming: 1, strength: .exact)])
  }

  @Test func equalAmountAndTimePairsAcrossAccounts() {
    let out = op(-5_000, d: 15, minute: 600, kind: .sbpTransferOut)
    let incoming = op(5_000, d: 15, minute: 601, kind: .sbpTransferIn)
    let result = StatementTransferPairing.pair([leg(0, "a", out), leg(1, "b", incoming)])
    #expect(result.pairs == [StatementTransferPair(outgoing: 0, incoming: 1, strength: .exact)])
  }

  @Test func sameAccountNeverPairsWithItself() {
    let out = op(-5_000, minute: 600, kind: .sbpTransferOut)
    let incoming = op(5_000, minute: 600, kind: .sbpTransferIn)
    let result = StatementTransferPairing.pair([leg(0, "a", out), leg(1, "a", incoming)])
    #expect(result.pairs.isEmpty && result.softPairs.isEmpty)
  }

  @Test func aPurchaseAndItsLookalikeRefundNeverPair() {
    let purchase = op(-1_000, minute: 600, kind: .purchase)
    let refund = op(1_000, minute: 601, kind: .cardCredit)
    let result = StatementTransferPairing.pair([leg(0, "a", purchase), leg(1, "b", refund)])
    #expect(result.pairs.isEmpty && result.softPairs.isEmpty && result.ambiguous.isEmpty)
  }

  @Test func theNamedReceivingBankMustBeTheOtherLegsBank() {
    let out = op(
      -5_000, minute: 600, kind: .sbpTransferOut,
      counterparty: StatementCounterparty(bankName: "Т-Банк"))
    let incoming = op(5_000, minute: 600, kind: .sbpTransferIn)
    let wrong = StatementTransferPairing.pair([
      leg(0, "a", out), leg(1, "b", incoming, bank: "ВТБ"),
    ])
    #expect(wrong.pairs.isEmpty)
    let right = StatementTransferPairing.pair([
      leg(0, "a", out), leg(1, "b", incoming, bank: "Т-Банк"),
    ])
    #expect(right.pairs.count == 1)
  }

  @Test func twoEquallyGoodCandidatesAreAskedNotGuessed() {
    let out = op(-5_000, minute: 600, kind: .sbpTransferOut)
    let in1 = op(5_000, minute: 600, kind: .sbpTransferIn)
    let in2 = op(5_000, minute: 600, kind: .sbpTransferIn)
    let result = StatementTransferPairing.pair([
      leg(0, "a", out), leg(1, "b", in1), leg(2, "c", in2),
    ])
    #expect(result.pairs.isEmpty)
    #expect(result.ambiguous == [[0, 1, 2]])
  }

  @Test func theNearerCandidateWinsWhenTheyDiffer() {
    let out = op(-5_000, minute: 600, kind: .sbpTransferOut)
    let near = op(5_000, minute: 601, kind: .sbpTransferIn)
    let far = op(5_000, minute: 608, kind: .sbpTransferIn)
    let result = StatementTransferPairing.pair([
      leg(0, "a", out), leg(1, "b", far), leg(2, "c", near),
    ])
    // Each of them is the nearest for the out, but `far` has the out as its nearest too, so
    // the out has one nearest (`near`), and `near`'s nearest is the out: paired.
    #expect(result.pairs == [StatementTransferPair(outgoing: 0, incoming: 2, strength: .exact)])
  }

  @Test func softPairIsOnlyProposedWithinTwoDays() {
    let out = op(-20_000, d: 14, minute: 23 * 60 + 5, kind: .sbpTransferOut)
    let incoming = op(20_000, d: 15, minute: 7 * 60 + 6, kind: .sbpTransferIn)
    let result = StatementTransferPairing.pair([leg(0, "a", out), leg(1, "b", incoming)])
    #expect(result.pairs.isEmpty)
    #expect(result.softPairs == [StatementTransferPair(outgoing: 0, incoming: 1, strength: .soft)])
    let late = op(20_000, d: 17, minute: 7 * 60, kind: .sbpTransferIn)
    #expect(StatementTransferPairing.pair([leg(0, "a", out), leg(1, "b", late)]).softPairs.isEmpty)
  }

  @Test func ownTransfersWithoutAStatementAreOneQuestionPerBank() {
    let identity = StatementIdentity(phones: ["+7 900 111-22-33"], names: ["Иван Петрович К"])
    let toOwn = StatementCounterparty(phone: "79001112233", bankName: "Яндекс")
    let legs = [
      leg(0, "a", op(-1_000, kind: .sbpTransferOut, counterparty: toOwn)),
      leg(1, "a", op(-2_000, d: 15, kind: .sbpTransferOut, counterparty: toOwn)),
      leg(
        2, "a",
        op(-500, kind: .sbpTransferOut, counterparty: StatementCounterparty(phone: "79005550000"))),
      leg(
        3, "a",
        op(
          -700, kind: .personTransferOut,
          counterparty: StatementCounterparty(name: "Иван Петрович К."))),
    ]
    let questions = StatementOwnTransfers.toAccountsWithoutStatement(
      legs: legs, paired: [], identity: identity)
    #expect(questions.count == 2)
    #expect(questions[0].bankName == "Яндекс" && questions[0].legIDs == [0, 1])
    #expect(questions[0].total == AmountE4(whole: 3_000))
    #expect(questions[1].legIDs == [3])
    let afterPairing = StatementOwnTransfers.toAccountsWithoutStatement(
      legs: legs, paired: [0, 1], identity: identity)
    #expect(afterPairing.map(\.legIDs) == [[3]])
  }

  @Test func identityDoesNotLeakAndMatchesOnWholeNamesOnly() {
    let identity = StatementIdentity(
      phones: ["89001112233"], names: ["Иван Петрович К"], contractNumbers: ["1000000002"])
    #expect("\(identity)" == "StatementIdentity(redacted)")
    #expect(String(reflecting: identity) == "StatementIdentity(redacted)")
    #expect(identity.owns(StatementCounterparty(phone: "+7 (900) 111-22-33")))
    #expect(identity.owns(StatementCounterparty(name: "иван петрович к.")))
    // A relative with the same initial is someone else.
    #expect(!identity.owns(StatementCounterparty(name: "Ольга Петровна К")))
    #expect(identity.owns(StatementCounterparty(contractRef: "1000000002")))
    #expect(!identity.owns(StatementCounterparty()))
  }

  @Test func transfersWaitFiveDaysThenAreAsked() {
    let young = leg(0, "a", op(-1_000, d: 12, kind: .sbpTransferOut))
    let old = leg(1, "a", op(-1_000, d: 3, kind: .sbpTransferOut))
    let result = StatementOwnTransfers.inTransit(unpairedOutgoing: [young, old], today: day(15))
    #expect(result.onTheWay == [0] && result.overdue == [1])
  }
}

@Suite("One question per group of like operations")
struct StatementQuestionTests {
  @Test func groupsByPersonAndSumsThem() {
    let person = StatementCounterparty(name: "Анна Ивановна Т", phone: "79005550000")
    var one = op(-1_000, d: 10, kind: .sbpTransferOut, counterparty: person)
    one.message = "С Днём Рождения!"
    let two = op(-2_000, d: 12, kind: .sbpTransferOut, counterparty: person)
    let shop = op(-300, d: 11, text: "SAMPLE SHOP", kind: .purchase)
    let groups = StatementQuestions.group(
      operations: [one, shop, two], selfEmploymentEnabled: false)
    #expect(groups.count == 2)
    #expect(groups[0].topic == .person && groups[0].indices == [0, 2])
    #expect(groups[0].total == AmountE4(whole: -3_000))
    #expect(groups[0].from == day(10) && groups[0].to == day(12))
    #expect(groups[0].messages == ["С Днём Рождения!"])
    #expect(groups[0].rememberByDefault == false)
    #expect(groups[1].topic == .merchant && groups[1].rememberByDefault)
  }

  @Test func answeredOperationsAndDeclinedOnesAreNotAsked() {
    let shop = op(-300, text: "SAMPLE SHOP")
    var declined = op(-300, text: "OTHER")
    declined.status = .declined
    let groups = StatementQuestions.group(
      operations: [shop, declined], selfEmploymentEnabled: false,
      isAnswered: { $0.merchant == "SAMPLE SHOP" })
    #expect(groups.isEmpty)
  }

  @Test func loanAndContractIncomeFollowTheirOwnRules() {
    let loan = op(200_000, kind: .loanProceeds)
    let contract = op(25_000, kind: .contractIncome)
    let off = StatementQuestions.group(operations: [loan, contract], selfEmploymentEnabled: false)
    #expect(off.map(\.topic) == [.loan])
    let on = StatementQuestions.group(operations: [loan, contract], selfEmploymentEnabled: true)
    #expect(on.map(\.topic) == [.loan, .selfEmployedIncome])
  }

  @Test func incomeWithoutASenderIsItsOwnQuestion() {
    let sbp = op(5_000, kind: .sbpTransferIn)
    let groups = StatementQuestions.group(operations: [sbp], selfEmploymentEnabled: false)
    #expect(
      groups.first?.topic == .unknownIncomingSource && groups.first?.rememberByDefault == false)
  }
}

@Suite("Statement reading stays fast on a large file")
struct StatementPerformanceTests {
  /// A loose guard against an accidental quadratic step, not a product budget: how long a
  /// big statement may take is the owner's call and none is set.
  @Test func tenThousandRowsParseAndDiffInReasonableTime() {
    var rows: [StatementFixtures.RaiffRow] = []
    for index in 0..<10_000 {
      let minute = index % 60
      rows.append(
        StatementFixtures.RaiffRow(
          moment: String(
            format: "%02d.%02d.2025 %02d:%02d", index % 28 + 1, index % 12 + 1, index % 24, minute),
          done: "01.01.2026", doc: "D\(index)", income: "", expense: "\(index % 900 + 10),00",
          details: " SAMPLE SHOP \(index % 50)", card: "*1111"))
    }
    let data = StatementFixtures.raiffeisenCSV(rows: rows)
    let start = Date()
    guard case .parsed(let result) = StatementImporter.parseCSV(data) else {
      Issue.record("not parsed")
      return
    }
    let stored = result.operations.prefix(5_000).enumerated().map {
      existing($1, id: "e\($0)", account: "x")
    }
    let diff = StatementDeduplicator.diff(
      incoming: result.operations, account: "x", existing: stored)
    let elapsed = Date().timeIntervalSince(start)
    #expect(result.operations.count == 10_000)
    #expect(diff.duplicateIndices.count == 5_000 && diff.newIndices.count == 5_000)
    #expect(elapsed < 30, "took \(elapsed) s")
  }
}
