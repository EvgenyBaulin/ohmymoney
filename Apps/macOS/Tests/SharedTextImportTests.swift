import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class SharedTextImportTests: XCTestCase {
  private var book: MacCommandsBook?
  private let text = "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽. Код 9911"

  override func setUp() async throws {
    let book = try await MacCommandsBook()
    self.book = book
    let cards = CardActions(environment: book.environment, store: book.store)
    XCTAssertEqual(
      cards.save(
        PaymentCard(accountId: book.sber.id, name: "Synthetic", last4: "7788"), previous: nil),
      .done)
    book.environment.refreshVocabulary()
    try await book.reload()
  }

  override func tearDown() async throws {
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.pendingKey)
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.fingerprintsKey)
    await book?.close()
    book = nil
  }

  func testSharingAMessageOffersOneDraftAndKeepsNoBankCodes() throws {
    let book = try XCTUnwrap(book)
    let before = try book.entries().count
    XCTAssertEqual(SharedTextImport.propose(text, deps: book.dependencies), "share.draftSaved")
    let drafts = SettingsDraftStore(settings: book.environment.settings).load()
    XCTAssertEqual(drafts.count, 1)
    let line = try XCTUnwrap(drafts.first?.text)
    XCTAssertTrue(line.contains("450"))
    XCTAssertFalse(line.contains("9911"))
    XCTAssertEqual(try book.entries().count, before)
    XCTAssertEqual(SharedTextImport.propose(text, deps: book.dependencies), "autoEntry.duplicate")
    XCTAssertEqual(SettingsDraftStore(settings: book.environment.settings).load().count, 1)
  }

  func testUnrecognisedTextKeepsNothing() throws {
    let book = try XCTUnwrap(book)
    XCTAssertEqual(
      SharedTextImport.propose("synthetic words", deps: book.dependencies), "autoEntry.notBank")
    XCTAssertTrue(SettingsDraftStore(settings: book.environment.settings).load().isEmpty)
  }

  func testSharingTextsHaveBothLanguages() throws {
    let book = try XCTUnwrap(book)
    let previous = book.environment.language.choice
    defer { book.environment.language.choice = previous }
    for choice in [AppLanguage.Choice.russian, .english] {
      let language = book.environment.language
      language.choice = choice
      for key in ["share.messageTitle", "share.draftSaved", "share.failed", "share.damaged"] {
        XCTAssertNotEqual(language(key, table: "ShareImport"), key)
      }
    }
  }
}
