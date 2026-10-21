import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «перевод 1000 наличные карта для поездок» in the entry line, end to end: the words over the
/// line before Return, the transfer written at once — no expense — and taken back by one ⌘Z;
/// the other way round with «на … с …»; the fields of a transfer in the panel — no window of its
/// own —, with nothing written, when an account is not known or the money changes currency, and
/// the transfer written from there; «перевод маше 500» stays an operation.
@MainActor
final class TransferFromTheLineTests: XCTestCase {
  private var host: EntryHost?
  private var appGuide: GuideStore!
  private var suite = ""
  private var cash = PaymentMethod(name: "Наличные", currency: .rub, isDefault: true)
  private var travel = PaymentMethod(name: "Карта для поездок", currency: .rub)
  private var abroad = PaymentMethod(name: "Заграница", currency: .usd)
  private let masha = Person(name: "Маша")

  override func setUp() async throws {
    suite = "ohmymoney.tests.transferLine.\(UUID().uuidString)"
    appGuide = GuideStore.shared
    GuideStore.shared = GuideStore(defaults: UserDefaults(suiteName: suite)!, tutorial: true)
  }

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
    GuideStore.shared = appGuide
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func makeHost() async throws -> EntryHost {
    let accounts = [cash, travel, abroad]
    let person = masha
    let host = try await EntryHost(opensDetails: false) { environment in
      let references = try XCTUnwrap(environment.references)
      for account in accounts { try references.save(account) }
      try references.save(person)
      environment.refreshVocabulary()
    }
    self.host = host
    return host
  }

  private func transfers(_ host: EntryHost) async throws -> [Transfer] {
    let books = await TransferActions(environment: host.environment, store: host.store).books()
    return try XCTUnwrap(books).dataset.transfers
  }

  private func type(_ line: String, in host: EntryHost) throws {
    let editor = try host.type(line, into: try host.line())
    editor.insertNewline(nil)
    host.settle(1)
  }

  private func read(_ line: String, in host: EntryHost) -> ParsedInput {
    CoreLineInterpreter(
      vocabulary: host.environment.vocabulary, calendar: host.environment.calendar
    )
    .interpret(line, today: host.environment.today)
  }

  /// Before Return: «Перевод: Наличные → Карта для поездок, 1,000.00 ₽».
  func testTheLineSaysWhatItWillTransfer() async throws {
    let host = try await makeHost()
    let parsed = read("перевод 1000 наличные карта для поездок", in: host)
    let reading = try XCTUnwrap(parsed.transfer, "the line is no transfer")
    XCTAssertEqual(reading.fromAccountId, cash.id)
    XCTAssertEqual(reading.toAccountId, travel.id)
    let text = EntryBar<EmptyView>.transferPreview(
      reading, amount: AmountE4(whole: 1000), currency: .rub, accounts: [cash, travel, abroad],
      environment: host.environment)
    XCTAssertEqual(
      text,
      host.environment.language("entry.transfer.preview", table: "Entry")
        + " Наличные → Карта для поездок, "
        + host.environment.money.exact(AmountE4(whole: 1000), currency: .rub))
    XCTAssertEqual(GuideFlowTests.russian("entry.transfer.preview", table: "Entry"), "Перевод:")
  }

  /// Return writes the transfer at once, without a sheet and without an expense; the line is
  /// cleared; the tutorial hears of it; one ⌘Z takes it back.
  func testReturnWritesTheTransferAtOnceAndUndoTakesItBack() async throws {
    let host = try await makeHost()
    try type("перевод 1000 наличные карта для поездок", in: host)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.count, 1)
    let transfer = try XCTUnwrap(written.first)
    XCTAssertEqual(transfer.fromAccountId, cash.id)
    XCTAssertEqual(transfer.toAccountId, travel.id)
    XCTAssertEqual(transfer.fromAmountE4, AmountE4(whole: 1000))
    XCTAssertEqual(transfer.toAmountE4, AmountE4(whole: 1000))
    XCTAssertEqual(try host.transactions.count(), 0, "a transfer is no expense")
    XCTAssertNil(host.window.attachedSheet, "nothing was left to ask")
    XCTAssertEqual(try host.line().stringValue, "", "the line was not cleared")
    XCTAssertTrue(GuideStore.shared.progress.events.contains(GuideEvent.transferFromLine))

