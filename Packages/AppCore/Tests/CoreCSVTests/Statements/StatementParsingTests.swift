import CoreKit
import Foundation
import Testing

@testable import CoreCSV

@Suite("Statement text helpers read the bank's way of writing money, dates and names")
struct StatementTextTests {
  @Test(arguments: [
    ("-3 014.00 ₽", -30_140_000), ("2 208,50", 22_085_000), ("-1786,0", -17_860_000),
    ("+ 4,88 ₽", 48_800), ("– 5 000 ₽", -50_000_000), ("162,5", 1_625_000),
    ("\u{2212}12,30", -123_000), ("1\u{00A0}234,56", 12_345_600), ("1 234 567,00", 12_345_670_000),
    ("0,00", 0),
  ])
  func parsesAmounts(text: String, raw: Int64) {
    #expect(StatementAmount.parse(text)?.raw == raw)
  }

  @Test(arguments: ["", "abc", "12 abc", "1,2,3,4x", "--5", "5-", "₽", "1.2.3,4"])
  func refusesWhatIsNoAmount(text: String) {
    #expect(StatementAmount.parse(text) == nil)
  }

  @Test func repairsRecognitionSlipsOnlyWhenTheResultIsANumber() {
    #expect(StatementAmount.parseRepairingRecognition("3 O14.00 Р")?.raw == 30_140_000)
    #expect(StatementAmount.parseRepairingRecognition("l 2S0,50")?.raw == 12_505_000)
    #expect(StatementAmount.parseRepairingRecognition("3 014 .00 ₽")?.raw == 30_140_000)
    #expect(StatementAmount.parseRepairingRecognition("hello") == nil)
  }

  @Test func collapsesBlanksOfEveryKind() {
    #expect(StatementText.collapse("  a\u{00A0}\u{00A0}b \n c\u{202F}d ") == "a b c d")
  }

  @Test func foldsRepeatedPhrases() {
    #expect(StatementText.collapsingRepeatedPhrase("На отпуск На отпуск") == "На отпуск")
    #expect(
      StatementText.collapsingRepeatedPhrase("КИОН Оплата услуг КИОН Оплата услуг")
        == "КИОН Оплата услуг")
    #expect(StatementText.collapsingRepeatedPhrase("Кофе Кофе") == "Кофе")
    #expect(StatementText.collapsingRepeatedPhrase("Кофе и чай") == "Кофе и чай")
    #expect(StatementText.collapsingRepeatedPhrase("a b a c") == "a b a c")
  }

  @Test func phoneKeyIgnoresFormatting() {
    #expect(StatementText.phoneKey("+7 900 111-22-33") == StatementText.phoneKey("89001112233"))
    #expect(StatementText.phoneKey("79001112233") == "9001112233")
  }

  @Test func civilArithmeticRoundTrips() {
    for offset in stride(from: -40_000, through: 40_000, by: 997) {
      let date = StatementCivil.date(dayNumber: offset)
      #expect(StatementCivil.dayNumber(date) == offset)
    }
    #expect(StatementCivil.dayNumber(DateOnly(year: 1970, month: 1, day: 1)) == 0)
    #expect(StatementCivil.isValid(DateOnly(year: 2028, month: 2, day: 29)))
    #expect(!StatementCivil.isValid(DateOnly(year: 2026, month: 2, day: 29)))
    let a = StatementMoment(day: DateOnly(year: 2026, month: 9, day: 15), minuteOfDay: 23 * 60 + 5)
    let b = StatementMoment(day: DateOnly(year: 2026, month: 9, day: 16), minuteOfDay: 7 * 60 + 6)
    #expect(StatementMoment.minutes(from: a, to: b) == 8 * 60 + 1)
    #expect(StatementMoment.minutes(from: a, to: StatementMoment(day: b.day)) == nil)
  }

  @Test func decodesWindows1251WhenTheBytesAreNotUTF8() {
    // «Выписка;Сумма» in windows-1251.
    let bytes: [UInt8] = [
      0xC2, 0xFB, 0xEF, 0xE8, 0xF1, 0xEA, 0xE0, 0x3B, 0xD1, 0xF3, 0xEC, 0xEC, 0xE0,
    ]
    let decoded = StatementTextDecoder.decode(Data(bytes))
    #expect(decoded.text == "Выписка;Сумма")
    #expect(decoded.usedLegacyEncoding)
    let utf8 = StatementTextDecoder.decode(Data("\u{FEFF}Выписка".utf8))
    #expect(utf8.text == "Выписка" && !utf8.usedLegacyEncoding)
  }

  @Test func delimitedReaderKeepsStrayQuotesAndMixedEndings() {
    let text = "a;b;c\r\n1;5\" screen;3\n\"x;y\";\"he said \"\"hi\"\"\";\r\n\n4;5;6"
    let rows = StatementDelimitedReader.rows(in: text, delimiter: ";")
    #expect(rows.count == 4)
    #expect(rows[1] == ["1", "5\" screen", "3"])
    #expect(rows[2] == ["x;y", "he said \"hi\"", ""])
    #expect(rows[3] == ["4", "5", "6"])
  }

  @Test func cleansMerchantNames() {
    #expect(StatementMerchant.clean("FUEL 12345_INT") == "FUEL")
    #expect(StatementMerchant.clean("Оплата в SAMPLE SHOP MOSCOW RUS") == "SAMPLE SHOP")
    #expect(StatementMerchant.clean("Y.M*Sample Taxi") == "Sample Taxi")
    #expect(StatementMerchant.clean("IP Ivanov Bakery") == "Ivanov Bakery")
    #expect(StatementMerchant.clean("Оплата в SAMPLE.TECH G TULA RUS") == "SAMPLE.TECH")
    #expect(StatementMerchant.clean("KFC") == "KFC")
    #expect(StatementMerchant.clean("7 Eleven") == "7 Eleven")
  }

  @Test func readsMonthNames() {
    #expect(StatementMonthName.number(of: "сентябрь") == 9)
    #expect(StatementMonthName.number(of: "Мая") == 5)
    #expect(StatementMonthName.number(of: "март") == 3)
    #expect(StatementMonthName.number(of: "привет") == nil)
  }
}

