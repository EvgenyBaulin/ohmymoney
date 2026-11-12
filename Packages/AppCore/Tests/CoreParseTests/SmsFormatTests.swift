import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Every text, file and folder here is made up for the test.
private func format(
  _ pattern: String, _ columns: String, operation: BankOperation? = nil, examples: [String],
  id: String = "t", bank: BankBrand = .unknown
) -> SmsFormat {
  SmsFormat(
    id: id, bank: bank, pattern: pattern, columns: columns.split(
      separator: ";", omittingEmptySubsequences: false
    ).map { SmsColumn(name: String($0)) ?? .skip }, operation: operation, examples: examples)
}

private func money(_ text: String, _ code: String = "RUB") -> Money {
  Money(amount: try! AmountE4(decimal: Decimal(string: text)!), currency: CurrencyCode(code))
}

struct SmsFormatFileTests {
  @Test func fileTextRoundTrips() throws {
    let source = format(
      #"^Paid (\d+) at (.+)$"#, "outcome;payee", operation: .purchase,
      examples: ["Paid 5 at SAMPLE", "Paid 7 at OTHER"], bank: .sber)
    let parsed = try SmsFormat.parse(fileText: source.fileText, id: "t").get()
    #expect(parsed == source)
  }

  @Test func theFileOfTheShapeOfASharedFormatIsRead() throws {
    let text = """
      ^Card (\\d{4}) paid ([\\d.]+) (\\w{3}) at (.+) on (\\d{2}\\.\\d{2}\\.\\d{2}) mcc (\\d{4})$
      -----COLUMNS-----
      card;outcome;instrument;payee;date#dd.MM.yy;mcc
      -----EXAMPLE-----
      Card 1234 paid 10.50 USD at SAMPLE on 03.04.26 mcc 5812
      """
    let parsed = try SmsFormat.parse(fileText: text, id: "x").get()
    #expect(parsed.columns.count == 6)
    #expect(parsed.columns[4] == .date("dd.MM.yy"))
    #expect(SmsFormatValidator.problems(of: parsed).isEmpty)
  }

  @Test func aFileWithoutAnExpressionIsRefused() {
    #expect(SmsFormat.parse(fileText: "\n\n", id: "x") == .failure(.missingPattern))
  }

  @Test func aFileWithoutColumnsIsRefused() {
    #expect(SmsFormat.parse(fileText: "^a$\n-----EXAMPLE-----\na", id: "x") == .failure(.missingColumns))
  }

  @Test func anUnknownColumnIsNamed() {
    let result = SmsFormat.parse(fileText: "^(a)$\n-----COLUMNS-----\nrubbish", id: "x")
    #expect(result == .failure(.unknownColumn("rubbish")))
  }

  @Test func anUnknownSectionIsRefused() {
    let result = SmsFormat.parse(fileText: "^(a)$\n-----COLUMNS-----\npayee\n-----SPAM-----\nx", id: "x")
    #expect(result == .failure(.unknownSection("-----SPAM-----")))
  }

  @Test func anUnknownOperationIsRefused() {
    let result = SmsFormat.parse(
      fileText: "^(a)$\n-----COLUMNS-----\npayee\n-----OPERATION-----\nswim", id: "x")
    #expect(result == .failure(.unknownOperation("swim")))
  }
}

