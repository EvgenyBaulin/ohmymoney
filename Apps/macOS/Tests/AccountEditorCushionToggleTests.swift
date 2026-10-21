import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Деньги подушки безопасности» of the account editor: the draft reads the mark and gives it
/// back, saving writes it with the rest of the account in its step of ⌘Z, and the account's
/// screen says «Подушка».
@MainActor
final class AccountEditorCushionToggleTests: CushionDatabaseTestCase {
  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  /// The switch is off for a new account, reads what an account has, and the account the draft
  /// saves carries it.
  func testTheDraftCarriesTheMark() {
    var draft = AccountDraft(newIn: .rub)
    XCTAssertFalse(draft.cushion)
    draft.name = "Копилка"
    draft.cushion = true
    XCTAssertTrue(draft.account(over: nil).cushion)

    var marked = PaymentMethod(name: "Вклад", kind: .account, currency: .rub)
    marked.cushion = true
    let read = AccountDraft(marked)
    XCTAssertTrue(read.cushion)
    var off = read
    off.cushion = false
    XCTAssertFalse(off.account(over: marked).cushion, "taken off over the stored account")
  }

  /// An edit that marks the account is written, and its ⌘Z takes the mark away again.
  func testSavingTheMarkIsTheAccountsStepOfUndo() async throws {
    let savings = try account("Копилка")
    var draft = AccountDraft(savings)
    draft.cushion = true
    let fetched = await actions.books()
    let books = try XCTUnwrap(fetched)
    XCTAssertEqual(
      actions.save(draft.account(over: savings), previous: savings, books: books), .done)
    XCTAssertEqual(try accounts().first { $0.id == savings.id }?.cushion, true)
    store.undo()
    XCTAssertEqual(try accounts().first { $0.id == savings.id }?.cushion, false)
  }

  /// The words of the switch and of the badge, in both languages.
  func testTheWords() {
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("account.editor.cushion", table: AccountText.table),
      "Деньги подушки безопасности")
    XCTAssertEqual(environment.language("accounts.cushion", table: AccountText.table), "Подушка")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.language("account.editor.cushion", table: AccountText.table),
      "Money of the safety cushion")
  }
}