@Suite("Semicolon statements with every field quoted and no bank named")
struct RaiffeisenStatementTests {
  private func parse(_ data: Data = StatementFixtures.raiffeisenCSV()) -> StatementParseResult {
    guard case .parsed(let result) = StatementImporter.parseCSV(data) else {
      Issue.record("not parsed")
      return StatementParseResult(
        profileID: "", header: StatementHeader(), operations: [], declined: [], unparsed: [],
        checks: [], usedLegacyEncoding: false)
    }
    return result
  }

  @Test func readsEveryRowWithoutLoss() {
    let result = parse()
    #expect(result.profileID == "raiffeisen-csv-v1")
    #expect(result.operations.count == StatementFixtures.raiffeisenRows.count)
    #expect(result.unparsed.isEmpty)
    #expect(result.declined.isEmpty)
    #expect(result.isImportable)
    #expect(result.checks.map(\.kind) == [.oneAmountPerRow])
    #expect(result.checks.allSatisfy { $0.passed })
  }

  @Test func readsAmountsDatesAndStatus() {
    let ops = parse().operations
    #expect(ops[0].amount == AmountE4(whole: -150))
    #expect(
      ops[0].moment
        == StatementMoment(day: DateOnly(year: 2026, month: 9, day: 14), minuteOfDay: 615))
    #expect(ops[0].postedOn == DateOnly(year: 2026, month: 9, day: 15))
    #expect(ops[0].status == .posted)
    #expect(ops[0].cardTail == "1111")
    #expect(ops[2].status == .pending && ops[2].postedOn == nil)
    #expect(ops[2].amount.raw == -22_085_000)
    #expect(ops[4].amount == AmountE4(whole: 10_000))
    #expect(ops[3].cardTail == nil)
    #expect(ops[0].currency == .rub && ops[0].accountCurrency == .rub)
  }

  @Test func readsTheWordingTemplates() {
    let ops = parse().operations
    #expect(ops[0].kind == .purchase && ops[0].merchant == "SAMPLE CAFE")

    #expect(ops[3].kind == .sbpTransferOut)
    #expect(ops[3].counterparty.phone == "79001112233")
    #expect(ops[3].counterparty.bankName == "Яндекс")
    #expect(ops[3].message == nil)

    #expect(ops[4].kind == .personTransferIn)
    #expect(ops[4].counterparty.name == "Анна Ивановна Т")
    #expect(ops[4].message == "На отпуск")

    #expect(ops[5].kind == .personTransferOut)
    #expect(ops[5].counterparty.name == "Иван П.")

    #expect(ops[6].kind == .servicePayment && ops[6].merchant == "КИОН Оплата услуг")
    #expect(ops[7].kind == .mobileTopUp)
    #expect(ops[8].kind == .cashbackPayout && ops[8].cashbackMonth == 9)
    #expect(ops[9].kind == .purchaseRefund && ops[9].merchant == "SAMPLE SHOP")
    #expect(ops[10].kind == .contractIncome)
    #expect(ops[11].kind == .unnamedTransferIn && ops[11].counterparty.bankName == "Т-Банк")
    #expect(ops[12].kind == .rawCardLine && ops[12].merchant == "SAMPLESHOP")
  }

  @Test func readsTheLaterWordings() {
    let ops = parse().operations
    #expect(ops[13].kind == .personTransferIn && ops[13].counterparty.name == "Алексей В.")
    #expect(ops[14].kind == .ownContractTransferOut && ops[14].counterparty.isEmpty)
    #expect(ops[15].kind == .cashbackPayout && ops[15].merchant == "SAMPLE MARKET")
    // A two-word name: the repeated message after it is not part of the name.
    #expect(ops[16].kind == .personTransferIn && ops[16].counterparty.name == "Мария А")
    #expect(ops[16].message == "Мария")
    // Transfer by phone without a message and without an identifier, and with a message.
    #expect(ops[17].kind == .sbpTransferOut && ops[17].counterparty.bankName == "Сбербанк")
    #expect(ops[17].message == nil)
    #expect(ops[18].message == "За обед" && ops[18].counterparty.bankName == "Т-Банк")
  }

  @Test func documentNumberIsOptionalAndKept() {
    let ops = parse().operations
    #expect(ops[0].documentID == "DOC0001")
    #expect(ops[4].documentID == nil)
  }

  @Test func theHeaderMayBeQuotedToo() {
    let quotedHeader = StatementFixtures.raiffeisenHeader.split(separator: ";").map { "\"\($0)\"" }
      .joined(separator: ";")
    let text =
      quotedHeader + "\n" + StatementFixtures.raiffeisenLine(StatementFixtures.raiffeisenRows[0])
    guard case .parsed(let result) = StatementImporter.parseCSV(Data(text.utf8)) else {
      Issue.record("not parsed")
      return
    }
    #expect(result.operations.count == 1)
  }

  @Test func bothAmountColumnsFilledIsAnUnreadableRowNotAGuess() {
    var rows = StatementFixtures.raiffeisenRows
    rows[0].income = "10,00"
    rows[1].income = ""
    rows[1].expense = ""
    let result = parse(StatementFixtures.raiffeisenCSV(rows: rows))
    #expect(result.operations.count == rows.count - 2)
    #expect(result.unparsed.count == 2)
    #expect(result.unparsed.allSatisfy { $0.reason == .amountColumnsConflict })
    #expect(result.checks.first { $0.kind == .oneAmountPerRow }?.violations == 2)
  }

  @Test func badDateAndBadAmountAreCountedWithTheirSum() {
    var rows = StatementFixtures.raiffeisenRows
    rows[0].moment = "31.02.2026 10:00"
    rows[1].expense = "12x"
    let result = parse(StatementFixtures.raiffeisenCSV(rows: rows))
    #expect(result.unparsed.map(\.reason) == [.badDate, .badAmount])
    #expect(result.unparsedSum == AmountE4(whole: -150))
  }

  @Test func rowOfTheWrongWidthIsReportedNotPadded() {
    let text =
      StatementFixtures.raiffeisenHeader + "\n\"14.09.2026 10:15\";\"15.09.2026\";\"X\"\n"
      + StatementFixtures.raiffeisenLine(StatementFixtures.raiffeisenRows[0])
    guard case .parsed(let result) = StatementImporter.parseCSV(Data(text.utf8)) else {
      Issue.record("not parsed")
      return
    }
    #expect(result.operations.count == 1)
    #expect(
      result.unparsed == [
        StatementUnparsedLine(sourceIndex: 0, reason: .columnCountMismatch, amount: nil)
      ])
  }

  @Test func readsWindows1251Files() {
    let text =
      StatementFixtures.raiffeisenHeader + "\n"
      + StatementFixtures.raiffeisenLine(StatementFixtures.raiffeisenRows[0])
    // Encode through a scalar table: every character of the fixture is in the code page.
    var bytes: [UInt8] = []
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0..<128: bytes.append(UInt8(scalar.value))
      case 0x0410...0x044F: bytes.append(UInt8(scalar.value - 0x0410 + 0xC0))
      case 0x0401: bytes.append(0xA8)
      case 0x0451: bytes.append(0xB8)
      default: Issue.record("fixture holds a character outside the code page")
      }
    }
    guard case .parsed(let result) = StatementImporter.parseCSV(Data(bytes)) else {
      Issue.record("not parsed")
      return
    }
    #expect(result.usedLegacyEncoding)
    #expect(result.operations.first?.merchant == "SAMPLE CAFE")
  }
}