struct SmsFormatReadingTests {
  @Test func readsAmountPlaceBalanceCardAndTime() throws {
    let f = format(
      #"^(\d{4}) (\d\d:\d\d) paid ([\d\s]+,\d\d) RUB at (.+), left ([\d\s]+,\d\d)$"#,
      "card;time;outcome;payee;balance", examples: [])
    let reading = try #require(
      try f.read("1234 08:05 paid 1 250,50 RUB at SAMPLE CAFE, left 10 000,00")?.get())
    #expect(reading.money == money("1250.5"))
    #expect(reading.operation == .purchase)
    #expect(reading.merchant == "SAMPLE CAFE")
    #expect(reading.cardLast4 == "1234")
    #expect(reading.time == TimeOfDay(hour: 8, minute: 5))
    #expect(reading.balance == money("10000"))
  }

  @Test func theForeignAmountKeepsItsOwnCurrency() throws {
    let f = format(
      #"^paid ([\d.]+) (\w{3}) of ([\d.]+) (\w{3})$"#, "op_outcome;op_instrument;outcome;instrument",
      examples: [])
    let reading = try #require(try f.read("paid 12.50 USD of 1100.00 RUB")?.get())
    #expect(reading.money == money("12.5", "USD"))
  }

  @Test func feeAndCashbackAreFieldsOfTheOperation() throws {
    let f = format(
      #"^paid ([\d.]+), fee ([\d.]+), cashback ([\d.]+)$"#, "outcome;fee;cashback", examples: [])
    let reading = try #require(try f.read("paid 100.00, fee 1.50, cashback 2.00")?.get())
    #expect(reading.money == money("100"))
    #expect(reading.fee == money("1.5"))
    #expect(reading.cashback == money("2"))
    let message = try #require(reading.message(source: "x"))
    #expect(message.fee == money("1.5") && message.cashback == money("2"))
  }

  @Test func aFeeAloneIsTheOperation() throws {
    let f = format(#"^fee ([\d.]+)$"#, "fee", examples: [])
    let reading = try #require(try f.read("fee 30.00")?.get())
    #expect(reading.operation == .fee)
    #expect(reading.money == money("30"))
    #expect(reading.fee == nil)
  }

  @Test func readsMCCSyncidAndComment() throws {
    let f = format(
      #"^(\d+) ([\d.]+) (\w+) (.+)$"#, "mcc;outcome;syncid;comment", examples: [])
    let reading = try #require(try f.read("5812 10.00 AB12 lunch with a friend")?.get())
    #expect(reading.mcc == 5812)
    #expect(reading.syncid == "AB12")
    #expect(reading.comment == "lunch with a friend")
  }

  @Test func readsADayByItsPattern() throws {
    let f = format(
      #"^(\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}) ([\d.]+)$"#, "date#dd.MM.yyyy HH:mm;outcome", examples: [])
    let reading = try #require(try f.read("03.04.2026 21:15 10.00")?.get())
    #expect(reading.day == DateOnly(year: 2026, month: 4, day: 3))
    #expect(reading.time == TimeOfDay(hour: 21, minute: 15))
  }

  @Test func aDayWithoutAYearTakesTheYearOfToday() throws {
    let f = format(#"^(\d{2}\.\d{2}) ([\d.]+)$"#, "date#dd.MM;outcome", examples: [])
    let reading = try #require(
      try f.read("03.04 10.00", today: DateOnly(year: 2026, month: 6, day: 1))?.get())
    #expect(reading.day == DateOnly(year: 2026, month: 4, day: 3))
    let none = try #require(try f.read("03.04 10.00")?.get())
    #expect(none.day == nil)
  }

  @Test func theOperationOfTheFileOverridesTheColumn() throws {
    let f = format(#"^back ([\d.]+)$"#, "income", operation: .refund, examples: [])
    #expect(try f.read("back 9.00")?.get().operation == .refund)
  }

  @Test func aFormatWithoutAnAmountColumnCreatesNothing() throws {
    let f = format(#"^balance ([\d.]+)$"#, "balance", examples: [])
    let reading = try #require(try f.read("balance 5.00")?.get())
    #expect(f.isInformational)
    #expect(reading.balance == money("5"))
    #expect(reading.message(source: "x") == nil)
  }

  @Test func aTextTheExpressionDoesNotFitIsNotRead() {
    let f = format(#"^paid ([\d.]+)$"#, "outcome", examples: [])
    #expect(f.read("hello") == nil)
  }

  @Test func aGroupThatIsNotANumberIsReportedByItsColumn() throws {
    let f = format(#"^paid (\w+)$"#, "outcome", examples: [])
    guard case .failure(let failure)? = f.read("paid lots") else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure.column == "outcome")
  }

  @Test(arguments: [
    ("1 250,50", "1250.5"), ("1,250.50", "1250.5"), ("1.250,50", "1250.5"), ("−450", "450"),
    ("450.5", "450.5"), ("1 000 000", "1000000"), ("1.250.000", "1250000"), ("7", "7"),
  ])
  func amountsAsBanksWriteThem(text: String, value: String) throws {
    let expected = try AmountE4(decimal: Decimal(string: value)!)
    #expect(SmsFormatNumbers.amount(text) == expected)
  }
}

struct SmsFormatValidatorTests {
  private let good = format(
    #"^paid (\d+) at (.+)$"#, "outcome;payee", examples: ["paid 5 at SAMPLE"], id: "a")

  @Test func aGoodFormatHasNoProblems() {
    #expect(SmsFormatValidator.problems(of: good).isEmpty)
  }

  @Test func aBrokenExpressionIsNamed() {
    var f = good
    f.pattern = "^(unclosed"
    #expect(SmsFormatValidator.problems(of: f) == [.invalidPattern])
  }

  @Test func groupsMustEqualColumns() {
    var f = good
    f.columns = [.outcome]
    #expect(SmsFormatValidator.problems(of: f) == [.groupCountMismatch(groups: 2, columns: 1)])
  }

  @Test func aColumnTwiceIsRefused() {
    var f = good
    f.columns = [.outcome, .outcome]
    #expect(SmsFormatValidator.problems(of: f) == [.duplicateColumn("outcome")])
  }

  @Test func aBadDatePatternIsRefused() {
    var f = format(#"^(\S+)$"#, "date#xx", examples: ["a"])
    #expect(SmsFormatValidator.problems(of: f) == [.badDateFormat("xx")])
    f.columns = [.date("dd.MM.yyyy")]
    #expect(!SmsFormatValidator.problems(of: f).contains(.badDateFormat("dd.MM.yyyy")))
  }

  @Test func aFormatWithoutExamplesIsRefused() {
    var f = good
    f.examples = []
    #expect(SmsFormatValidator.problems(of: f) == [.noExamples])
  }

  @Test func anExampleHasToFitItsOwnExpression() {
    var f = good
    f.examples = ["paid 5 at SAMPLE", "something else"]
    #expect(SmsFormatValidator.problems(of: f) == [.exampleDoesNotMatch(2)])
  }

  @Test func anExampleThatCannotBeReadIsNamedWithItsColumn() {
    var f = good
    f.examples = ["paid 5 at SAMPLE"]
    f.pattern = #"^paid (\d+) (\w+) SAMPLE$"#
    f.columns = [.outcome, .opOutcome]
    f.examples = ["paid 5 abc SAMPLE"]
    #expect(SmsFormatValidator.problems(of: f) == [.exampleUnreadable(1, column: "op_outcome")])
  }

  @Test func anExampleThatFitsAnotherFormatOfTheBankIsNamed() {
    let rival = format(
      #"^paid (\d+) at (.+)$"#, "outcome;payee", examples: ["paid 9 at ELSE"], id: "b")
    let problems = SmsFormatValidator.problems(of: good, among: [good, rival])
    #expect(problems == [.exampleMatchesOther(1, other: "b")])
  }

  @Test func otherBanksAreNotCompared() {
    let alien = format(
      #"^paid (\d+) at (.+)$"#, "outcome;payee", examples: ["paid 9 at ELSE"], id: "b",
      bank: .alfa)
    #expect(SmsFormatValidator.problems(of: good, among: [alien]).isEmpty)
  }

  @Test func theSetReportsOnlyTheFormatsWithProblems() {
    var bad = good
    bad.id = "bad"
    bad.examples = ["nope"]
    var other = format(#"^got (\d+)$"#, "income", examples: ["got 4"], id: "ok")
    other.bank = good.bank
    let report = SmsFormatValidator.problems(ofSet: [bad, other])
    #expect(Array(report.keys) == ["bad"])
  }
}

struct SmsBuiltInFormatTests {
  /// One test per example of every format the app is built with.
  static let examples: [SmsFormatExample] = SmsBuiltInFormats.formats.flatMap { format in
    format.examples.enumerated().map { SmsFormatExample(format: format, number: $0.offset + 1) }
  }

  @Test func everyFileIsReadable() {
    #expect(SmsBuiltInFormats.formats.count == SmsBuiltInFormats.files.count)
  }

  @Test func theWholeSetIsValid() {
    #expect(SmsFormatValidator.problems(ofSet: SmsBuiltInFormats.formats).isEmpty)
  }

  @Test(arguments: examples)
  func everyExampleIsReadByItsFormatAndOnlyByIt(example: SmsFormatExample) throws {
    let text = example.format.examples[example.number - 1]
    guard case .success(let reading)? = example.format.read(text, today: nil) else {
      Issue.record("\(example.format.id) #\(example.number) not read")
      return
    }
    // Informational formats give nothing to write; every other one gives an operation.
    #expect(reading.isInformational == example.format.isInformational)
    let others = SmsBuiltInFormats.formats.filter { $0.id != example.format.id }
    for other in others {
      #expect(other.read(text) == nil, "\(other.id) also reads \(example.format.id)")
    }
  }

  /// The formats and the general scan must not disagree about the same text.
  @Test(arguments: examples.filter { !$0.format.isInformational })
  func aFormatAgreesWithTheScan(example: SmsFormatExample) throws {
    let text = example.format.examples[example.number - 1]
    let byFormat = try #require(BankTextParser().parse(text))
    let byScan = try #require(BankTextParser().scanned(text))
    #expect(byFormat.operation == byScan.operation)
    #expect(byFormat.money == byScan.money)
    #expect(byFormat.merchant == byScan.merchant)
    #expect(byFormat.cardLast4 == byScan.cardLast4)
    #expect(byFormat.balance == byScan.balance)
    #expect(byFormat.formatId == example.format.id)
  }

  @Test func theCodeTextCreatesNothing() {
    let parser = BankTextParser()
    #expect(parser.parse("Код: 123456. Никому не сообщайте его.") == nil)
    guard case .informational = parser.outcome("Код: 123456. Никому не сообщайте его.") else {
      Issue.record("expected an informational outcome")
      return
    }
  }
}

struct SmsFormatExample: Sendable, CustomTestStringConvertible {
  var format: SmsFormat
  var number: Int
  var testDescription: String { "\(format.id) #\(number)" }
}

struct SmsFormatLibraryTests {
  private func entry(
    _ id: String, _ source: SmsFormatSource, pattern: String = #"^paid (\d+) at (.+)$"#,
    columns: String = "outcome;payee", senders: [String] = []
  ) -> SmsFormatEntry {
    SmsFormatEntry(
      format(pattern, columns, examples: [], id: id), source: source, senders: senders)!
  }

  @Test func theOwnFormatBeatsTheFolderAndTheFolderTheBuiltInOne() throws {
    let library = SmsFormatLibrary(entries: [
      entry("built", .builtIn, columns: "income;payee"), entry("folder", .folder),
      entry("own", .own, columns: "outcome;payee"),
    ])
    guard case .operation(let message) = library.outcome(for: "paid 5 at SAMPLE") else {
      Issue.record("expected an operation")
      return
    }
    #expect(message.formatId == "own")
    #expect(message.operation == .purchase)
  }

  @Test func twoFormatsOfOneTierThatReadDifferentlyAreAQuestion() {
    let library = SmsFormatLibrary(entries: [
      entry("one", .folder, columns: "outcome;payee"),
      entry("two", .folder, columns: "income;payee"),
    ])
    guard case .ambiguous(let candidates) = library.outcome(for: "paid 5 at SAMPLE") else {
      Issue.record("expected a question")
      return
    }
    #expect(candidates.map(\.formatId) == ["one", "two"])
  }

  @Test func twoFormatsThatReadTheSameAreNotAQuestion() {
    let library = SmsFormatLibrary(entries: [entry("one", .folder), entry("two", .folder)])
    guard case .operation = library.outcome(for: "paid 5 at SAMPLE") else {
      Issue.record("expected an operation")
      return
    }
  }

  @Test func theOwnersPickIsRememberedAndUsed() throws {
    let library = SmsFormatLibrary(entries: [
      entry("one", .folder, columns: "outcome;payee"),
      entry("two", .folder, columns: "income;payee"),
    ])
    var choices = SmsFormatChoices()
    choices.remember("two", among: ["one", "two"])
    let again = SmsFormatChoices.decoded(choices.encoded())
    #expect(again == choices)
    guard case .operation(let message) = library.outcome(for: "paid 5 at SAMPLE", choices: again)
    else {
      Issue.record("expected an operation")
      return
    }
    #expect(message.formatId == "two")
  }

  @Test func aPickOfAFormatOutsideTheSetIsNotRemembered() {
    var choices = SmsFormatChoices()
    choices.remember("three", among: ["one", "two"])
    #expect(choices.pick(among: ["one", "two"]) == nil)
  }

  @Test func aFormatOfASenderIsNotTriedOnAnother() {
    let library = SmsFormatLibrary(entries: [entry("a", .folder, senders: ["SAMPLEBANK"])])
    if case .noFormat = library.outcome(for: "paid 5 at SAMPLE", sender: "OTHERBANK") {
    } else {
      Issue.record("a format of another sender was tried")
    }
    guard case .operation = library.outcome(for: "paid 5 at SAMPLE", sender: "SampleBank") else {
      Issue.record("sender not matched")
      return
    }
    guard case .operation = library.outcome(for: "paid 5 at SAMPLE") else {
      Issue.record("no sender: every format is tried")
      return
    }
  }

  @Test func aTextNoFormatFitsFallsBackToTheScan() throws {
    let parser = BankTextParser(formats: SmsFormatLibrary())
    let text = "MIR-1111 07:55 Покупка 450р SAMPLE CAFE Баланс: 12300р"
    #expect(try #require(parser.parse(text)).formatId == nil)
  }

  @Test func theOwnerFormatReadsABankNobodyWroteATemplateFor() throws {
    let own = entry("mine", .own, pattern: #"^Spent (\d+) EUR at (.+)$"#, columns: "outcome;payee")
    let parser = BankTextParser(formats: SmsFormatLibrary.builtIn.adding([own]))
    let message = try #require(parser.parse("Spent 12 EUR at SAMPLE BAKERY"))
    #expect(message.merchant == "SAMPLE BAKERY")
    #expect(message.formatId == "mine")
  }
}

struct SmsFormatFolderTests {
  private func file(_ path: String, _ text: String) -> SmsFolderFile {
    SmsFolderFile(path: path, data: Data(text.utf8))
  }

  private let formatText = """
    ^paid (\\d+) at (.+)$
    -----COLUMNS-----
    outcome;payee
    -----EXAMPLE-----
    paid 5 at SAMPLE
    """

  @Test func readsSendersFormatsAndCategories() throws {
    let contents = SmsFormatFolder.read(files: [
      file("samplebank_7/senders.txt", "# comment\nSAMPLEBANK\n\n900\n"),
      file("samplebank_7/formats/purchase_1.txt", formatText),
      file(
        "samplebank_7/categories/main.json",
        #"[{"category":"Cafe","unified_category":"restaurants","include_mcc":[5812,"5814"],"exclude_mcc":[5815]}]"#
      ),
    ])
    #expect(contents.skipped.isEmpty)
    #expect(contents.bankCount == 1)
    let entry = try #require(contents.entries.first)
    #expect(entry.senders == ["SAMPLEBANK", "900"])
    #expect(entry.bankName == "samplebank")
    #expect(entry.source == .folder)
    let category = try #require(contents.categories.first)
    #expect(category.includeMCC == [5812, 5814] && category.excludeMCC == [5815])
    #expect(category.covers(mcc: 5812) && !category.covers(mcc: 5815) && !category.covers(mcc: 1))
  }

  @Test func aBrokenFileIsSkippedWithItsReasonAndTheRestStillCount() {
    let contents = SmsFormatFolder.read(files: [
      file("b_1/formats/good.txt", formatText),
      file("b_1/formats/bad.txt", "^(unclosed\n-----COLUMNS-----\npayee\n-----EXAMPLE-----\nx"),
      file("b_1/formats/rubbish.txt", "^(a)$\n-----COLUMNS-----\nnonsense"),
      file("b_1/categories/broken.json", "{not json"),
    ])
    #expect(contents.entries.count == 1)
    let reasons = Dictionary(uniqueKeysWithValues: contents.skipped.map { ($0.path, $0.problems) })
    #expect(reasons["b_1/formats/bad.txt"] == [.invalidPattern])
    #expect(reasons["b_1/formats/rubbish.txt"] == [.unknownColumn("nonsense")])
    #expect(reasons["b_1/categories/broken.json"] == [.badCategoryFile])
  }

  @Test func aFileThatIsNotTextIsSkipped() {
    let bad = SmsFolderFile(path: "b/formats/x.txt", data: Data([0xFF, 0xFE, 0x00, 0xC3]))
    #expect(SmsFormatFolder.read(files: [bad]).skipped.map(\.problems) == [[.notText]])
  }

  @Test func theLaterOfTwoFormatsThatClashIsLeftOut() {
    let contents = SmsFormatFolder.read(files: [
      file("b/formats/a.txt", formatText), file("b/formats/b.txt", formatText),
    ])
    #expect(contents.entries.count == 1)
    #expect(contents.skipped.first?.path == "b/formats/b.txt")
    #expect(contents.skipped.first?.problems == [.exampleMatchesOther(1, other: "folder.b/formats/a")])
  }

  @Test func theFolderFormatsAreReadAfterTheOwnOnes() throws {
    let contents = SmsFormatFolder.read(files: [file("b/formats/a.txt", formatText)])
    let own = SmsFormatEntry(
      format(#"^paid (\d+) at (.+)$"#, "income;payee", examples: [], id: "own"), source: .own)!
    let library = SmsFormatLibrary().adding(contents.entries).adding([own])
    guard case .operation(let message) = library.outcome(for: "paid 5 at SAMPLE") else {
      Issue.record("expected an operation")
      return
    }
    #expect(message.formatId == "own")
  }

  @Test func filesOutsideTheLayoutAreIgnored() {
    let contents = SmsFormatFolder.read(files: [
      file("readme.txt", "x"), file("b/notes.md", "x"), file("b/formats/deep/a.txt", formatText),
    ])
    #expect(contents.entries.isEmpty && contents.skipped.isEmpty && contents.bankCount == 0)
  }
}

struct SmsFormatProposalTests {
  private let text = "Покупка 450,50 р KOFEMANIYA, карта 4417, остаток 12 300,00 р"

  private func message() throws -> BankMessage {
    BankMessage(
      bank: .unknown, operation: .purchase, money: money("450.5"), merchant: "KOFEMANIYA",
      cardLast4: "4417", balance: money("12300"))
  }

  @Test func theProposedFormatReadsTheTextItCameFrom() throws {
    let proposed = try #require(
      SmsFormatProposal.propose(text: text, message: try message(), id: "own.1"))
    #expect(proposed.columns == [.outcome, .payee, .card, .balance])
    let reading = try #require(try proposed.read(text)?.get())
    #expect(reading.money == money("450.5"))
    #expect(reading.merchant == "KOFEMANIYA")
    #expect(reading.cardLast4 == "4417")
    #expect(reading.balance == money("12300"))
  }

  @Test func theKeptExampleHoldsNoFigureOrShopOfTheText() throws {
    let proposed = try #require(
      SmsFormatProposal.propose(text: text, message: try message(), id: "own.1"))
    let example = try #require(proposed.examples.first)
    #expect(!example.contains("4417") && !example.contains("KOFEMANIYA"))
    #expect(!example.contains("450") && !example.contains("12 300"))
    #expect(proposed.examples.count == 1)
  }

  @Test func theProposedFormatIsValidAndFitsAnotherTextOfTheSameShape() throws {
    let proposed = try #require(
      SmsFormatProposal.propose(text: text, message: try message(), id: "own.1"))
    #expect(SmsFormatValidator.problems(of: proposed).isEmpty)
    let other = "Покупка 99 р VKUSVILL, карта 4417, остаток 800,25 р"
    let reading = try #require(try proposed.read(other)?.get())
    #expect(reading.money == money("99"))
    #expect(reading.merchant == "VKUSVILL")
    #expect(reading.balance == money("800.25"))
  }

  @Test func theOperationOfTheCorrectedMessageIsKept() throws {
    var corrected = try message()
    corrected.operation = .refund
    let proposed = try #require(
      SmsFormatProposal.propose(text: text, message: corrected, id: "own.1"))
    #expect(proposed.operation == .refund)
    #expect(proposed.columns.first == .income)
  }

  @Test func withoutTheAmountInTheTextThereIsNothingToPropose() throws {
    var wrong = try message()
    wrong.money = money("777")
    #expect(SmsFormatProposal.propose(text: text, message: wrong, id: "own.1") == nil)
  }
}

struct SmsFormatLineTests {
  private func message(_ pattern: String, _ columns: String, _ text: String) throws -> BankMessage {
    let f = format(pattern, columns, examples: [])
    return try #require(try f.read(text)?.get().message(source: text))
  }

  @Test func cashbackFromTheTextTravelsInTheLine() throws {
    let message = try message(
      #"^paid ([\d.]+) at (.+), cashback ([\d.]+)$"#, "outcome;payee;cashback",
      "paid 450.00 at KOFEMANIYA, cashback 9.00")
    let line = message.suggestedLine()
    let reading = Fixture.parser.read(line, today: Fixture.today, kind: nil)
    #expect(reading.parsed.amount == 450)
    #expect(reading.cashback == .amount(9))
  }

  @Test func aCashbackInAnotherCurrencyThanTheAmountIsNotWritten() throws {
    let message = try message(
      #"^paid ([\d.]+) (\w{3}) at (.+), cashback ([\d.]+)$"#, "op_outcome;op_instrument;payee;cashback",
      "paid 12.00 USD at SAMPLE, cashback 9.00")
    #expect(message.cashback?.currency == .rub)
    #expect(!message.suggestedLine().contains("кэшбэк"))
  }

  @Test func anIncomeHasNoCashbackInItsLine() throws {
    var message = try message(
      #"^got ([\d.]+) from (.+), cashback ([\d.]+)$"#, "income;payee;cashback",
      "got 100.00 from SAMPLE, cashback 1.00")
    #expect(message.operation == .income)
    message.cashback = Money(amount: AmountE4(whole: 1), currency: .rub)
    #expect(!message.suggestedLine().contains("кэшбэк"))
  }

  @Test func theFeeIsKeptOnTheMessageNotWrittenAsAnOperation() throws {
    let message = try message(
      #"^paid ([\d.]+), fee ([\d.]+)$"#, "outcome;fee", "paid 100.00, fee 1.50")
    #expect(message.fee == money("1.5"))
    #expect(message.operation == .purchase)
    #expect(!message.suggestedLine().contains("1.5"))
  }
}

struct OwnSmsFormatsTests {
  private let good = format(
    #"^paid (\d+) at (.+)$"#, "outcome;payee", examples: ["paid 5 at SAMPLE"], id: "own.1")

  @Test func aValidFormatIsKeptAndReadBack() {
    var own = OwnSmsFormats()
    #expect(own.add(good).isEmpty)
    let again = OwnSmsFormats.decoded(own.encoded())
    #expect(again == own)
    #expect(again.formats == [good])
    #expect(again.entries.first?.source == .own)
  }

  @Test func anInvalidFormatKeepsNothing() {
    var own = OwnSmsFormats()
    var bad = good
    bad.examples = ["nope"]
    #expect(own.add(bad) == [.exampleDoesNotMatch(1)])
    #expect(own.items.isEmpty)
  }

  @Test func aFormatThatClashesWithAKeptOneIsRefused() {
    var own = OwnSmsFormats()
    own.add(good)
    var twin = good
    twin.id = "own.2"
    #expect(own.add(twin) == [.exampleMatchesOther(1, other: "own.1")])
    #expect(own.items.count == 1)
  }

  @Test func theSameIdReplacesTheFormat() {
    var own = OwnSmsFormats()
    own.add(good)
    var changed = good
    changed.columns = [.income, .payee]
    own.add(changed)
    #expect(own.formats == [changed])
  }

  @Test func aFormatIsRemovedById() {
    var own = OwnSmsFormats()
    own.add(good)
    own.remove(id: "own.1")
    #expect(own.items.isEmpty)
  }

  @Test func garbageDecodesToNothing() {
    #expect(OwnSmsFormats.decoded("not json").items.isEmpty)
    #expect(OwnSmsFormats.decoded(nil).items.isEmpty)
  }
}
