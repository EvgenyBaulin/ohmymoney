import AppCore
import XCTest

@testable import OhMyMoney

/// The colour of an account: a palette of twelve that reads on every theme, saved with the
/// account in one step of ⌘Z, and shown as a dot on the rows of its operations.
@MainActor
final class AccountAccentPaletteTests: XCTestCase {
  func testThereAreTwelveKeysFromZeroOneToTwelve() {
    XCTAssertEqual(
      AccountAccent.allCases.map(\.key), (1...12).map { String(format: "%02d", $0) })
    XCTAssertNil(AccountAccent(key: nil))
    XCTAssertNil(AccountAccent(key: "13"))
    XCTAssertEqual(AccountAccent(key: "07"), .c07)
  }

  /// A dot or a stripe is a graphic, which needs 3 : 1 against what it stands on: the
  /// backgrounds, cards and sidebars of every theme in both schemes, light ones and black ones.
  func testEveryColourHoldsThreeToOneOnEverySurfaceOfEveryTheme() {
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        for surface in [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar] {
          for accent in AccountAccent.allCases {
            XCTAssertGreaterThanOrEqual(
              accent.color.contrast(on: surface), 3, "\(theme.id) \(scheme) \(accent.key)")
          }
        }
      }
    }
  }

  /// The colour of a card is read with white words on it, to the corner the gradient darkens to.
  func testWhiteWordsOnACardOfEveryColourReadAtFourAndAHalf() {
    let white = ThemeColor(0xFFFF_FFFF)
    for accent in AccountAccent.allCases {
      XCTAssertGreaterThanOrEqual(white.contrast(on: accent.color), 4.5, accent.key)
    }
  }

  func testNoTwoColoursLookAlike() {
    let all = AccountAccent.allCases
    for (index, a) in all.enumerated() {
      for b in all[(index + 1)...] {
        let dr = Double(a.color.red) - Double(b.color.red)
        let dg = Double(a.color.green) - Double(b.color.green)
        let db = Double(a.color.blue) - Double(b.color.blue)
        XCTAssertGreaterThan((dr * dr + dg * dg + db * db).squareRoot(), 40, "\(a.key) \(b.key)")
      }
    }
  }

  func testEveryColourHasANameInBothLanguages() {
    let environment = AppEnvironment()
    for accent in AccountAccent.allCases {
      for language in [AppLanguage.Choice.english, .russian] {
        environment.language.choice = language
        let name = environment.language(accent.nameKey, table: "Accounts")
        XCTAssertNotEqual(name, accent.nameKey, "\(accent.key) \(language)")
      }
    }
  }
}

final class AccountAccentSaveTests: AccountsScenarioDatabaseCase {
  func testTheColourIsSavedWithTheAccountAndOneUndoTakesItBack() async throws {
    let saved = try await make(PaymentMethod(name: "Альфа", isDefault: true))
    XCTAssertNil(saved.accent)
    var draft = AccountDraft(saved)
    draft.accent = AccountAccent.c05.key
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(draft.account(over: saved), previous: saved, books: books), .done)
    XCTAssertEqual(try account(saved.id).accountAccent, .c05)
    store.undo()
    XCTAssertNil(try account(saved.id).accent)
  }

  func testChoosingNoColourClearsIt() async throws {
    let saved = try await make(PaymentMethod(name: "Альфа", isDefault: true, accent: "02"))
    XCTAssertEqual(try account(saved.id).accountAccent, .c02)
    var draft = AccountDraft(saved)
    XCTAssertEqual(draft.accent, "02")
    draft.accent = nil
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(draft.account(over: saved), previous: saved, books: books), .done)
    XCTAssertNil(try account(saved.id).accent)
  }
}

@MainActor
final class AccountAccentRowTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let food = CoreKit.Category(kind: .expense, name: "Еда")

  private func rows(
    accounts: [PaymentMethod], on account: PaymentMethod?
  ) throws
    -> [TransactionRowItem]
  {
    let moment = calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 16))
      .addingTimeInterval(12 * 3600)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: moment, currency: .rub, amount: AmountE4(whole: 100),
      note: "кофе", paymentMethodId: account?.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    let entry = try draft.materialize(now: moment)
    let ledger = Ledger(
      dataset: Dataset(entries: [entry], categories: [food], paymentMethods: accounts),
      calendar: calendar)
    return TransactionListing.build(matching: .none, in: ledger).sections.flatMap(\.rows)
  }

  func testAnOperationOnAnAccountWithAColourCarriesItAndItsName() throws {
    let account = PaymentMethod(name: "Альфа", currency: .rub, isDefault: true, accent: "09")
    let row = try XCTUnwrap(rows(accounts: [account], on: account).first)
    XCTAssertEqual(row.accountAccent, .c09)
    XCTAssertEqual(row.paymentMethod, "Альфа")
  }

  func testNoDotWithoutAColourOrWithoutAnAccount() throws {
    let plain = PaymentMethod(name: "Альфа", currency: .rub, isDefault: true)
    XCTAssertNil(try rows(accounts: [plain], on: plain).first?.accountAccent)
    let coloured = PaymentMethod(name: "Т-Банк", currency: .rub, accent: "03")
    XCTAssertNil(try rows(accounts: [coloured], on: nil).first?.accountAccent)
  }

  func testAKeyThisVersionDoesNotKnowShowsNoDot() throws {
    let account = PaymentMethod(name: "Альфа", currency: .rub, isDefault: true, accent: "99")
    XCTAssertNil(try rows(accounts: [account], on: account).first?.accountAccent)
  }
}
