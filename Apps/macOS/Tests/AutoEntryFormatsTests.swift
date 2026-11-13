import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The formats of bank texts in the app: proposed from a text the owner wrote by hand, kept in
/// the books, tried before the general scan, and read from a folder. Every text and file is
/// made up.
@MainActor
final class AutoEntryFormatsTests: XCTestCase {
  private var book: MacCommandsBook!
  private var defaults: UserDefaults!
  private var suite: String!

  private let text = "Расход 450,50 р KOFEMANIYA, карта 4417, остаток 12 300,00 р"

  override func setUp() async throws {
    book = try await MacCommandsBook()
    suite = "autoentry-formats-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  override func tearDown() async throws {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    await book?.close()
    book = nil
  }

  private func message() -> BankMessage {
    BankMessage(
      operation: .purchase,
      money: Money(amount: AmountE4(raw: 4_505_000), currency: .rub), merchant: "KOFEMANIYA",
      cardLast4: "4417", balance: Money(amount: AmountE4(whole: 12_300), currency: .rub),
      source: text)
  }

  private func written(amount: AmountE4, kind: TransactionKind = .expense) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.amount = amount
    draft.currency = .rub
    draft.kind = kind
    return draft
  }

  func testAPastedTextWrittenByHandOffersAFormatThatKeepsNoFigure() throws {
    AutoEntryFormats.offerFormat(
      pasted: message(), draft: nil, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    let offer = try XCTUnwrap(AutoEntryFormats.offers(defaults).first)
    XCTAssertFalse(offer.text.contains("4417"), offer.text)
    XCTAssertFalse(offer.text.contains("KOFEMANIYA"), offer.text)
    XCTAssertFalse(offer.text.contains("450"), offer.text)
  }

  func testAnAmountThatIsNotInTheTextOffersNothing() {
    AutoEntryFormats.offerFormat(
      pasted: message(), draft: nil, written: written(amount: AmountE4(whole: 777)),
      defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty)
  }

  func testAKeptOfferReadsTheNextTextOfItsShape() throws {
    AutoEntryFormats.offerFormat(
      pasted: message(), draft: nil, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    let offer = try XCTUnwrap(AutoEntryFormats.offers(defaults).first)
    XCTAssertTrue(
      AutoEntryFormats.accept(offer, environment: book.environment, defaults: defaults).isEmpty)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty)
    XCTAssertEqual(AutoEntryFormats.own(book.environment).items.count, 1)

    let next = AutoEntryFormats.parser(book.environment)
      .parse("Расход 99 р VKUSVILL, карта 4417, остаток 800,25 р", today: book.environment.today)
    XCTAssertEqual(next?.formatId, offer.id)
    XCTAssertEqual(next?.merchant, "VKUSVILL")
    XCTAssertEqual(next?.money.amount, AmountE4(whole: 99))
  }

  func testADismissedOfferIsGone() throws {
    AutoEntryFormats.offerFormat(
      pasted: message(), draft: nil, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    let offer = try XCTUnwrap(AutoEntryFormats.offers(defaults).first)
    AutoEntryFormats.dismiss(offer, defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty)
    XCTAssertTrue(AutoEntryFormats.own(book.environment).items.isEmpty)
  }

  func testADraftOffersAFormatOnlyWhenWrittenAsItWasRead() throws {
    let id = UUID()
    AutoEntryFormats.remember(message: message(), draft: id, defaults: defaults)
    AutoEntryFormats.offerFormat(
      pasted: nil, draft: id, written: written(amount: AmountE4(whole: 500)), defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty, "a changed amount teaches nothing")

    let again = UUID()
    AutoEntryFormats.remember(message: message(), draft: again, defaults: defaults)
    AutoEntryFormats.offerFormat(
      pasted: nil, draft: again, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    XCTAssertEqual(AutoEntryFormats.offers(defaults).count, 1)
  }

  func testADraftWrittenAsItCameOffersNothing() {
    let id = UUID()
    AutoEntryFormats.remember(message: message(), draft: id, defaults: defaults)
    AutoEntryFormats.forget(draft: id, defaults: defaults)
    AutoEntryFormats.offerFormat(
      pasted: nil, draft: id, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty)
  }

  func testATextAFormatAlreadyReadsOffersNothing() {
    var known = message()
    known.formatId = "sber.purchase"
    AutoEntryFormats.offerFormat(
      pasted: known, draft: nil, written: written(amount: AmountE4(raw: 4_505_000)),
      defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.offers(defaults).isEmpty)
  }

  func testTwoFormatsThatFitOneTextAreAskedOnceAndTheAnswerIsKept() {
    let reading = SmsFormatReading(formatId: "a", bank: .unknown)
    let candidates = ["b", "a"].map {
      SmsFormatCandidate(formatId: $0, source: .folder, bankName: nil, reading: reading)
    }
    AutoEntryFormats.recordConflict(candidates, defaults: defaults)
    AutoEntryFormats.recordConflict(candidates, defaults: defaults)
    XCTAssertEqual(AutoEntryFormats.conflicts(defaults: defaults), [["a", "b"]])
    AutoEntryFormats.resolveConflict(
      ["a", "b"], pick: "b", environment: book.environment, defaults: defaults)
    XCTAssertTrue(AutoEntryFormats.conflicts(defaults: defaults).isEmpty)
    XCTAssertEqual(AutoEntryFormats.choices(book.environment).pick(among: ["a", "b"]), "b")
  }

  func testAFolderIsReadByPathsBelowItAndTheBrokenFileIsSkippedWithItsReason() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("formats-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bank = root.appendingPathComponent("samplebank_1/formats")
    try FileManager.default.createDirectory(at: bank, withIntermediateDirectories: true)
    try Data("SAMPLEBANK\n".utf8).write(
      to: root.appendingPathComponent("samplebank_1/senders.txt"))
    try Data(
      "^paid (\\d+) at (.+)$\n-----COLUMNS-----\noutcome;payee\n-----EXAMPLE-----\npaid 5 at SAMPLE\n"
        .utf8
    )
    .write(to: bank.appendingPathComponent("a.txt"))
    try Data("^(unclosed\n-----COLUMNS-----\npayee\n".utf8).write(
      to: bank.appendingPathComponent("broken.txt"))
    try Data("not a format".utf8).write(to: root.appendingPathComponent("readme.md"))

    let contents = SmsFormatFolder.read(files: AutoEntryFormats.files(in: root))
    XCTAssertEqual(contents.entries.count, 1)
    XCTAssertEqual(contents.entries.first?.senders, ["SAMPLEBANK"])
    XCTAssertEqual(contents.skipped.map(\.path), ["samplebank_1/formats/broken.txt"])
  }

  func testTheKeysOfOwnFormatsAndPicksAreNamedInTheSettingsOfTheDatabase() {
    XCTAssertEqual(OwnSmsFormats.settingsKey, "autoEntry.formats")
    XCTAssertEqual(SmsFormatChoices.settingsKey, "autoEntry.formatChoices")
  }
}