@Suite("Semicolon statements with unquoted fields and a debit/credit word")
struct VTBStatementTests {
  private func parse() -> StatementParseResult {
    guard case .parsed(let result) = StatementImporter.parseCSV(StatementFixtures.vtbCSV()) else {
      Issue.record("not parsed")
      return StatementParseResult(
        profileID: "", header: StatementHeader(), operations: [], declined: [], unparsed: [],
        checks: [], usedLegacyEncoding: false)
    }
    return result
  }

  @Test func separatesImportedDeclinedAndUnreadable() {
    let result = parse()
    #expect(result.profileID == "vtb-csv-v1")
    #expect(result.operations.count == 5)
    #expect(result.declined.count == 1)
    #expect(result.declined.first?.amount == AmountE4(whole: -3588))
    #expect(result.unparsed.map(\.reason) == [.signContradictsDirection, .columnCountMismatch])
    // The contradicting line's sum is not lost.
    #expect(result.unparsed.first?.amount == AmountE4(whole: 700))
    #expect(result.unparsedSum == AmountE4(whole: 700))
    let sign = result.checks.first { $0.kind == .signMatchesDirection }
    #expect(sign?.passed == false && sign?.violations == 1 && sign?.blocking == false)
  }

  @Test func readsPurchaseCashbackFeeAndCard() {
    let ops = parse().operations
    #expect(ops[0].kind == .purchase)
    #expect(ops[0].amount == AmountE4(whole: -1786))
    #expect(ops[0].cashbackAccrued == AmountE4(whole: 130))
    #expect(ops[0].cardTail == "1111")
    #expect(ops[0].merchant == "FUEL")
    #expect(ops[0].mcc == "5541")
    #expect(ops[0].bankCategory == "Транспорт")
    #expect(ops[0].feeAmount == nil)
    let withFee = ops[4]
    #expect(withFee.feeAmount == AmountE4(whole: 15))
    #expect(withFee.merchant == "SAMPLE KIOSK")
    #expect(withFee.comment == "Комментарий")
  }