    host.store.undo()
    host.settle()
    let after = try await transfers(host)
    XCTAssertTrue(after.isEmpty, "⌘Z left the transfer")
  }

  /// «на наличные с карты для поездок»: the money leaves the card for the cash.
  func testTheOtherWayRound() async throws {
    let host = try await makeHost()
    let line = "перевод 500 на наличные с карты для поездок"
    let reading = try XCTUnwrap(read(line, in: host).transfer)
    XCTAssertEqual(reading.fromAccountId, travel.id)
    XCTAssertEqual(reading.toAccountId, cash.id)

    try type("перевод 500 на наличные с карты для поездок", in: host)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.map(\.fromAccountId), [travel.id])
    XCTAssertEqual(written.map(\.toAccountId), [cash.id])
  }

  /// Return in the line once more, its text as it stands.
  private func returnInTheLine(_ host: EntryHost) throws {
    let line = try host.line()
    XCTAssertTrue(host.window.makeFirstResponder(line))
    let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView, "the field editor")
    editor.insertNewline(nil)
    host.settle(1)
  }

  /// «перевод 300 наличные копилка»: no account is «копилка» — no sheet: the panel opens on the
  /// fields of a transfer from «Наличные» with 300 and nothing on the other side, and nothing is
  /// written; Return again says what is missing and still writes nothing.
  func testAnAccountNotKnownOpensTheTransferFieldsAndWritesNothing() async throws {
    let host = try await makeHost()
    let parsed = read("перевод 300 наличные копилка", in: host)
    let reading = try XCTUnwrap(parsed.transfer)
    var draft = TransactionDraft(amount: AmountE4(whole: 300))
    draft.normalizeSinglePart()
    let form = TransferForm(
      fromTheLine: reading, draft: draft, accounts: [cash, travel, abroad],
      calendar: host.environment.calendar)
    XCTAssertEqual(form.fromAccountId, cash.id)
    XCTAssertNil(form.toAccountId, "the main account is never put there by itself")
    XCTAssertEqual(form.sent, AmountE4(whole: 300))
    XCTAssertFalse(form.savesAtOnce(reading))

    try type("перевод 300 наличные копилка", in: host)
    XCTAssertNil(host.window.attachedSheet, "a transfer opens no window of its own")
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty, "a transfer was written without a word")
    XCTAssertEqual(try host.transactions.count(), 0)
    XCTAssertTrue(
      host.textFields().contains { $0.stringValue == "300" },
      "the amount sent of the transfer is not in the panel")
    XCTAssertEqual(try host.line().stringValue, "перевод 300 наличные копилка")

    try returnInTheLine(host)
    XCTAssertNil(host.window.attachedSheet)
    let again = try await transfers(host)
    XCTAssertTrue(again.isEmpty, "a transfer with no account to go to was written")
    XCTAssertEqual(try host.transactions.count(), 0, "it became an expense")
    XCTAssertEqual(try host.line().stringValue, "перевод 300 наличные копилка")
  }

  /// The account the line did not know, chosen in the panel: Return writes the transfer there,
  /// clears the line, and one ⌘Z takes it back.
  func testTheAccountChosenInThePanelTakesTheTransfer() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await makeHost()
    try type("перевод 300 наличные копилка", in: host)
    try WindowAccessibility.choose("Карта для поездок", inMenu: "transfer.to", of: host.window)
    host.settle()
    try returnInTheLine(host)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.map(\.fromAccountId), [cash.id])
    XCTAssertEqual(written.map(\.toAccountId), [travel.id])
    XCTAssertEqual(written.first?.fromAmountE4, AmountE4(whole: 300))
    XCTAssertNil(host.window.attachedSheet)
    XCTAssertEqual(try host.line().stringValue, "", "the line was not cleared")
    XCTAssertTrue(GuideStore.shared.progress.events.contains(GuideEvent.transferFromLine))
    host.store.undo()
    host.settle()
    let after = try await transfers(host)
    XCTAssertTrue(after.isEmpty, "⌘Z left the transfer")
  }

  /// «перевод 9500 наличные заграница»: rubles to a dollar account — the panel asks what came,
  /// nothing is written in silence; what came, typed in the panel, writes the exchange.
  func testAnotherCurrencyAsksWhatCameInThePanel() async throws {
    let host = try await makeHost()
    let reading = try XCTUnwrap(read("перевод 9500 наличные заграница", in: host).transfer)
    XCTAssertTrue(reading.isComplete)
    var draft = TransactionDraft(amount: AmountE4(whole: 9500))
    draft.normalizeSinglePart()
    let form = TransferForm(
      fromTheLine: reading, draft: draft, accounts: [cash, travel, abroad],
      calendar: host.environment.calendar)
    XCTAssertEqual(form.toAccountId, abroad.id)
    XCTAssertEqual(form.toCurrency, .usd)
    XCTAssertTrue(form.isExchange)
    XCTAssertFalse(form.savesAtOnce(reading), "an exchange asks what came")

    try type("перевод 9500 наличные заграница", in: host)
    XCTAssertNil(host.window.attachedSheet, "a transfer opens no window of its own")
    host.settle(0.5)
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty)

    // The amounts of the panel, top to bottom: sent, received, the fee.
    let amounts = host.textFields().filter { $0.placeholderString == "0" }
      .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
    XCTAssertEqual(amounts.count, 3, "sent, received and the fee")
    let received = try XCTUnwrap(amounts.dropFirst().first)
    XCTAssertEqual(received.stringValue, "", "what came is the owner's to type")
    _ = try host.type("100", into: received)
    host.settle()
    try returnInTheLine(host)
    let deadline = Date().addingTimeInterval(3)
    var exchanged: [Transfer] = []
    while exchanged.isEmpty, Date() < deadline {
      host.settle(0.1)
      exchanged = try await transfers(host)
    }
    let exchange = try XCTUnwrap(exchanged.first, "the exchange was not written")
    XCTAssertEqual(exchange.fromAmountE4, AmountE4(whole: 9500))
    XCTAssertEqual(exchange.fromCurrency, .rub)
    XCTAssertEqual(exchange.toAmountE4, AmountE4(whole: 100))
    XCTAssertEqual(exchange.toCurrency, .usd)
    XCTAssertEqual(try host.transactions.count(), 0)
  }

  /// The quick line of the form at the side: the first Return shows the transfer it will write
  /// and writes nothing, the second writes it — no window of its own — and clears the line.
  func testTheQuickLineOfTheFormWritesTheTransferOnTheSecondReturn() async throws {
    let accounts = [cash, travel, abroad]
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      let references = try XCTUnwrap(environment.references)
      for account in accounts { try references.save(account) }
      environment.refreshVocabulary()
    }
    self.host = host
    let quick = try host.field(
      prompt: host.environment.language("entry.quick.prompt", table: "Entry"))
    let editor = try host.type("перевод 1000 наличные карта для поездок", into: quick)
    host.settle()
    editor.insertNewline(nil)
    host.settle(1)
    let shown = try await transfers(host)
    XCTAssertTrue(shown.isEmpty, "the first Return wrote")
    XCTAssertEqual(
      QuickEntrySummary.text(
        of: TransferForm(
          fromTheLine: TransferReading(fromAccountId: cash.id, toAccountId: travel.id),
          draft: {
            var draft = TransactionDraft(amount: AmountE4(whole: 1000))
            draft.normalizeSinglePart()
            return draft
          }(), accounts: accounts, calendar: host.environment.calendar),
        accounts: accounts, environment: host.environment
      ).hasPrefix(
        host.environment.language("entry.transfer.preview", table: "Entry")
          + " Наличные → Карта для поездок, "), true)

    XCTAssertTrue(host.window.makeFirstResponder(quick))
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.map(\.fromAccountId), [cash.id])
    XCTAssertEqual(written.map(\.toAccountId), [travel.id])
    XCTAssertEqual(written.first?.fromAmountE4, AmountE4(whole: 1000))
    XCTAssertEqual(try host.transactions.count(), 0, "a transfer is no expense")
    XCTAssertNil(host.window.attachedSheet)
    XCTAssertEqual(quick.stringValue, "", "the quick line was not cleared")
  }

  /// «перевод маше 500» is an expense, as it always was: no transfer, no sheet.
  func testAPersonIsNoTransfer() async throws {
    let host = try await makeHost()
    XCTAssertNil(read("перевод маше 500", in: host).transfer)
    try type("перевод маше 500", in: host)
    host.settle(0.5)
    XCTAssertNil(host.window.attachedSheet, "a transfer opened for a person")
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty)
  }
}
