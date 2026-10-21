import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Transfers between accounts")
struct TransferRulesTests {
  let categories = StartingCategories()
  let kzt = CurrencyCode("KZT")

  var card: PaymentMethod { PaymentMethod(id: id(1), name: "Card", currency: .rub) }
  var multi: PaymentMethod {
    PaymentMethod(id: id(2), name: "Multi", currency: .eur, otherCurrencies: [.usd, .rub, kzt])
  }

  func transfer(
    from: (UUID, CurrencyCode, Int), to: (UUID, CurrencyCode, Int)
  ) -> Transfer {
    Transfer(
      id: id(70), occurredAt: moment("2026-03-02"), fromAccountId: from.0, fromCurrency: from.1,
      fromAmountE4: money(from.2), toAccountId: to.0, toCurrency: to.1, toAmountE4: money(to.2))
  }

  @Test func aTransferBetweenHeldCurrenciesIsFine() {
    let accounts = [card, multi]
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 1000), to: (id(2), .rub, 1000)),
        accounts: accounts) == nil)
    // An exchange inside one account is a transfer between two of its currencies.
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .rub, 10_000), to: (id(2), kzt, 55_000)),
        accounts: accounts) == nil)
  }

  @Test func whatIsWrongIsSaid() {
    let accounts = [card, multi]
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 0), to: (id(2), .rub, 0)),
        accounts: accounts) == .notPositive)
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .rub, 10), to: (id(2), .rub, 10)),
        accounts: accounts) == .sameKey)
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .usd, 10), to: (id(2), .usd, 10)),
        accounts: accounts) == .currencyNotHeld(.from))
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .usd, 10), to: (id(1), .usd, 10)),
        accounts: accounts) == .currencyNotHeld(.to))
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 1000), to: (id(2), .rub, 990)),
        accounts: accounts) == .amountsDiffer)
    var archived = multi
    archived.archived = true
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 10), to: (id(2), .rub, 10)),
        accounts: [card, archived]) == .archivedAccount)
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 10), to: (id(9), .rub, 10)),
        accounts: [card]) == .archivedAccount)
  }

  /// Money left on an account in the archive by an edit of its past is moved off it: the
  /// archived side named in the set is allowed, any other archived side still is not, and an
  /// account that is not there never is.
  @Test func anArchivedSideNamedInTheSetIsAllowed() {
    var archived = multi
    archived.archived = true
    let accounts = [card, archived]
    let out = transfer(from: (id(2), .rub, 1000), to: (id(1), .rub, 1000))
    let back = transfer(from: (id(1), .rub, 1000), to: (id(2), .rub, 1000))
    #expect(TransferRules.validate(out, accounts: accounts) == .archivedAccount)
    #expect(TransferRules.validate(out, accounts: accounts, allowingArchived: [id(2)]) == nil)
    #expect(TransferRules.validate(back, accounts: accounts, allowingArchived: [id(2)]) == nil)
    #expect(
      TransferRules.validate(out, accounts: accounts, allowingArchived: [id(1)])
        == .archivedAccount)
    var bothArchived = card
    bothArchived.archived = true
    #expect(
      TransferRules.validate(out, accounts: [bothArchived, archived], allowingArchived: [id(2)])
        == .archivedAccount)
    #expect(
      TransferRules.validate(
        transfer(from: (id(9), .rub, 10), to: (id(1), .rub, 10)), accounts: accounts,
        allowingArchived: [id(9)]) == .archivedAccount)
    // Every other rule still holds for an allowed side.
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .rub, 1000), to: (id(1), .rub, 990)), accounts: accounts,
        allowingArchived: [id(2)]) == .amountsDiffer)
  }

  /// The transfer that keeps an archived account at zero after a change of its past: built by
  /// `ArchivedMoney`, it names the archived side, and with that side allowed it is a transfer
  /// like any other, whichever way the money goes.
  @Test func aSettlingTransferMayTouchAnArchivedAccount() {
    var archived = multi
    archived.archived = true
    let accounts = [card, archived]
    for amount in [money(1_000), money(-1_000)] {
      let leftover = ArchivedLeftover(
        key: BalanceKey(accountId: id(2), currency: .rub), amount: amount,
        latest: moment("2026-03-02"))
      let settling = ArchivedMoney.settlingTransfer(
        leftover, counterpart: id(1), counterpartCountedAt: nil, now: moment("2026-03-05"),
        note: nil, id: id(71))
      #expect(TransferRules.validate(settling, accounts: accounts) == .archivedAccount)
      #expect(
        TransferRules.validate(settling, accounts: accounts, allowingArchived: [id(2)]) == nil)
      #expect(settling.fromAmountE4 == money(1_000) && settling.toAmountE4 == money(1_000))
      #expect(settling.occurredAt == moment("2026-03-05"))
    }
  }

  /// A new transfer to or from an account in the archive is still refused: only a transfer
  /// that settles a change of its past may name it.
  @Test func aNewTransferToAnArchivedAccountIsRefused() {
    var archived = multi
    archived.archived = true
    let accounts = [card, archived]
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 500), to: (id(2), .rub, 500)), accounts: accounts)
        == .archivedAccount)
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .eur, 5), to: (id(1), .rub, 500)), accounts: accounts)
        == .archivedAccount)
  }

  @Test func theFeeIsAnExpenseFromTheAccountTheMoneyLeft() {
    let move = transfer(from: (id(2), .usd, 100), to: (id(1), .rub, 9000))
    let draft = TransferRules.feeDraft(
      transfer: move, fee: money(2), categoryId: categories.fees, tree: categories.tree)
    #expect(draft.kind == .expense)
    #expect(draft.paymentMethodId == id(2))
    #expect(draft.currency == .usd)
    #expect(draft.amount == money(2))
    #expect(draft.occurredAt == move.occurredAt)
    #expect(draft.parts.map(\.categoryId) == [categories.fees])
    #expect(draft.parts.first?.quality == .bad)
    #expect(OperationLink(externalId: TransferRules.feeKey(of: id(70))) == .transferFee(id(70)))
    #expect(OperationLink.transferFee(id(70)).isBookkeeping == false)
  }

  // MARK: The category of the fees

  @Test func theRememberedCategoryComesFirstWhileItIsLive() {
    let all = startingList()
    #expect(
      TransferRules.feeCategory(categories: all, remembered: categories.car)
        == .existing(categories.car))
    var archived = all
    if let index = archived.firstIndex(where: { $0.id == categories.car }) {
      archived[index].archived = true
    }
    #expect(
      TransferRules.feeCategory(categories: archived, remembered: categories.car)
        == .existing(categories.fees))
    // A system category is never where fees go.
    #expect(
      TransferRules.feeCategory(categories: all, remembered: categories.loans)
        == .existing(categories.fees))
  }

  @Test func aCategoryCalledFeesUnderOtherIsFound() {
    var all = startingList()
    all.append(CoreKit.Category(id: id(130), kind: .expense, name: "Комиссии", sort: -1))
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil) == .existing(categories.fees))
  }

  @Test func withoutOneItIsMadeUnderOther() {
    let all = startingList().filter { $0.id != categories.fees }
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil)
        == .create(nameKey: "category.fees", parent: categories.other, quality: .bad))
    let bare = all.filter { $0.id != categories.other }
    #expect(
      TransferRules.feeCategory(categories: bare, remembered: nil)
        == .create(nameKey: "category.fees", parent: nil, quality: .bad))
  }

  // MARK: The category of the fees, in the archive

  /// The starting «Fees» the owner put into the archive before any fee: the first fee brings
  /// it back — its parent «Other» is live — rather than making a second one.
  @Test func anArchivedStarterFeesCategoryComesBack() {
    let all = archiving([categories.fees], in: startingList())
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil)
        == .revive(categories.fees, parent: nil))
    // Remembered, it comes back the same way.
    #expect(
      TransferRules.feeCategory(categories: all, remembered: categories.fees)
        == .revive(categories.fees, parent: nil))
  }

  /// «Bank → Комиссии», remembered, and the whole «Bank» in the archive: both come back,
  /// the parent named. Only the parent archived, the category still marked live, is the same.
  @Test func aRememberedFeesUnderAnArchivedParentComesBackWithIt() {
    let bank = CoreKit.Category(id: id(140), kind: .expense, name: "Bank", archived: true)
    let bankFees = CoreKit.Category(
      id: id(141), parentId: bank.id, kind: .expense, name: "Комиссии", archived: true)
    let withoutStarter = startingList().filter { $0.id != categories.fees }
    #expect(
      TransferRules.feeCategory(
        categories: withoutStarter + [bank, bankFees], remembered: bankFees.id)
        == .revive(bankFees.id, parent: bank.id))
    var liveChild = bankFees
    liveChild.archived = false
    #expect(
      TransferRules.feeCategory(
        categories: withoutStarter + [bank, liveChild], remembered: bankFees.id)
        == .revive(bankFees.id, parent: bank.id))
    // Not remembered, it is found by its name all the same.
    #expect(
      TransferRules.feeCategory(categories: withoutStarter + [bank, bankFees], remembered: nil)
        == .revive(bankFees.id, parent: bank.id))
    // A remembered category of another name comes back too: it is where the fees went.
    let charges = CoreKit.Category(
      id: id(142), parentId: bank.id, kind: .expense, name: "Bank charges", archived: true)
    #expect(
      TransferRules.feeCategory(
        categories: withoutStarter + [bank, charges, bankFees], remembered: charges.id)
        == .revive(charges.id, parent: bank.id))
  }

  /// «Other» and its «Fees» both in the archive, nothing remembered: «Fees» comes back with
  /// «Other». An archived «Комиссии» of its own at the top loses to the one under «Other».
  @Test func anArchivedFeesUnderAnArchivedOtherComesBackWithIt() {
    let all = archiving([categories.other, categories.fees], in: startingList())
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil)
        == .revive(categories.fees, parent: categories.other))
    let top = CoreKit.Category(
      id: id(143), kind: .expense, name: "Комиссии", sort: -5, archived: true)
    #expect(
      TransferRules.feeCategory(categories: [top] + all, remembered: nil)
        == .revive(categories.fees, parent: categories.other))
    // Without «Other» the one at the top is found.
    let bare = all.filter { $0.id != categories.other && $0.id != categories.fees }
    #expect(
      TransferRules.feeCategory(categories: [top] + bare, remembered: nil)
        == .revive(top.id, parent: nil))
  }

  /// A live «Комиссии» anywhere is used before anything is brought back from the archive —
  /// the remembered one in the archive included.
  @Test func aLiveFeesCategoryWinsOverAnArchivedOne() {
    let all = archiving([categories.fees], in: startingList())
    let live = CoreKit.Category(id: id(144), kind: .expense, name: "комиссии ")
    #expect(
      TransferRules.feeCategory(categories: all + [live], remembered: nil) == .existing(live.id))
    #expect(
      TransferRules.feeCategory(categories: all + [live], remembered: categories.fees)
        == .existing(live.id))
  }

  /// Nothing under a system category is where fees go, archived or not: a «Fees» filed under
  /// «Loans» is neither used nor brought back, and a new category is made.
  @Test func aSystemParentIsNeverRevived() {
    let underLoans = CoreKit.Category(
      id: id(145), parentId: categories.loans, kind: .expense, name: "Fees", archived: true)
    let all = startingList().filter { $0.id != categories.fees } + [underLoans]
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil)
        == .create(nameKey: "category.fees", parent: categories.other, quality: .bad))
    #expect(
      TransferRules.feeCategory(categories: all, remembered: underLoans.id)
        == .create(nameKey: "category.fees", parent: categories.other, quality: .bad))
    // Nor an income category of that name.
    let income = CoreKit.Category(id: id(146), kind: .income, name: "Fees", archived: true)
    #expect(
      TransferRules.feeCategory(
        categories: startingList().filter { $0.id != categories.fees } + [income],
        remembered: income.id)
        == .create(nameKey: "category.fees", parent: categories.other, quality: .bad))
  }

  /// `list` with the categories `ids` put into the archive.
  func archiving(_ ids: Set<UUID>, in list: [CoreKit.Category]) -> [CoreKit.Category] {
    list.map { category in
      var category = category
      if ids.contains(category.id) { category.archived = true }
      return category
    }
  }

  /// The starting categories of the fixture as a list.
  func startingList() -> [CoreKit.Category] {
    [
      categories.goals, categories.goalsTrip, categories.loans, categories.loansCar,
      categories.surcharges, categories.unknown, categories.groceries, categories.education,
      categories.health, categories.pharmacy, categories.car, categories.fines, categories.fuel,
      categories.other, categories.fees, categories.salary, categories.bonus,
    ].compactMap { categories.tree[$0] }
  }
}