  @Test func statusAndWording() {
    let ops = parse().operations
    #expect(ops[1].kind == .sbpTransferIn && ops[1].counterparty.name == "Анна Ивановна Т")
    #expect(ops[2].status == .pending)
    #expect(ops[3].kind == .cashDeposit)
    #expect(parse().header.accountTail == "0402")
    #expect(parse().header.productName == "Мастер-счёт в рублях")
  }
}

@Suite("The text layer of a PDF turnover certificate")
struct TBankStatementTests {
  private func parse(_ lines: [String]) -> StatementParseResult {
    guard case .parsed(let result) = StatementImporter.parsePDFText(lines) else {
      Issue.record("not parsed")
      return StatementParseResult(
        profileID: "", header: StatementHeader(), operations: [], declined: [], unparsed: [],
        checks: [], usedLegacyEncoding: false)
    }
    return result
  }

  @Test func readsRowsAcrossPagesAndChecksTheFooter() {
    let result = parse(StatementFixtures.tbankLines())
    #expect(result.profileID == "tbank-pdf-v1")
    #expect(result.operations.count == StatementFixtures.tbankRows.count)
    #expect(result.unparsed.isEmpty)
    #expect(result.isImportable)
    let footer = result.checks.first { $0.kind == .footerTotals }
    #expect(footer?.passed == true && footer?.blocking == true)
    #expect(result.header.footerIncome?.raw == 500_123_400)
    #expect(result.header.footerExpense == AmountE4(whole: 14_914))
    #expect(result.header.contractNumber == "1000000001")
    #expect(result.header.accountTail == "0001")
    #expect(result.header.periodFrom == DateOnly(year: 2026, month: 9, day: 1))
    #expect(result.header.periodTo == DateOnly(year: 2026, month: 9, day: 30))
    #expect(result.header.openedOn == DateOnly(year: 2026, month: 1, day: 1))
    #expect(result.checks.first { $0.kind == .datesInPeriod }?.passed == true)
  }

  @Test func theLineWithOneBlankBeforeTheCardIsNotLost() {
    let result = parse(StatementFixtures.tbankLines())
    let tight = result.operations[3]
    #expect(tight.amount == AmountE4(whole: -841))
    #expect(tight.cardTail == "1111")
    #expect(tight.merchant == "SAMPLE.TECH")
  }

  @Test func joinsDescriptionContinuationAndTimes() {
    let result = parse(StatementFixtures.tbankLines())
    let transfer = result.operations[2]
    #expect(transfer.description == "Внешний перевод по номеру телефона +70001112233")
    #expect(transfer.kind == .sbpTransferOut)
    #expect(transfer.counterparty.phone == "+70001112233")
    #expect(transfer.cardTail == nil)
    #expect(transfer.moment.minuteOfDay == 12 * 60)
    #expect(transfer.postedOn == DateOnly(year: 2026, month: 9, day: 15))
  }

  @Test func classifiesTheWordings() {
    let ops = parse(StatementFixtures.tbankLines()).operations
    #expect(
      ops.map(\.kind) == [
        .sbpTransferIn, .purchase, .sbpTransferOut, .purchase, .cashbackPayout, .bankFee,
        .ownContractTransferOut,
      ])
    #expect(ops[1].merchant == "SAMPLE SHOP")
    #expect(ops[6].counterparty.contractRef == "1000000002")
  }

  @Test func aFormFeedInFrontOfTheRepeatedTableHeadDoesNotLeakIntoTheRow() {
    var lines = StatementFixtures.tbankLines()
    let heads = lines.indices.filter { lines[$0].hasPrefix("Дата и время") }
    if let last = heads.last { lines[last] = "\u{0C}" + lines[last] }
    let result = parse(lines)
    #expect(result.operations.allSatisfy { !$0.description.contains("Дата и время") })
    #expect(result.checks.first { $0.kind == .footerTotals }?.passed == true)
  }

  @Test func theMirrorOfAnInternalTransferNamesTheSendingContract() {
    var rows = StatementFixtures.tbankRows
    rows.append(
      StatementFixtures.TBankRow(
        amountCents: 1_000_000, description: "Внутрибанковский перевод с договора 1000000002",
        card: "—", time: "17:00", postTime: "17:00"))
    rows.append(
      StatementFixtures.TBankRow(
        amountCents: -2_500, description: "AIA*Sample MOSCOW RU", card: "1111", time: "18:00",
        postTime: "18:00"))
    let ops = parse(StatementFixtures.tbankLines(rows: rows)).operations
    #expect(ops[7].kind == .ownContractTransferIn && ops[7].counterparty.contractRef == "1000000002")
    #expect(ops[8].kind == .purchase && ops[8].merchant == "AIA*Sample")
  }

  @Test func theSignatureBlockIsNotAppendedToTheLastRow() {
    let ops = parse(StatementFixtures.tbankLines()).operations
    #expect(ops.last?.description == "Внутренний перевод на договор 1000000002")
  }

  @Test func aMissingLineStopsTheImportAndSaysHowMuch() {
    var rows = StatementFixtures.tbankRows
    let lost = rows.remove(at: 1)
    // The footer still shows what the bank printed for the full list.
    let full = StatementFixtures.tbankRows
    let income = full.map(\.amountCents).filter { $0 > 0 }.reduce(0, +)
    let expense = -full.map(\.amountCents).filter { $0 < 0 }.reduce(0, +)
    let result = parse(
      StatementFixtures.tbankLines(rows: rows, footerIncome: income, footerExpense: expense))
    let footer = result.checks.first { $0.kind == .footerTotals }
    #expect(footer?.passed == false && footer?.blocking == true)
    #expect(footer?.missingExpense.raw == Int64(-lost.amountCents) * 100)
    #expect(footer?.missingIncome == .zero)
    #expect(!result.isImportable)
  }

  @Test func aLineThatLooksLikeARowButIsNotIsCountedWithItsAmount() {
    var lines = StatementFixtures.tbankLines()
    let at = lines.firstIndex { $0.hasPrefix("16.09.2026") } ?? 0
    lines.insert("16.09.2026     16.09.2026     -77.00 ₽   garbled without a second amount", at: at)
    let result = parse(lines)
    #expect(result.unparsed.count == 1)
    #expect(result.unparsed.first?.reason == .unreadableLine)
    #expect(result.unparsed.first?.amount == AmountE4(whole: -77))
  }

  @Test func aMissingFooterIsAFailedBlockingCheck() {
    let lines = StatementFixtures.tbankLines().filter {
      !$0.hasPrefix("Пополнения:") && !$0.hasPrefix("Расходы:")
    }
    let footer = parse(lines).checks.first { $0.kind == .footerTotals }
    #expect(footer?.passed == false && footer?.blocking == true)
  }

  @Test func foreignCurrencyMarksAreKept() {
    var rows = StatementFixtures.tbankRows
    rows.append(
      StatementFixtures.TBankRow(
        amountCents: -1_000, description: "Оплата в SAMPLE SHOP", card: "1111"))
    var lines = StatementFixtures.tbankLines(rows: rows)
    if let index = lines.lastIndex(where: { $0.contains("-10.00 ₽") }) {
      lines[index] = lines[index].replacingOccurrences(of: "-10.00 ₽", with: "-10.00 $")
    }
    let last = parse(lines).operations.last
    #expect(last?.currency == .usd)
  }
}

@Suite("Format recognition")
struct StatementDetectionTests {
  @Test func eachFixtureHasExactlyOneProfile() {
    let headers: [(String, String)] = [
      ("vtb-csv-v1", StatementFixtures.vtbHeader),
      ("raiffeisen-csv-v1", StatementFixtures.raiffeisenHeader),
    ]
    for (expected, header) in headers {
      let cells = StatementDelimitedReader.rows(in: header, delimiter: ";")[0]
      let matching = StatementProfiles.all.filter {
        StatementImporter.detect(headerRow: cells, profiles: [$0]) != nil
      }
      #expect(matching.map(\.id) == [expected])
    }
    let pdf = StatementFixtures.tbankLines()
    let matching = StatementProfiles.all.filter {
      StatementImporter.detect(textLines: pdf, profiles: [$0]) != nil
    }
    #expect(matching.map(\.id) == ["tbank-pdf-v1"])
  }

  @Test func theFileNameDoesNotMatterOnlyTheContent() {
    // There is no name in the API at all; this documents that detection reads bytes only.
    #expect(
      {
        if case .parsed = StatementImporter.parseCSV(StatementFixtures.raiffeisenCSV()) {
          return true
        }
        return false
      }())
  }

  @Test func unknownHeaderIsReportedWithItsCells() {
    let data = Data("Date;Amount;Memo\n2026-01-01;5;x\n".utf8)
    guard case .unknownFormat(let hint) = StatementImporter.parseCSV(data) else {
      Issue.record("expected unknown format")
      return
    }
    #expect(hint == ["Date", "Amount", "Memo"])
  }

  @Test func emptyAndForeignTextAreHandledWithoutCrashing() {
    if case .unreadable = StatementImporter.parseCSV(Data()) {} else { Issue.record("empty") }
    if case .unreadable = StatementImporter.parsePDFText([]) {} else { Issue.record("no lines") }
    if case .unknownFormat = StatementImporter.parsePDFText(["Some other document", "Total 5"]) {
    } else {
      Issue.record("foreign text")
    }
    if case .unknownFormat = StatementImporter.parseCSV(Data([0xFF, 0xFE, 0x00, 0x41])) {
    } else if case .unreadable = StatementImporter.parseCSV(Data([0xFF, 0xFE, 0x00, 0x41])) {
    } else {
      Issue.record("binary junk must not parse")
    }
  }

  @Test func profilesAreDataThatSurvivesStorage() throws {
    let encoded = try JSONEncoder().encode(StatementProfiles.all)
    let decoded = try JSONDecoder().decode([StatementProfile].self, from: encoded)
    #expect(decoded == StatementProfiles.all)
    guard
      case .parsed(let result) = StatementImporter.parseCSV(
        StatementFixtures.raiffeisenCSV(), profiles: decoded)
    else {
      Issue.record("not parsed with decoded profiles")
      return
    }
    #expect(result.operations.count == StatementFixtures.raiffeisenRows.count)
  }

  @Test func everyRulePatternCompiles() {
    for profile in StatementProfiles.all {
      for rule in profile.descriptionRules {
        #expect(
          (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])) != nil,
          "\(profile.id)/\(rule.id)")
      }
      if case .pdfText(let layout) = profile.layout {
        for pattern in [layout.rowPattern, layout.timePattern] + layout.skipPatterns {
          #expect((try? NSRegularExpression(pattern: pattern)) != nil, "\(profile.id)")
        }
      }
    }
  }
}
