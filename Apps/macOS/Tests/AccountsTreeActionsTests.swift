import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What the tree of «Настройки → Счета» does to several accounts at once, against a real
/// database: a drag moves an account to another group and place, «В группу…», «Скрыть» and «В
/// архив» move all the marked ones — each one change and one step of ⌘Z, refused as a whole when
/// one of them cannot follow.
@MainActor
final class AccountsTreeActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let money = AccountGroup(name: "Деньги", sort: 1)
  private let savings = AccountGroup(name: "Накопления", inSummary: false, sort: 2)
  private let credit = AccountGroup(name: "Кредитки", sort: 3)
  private lazy var main = PaymentMethod(
    name: "Дебетовый", kind: .card, currency: .rub, isDefault: true, groupId: money.id, sort: 1)
  private lazy var second = PaymentMethod(
    name: "Дебетовая", kind: .card, currency: .rub, groupId: money.id, sort: 2)
  private lazy var cash = PaymentMethod(
    name: "Наличные", kind: .cash, currency: .rub, groupId: money.id, sort: 3)
  private lazy var deposit = PaymentMethod(
    name: "Вклад", kind: .account, currency: .rub, sort: 4)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-tree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            accountGroups: [money, savings, credit],
            paymentMethods: [main, second, cash, deposit]))))
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func account(_ id: UUID) throws -> PaymentMethod {
    try XCTUnwrap(actions.all.first { $0.id == id })
  }

  private func rows() -> [AccountsTree.Row] {
    let tree = AccountsTree.build(
      accounts: actions.all, groups: actions.groups, banks: actions.banks, cards: actions.cards,
      snapshot: nil, locale: Locale(identifier: "ru"))
    return AccountsTree.rows(tree, collapsed: AccountsTree.foldedAtFirst)
  }

  /// «Вклад» dragged under «Кредитки»: it goes to that group and after the last account above
  /// the gap; ⌘Z puts back its group and every place at once.
  func testADragMovesTheAccountToTheGroupAndPlaceInOneStep() throws {
    let rows = rows()
    let source = try XCTUnwrap(rows.firstIndex { $0.node.account?.id == deposit.id })
    let creditRow = try XCTUnwrap(rows.firstIndex { $0.id == "g:\(credit.id.uuidString)" })
    let drop = try XCTUnwrap(AccountsTree.drop(rows, from: source, to: creditRow + 1))
    XCTAssertEqual(drop.groupId, credit.id)
    XCTAssertEqual(actions.place(drop), .done)
    XCTAssertEqual(try account(deposit.id).groupId, credit.id)
    let order = actions.ordered(actions.all).map(\.id)
    XCTAssertEqual(order.first, main.id, "the main account stays first")
    XCTAssertEqual(order.last, deposit.id)
    store.undo()
    XCTAssertNil(try account(deposit.id).groupId)
    XCTAssertEqual(try account(deposit.id).sort, 4)
  }

  /// «В группу…» moves the marked accounts together; ⌘Z brings both back.
  func testToGroupMovesAllTheMarkedInOneStep() throws {
    XCTAssertEqual(actions.moveToGroup([second.id, cash.id], credit.id), .done)
    XCTAssertEqual(try account(second.id).groupId, credit.id)
    XCTAssertEqual(try account(cash.id).groupId, credit.id)
    store.undo()
    XCTAssertEqual(try account(second.id).groupId, money.id)
    XCTAssertEqual(try account(cash.id).groupId, money.id)
    // «Без группы».
    XCTAssertEqual(actions.moveToGroup([cash.id], nil), .done)
    XCTAssertNil(try account(cash.id).groupId)
  }

  /// The main account never leaves the summary: a group out of it refuses the whole move.
  func testTheMainAccountRefusesAGroupOutOfTheSummary() throws {
    XCTAssertEqual(
      actions.moveToGroup([main.id, second.id], savings.id), .refused(.mainInExcludedGroup))
    XCTAssertEqual(try account(second.id).groupId, money.id, "nothing moved")
  }

  /// «Скрыть», then «Показать», each one step of ⌘Z.
  func testHideAndShowTheMarked() throws {
    XCTAssertEqual(actions.setHidden([second.id, deposit.id], true), .done)
    XCTAssertTrue(try account(second.id).hidden)
    XCTAssertTrue(try account(deposit.id).hidden)
    let hidden = AccountsTree.rows(
      AccountsTree.build(
        accounts: actions.all, groups: actions.groups, banks: actions.banks, cards: [],
        snapshot: nil, locale: Locale(identifier: "ru")), collapsed: [])
    let place = try XCTUnwrap(hidden.first { $0.id == "hidden" })
    XCTAssertEqual(place.node.children.count, 2, "the hidden ones stand under «Скрытые»")
    store.undo()
    XCTAssertFalse(try account(second.id).hidden)
    XCTAssertFalse(try account(deposit.id).hidden)
  }

  /// «В архив» for several accounts with no money: together, one step; the main account among
  /// them refuses the whole, since who takes over is asked of one account.
  func testToArchiveTakesTheMarkedTogetherOrNone() async throws {
    let read = await actions.books()
    let books = try XCTUnwrap(read)
    XCTAssertEqual(actions.archive([main.id, second.id], books: books), .refused(.needsNewMain))
    XCTAssertFalse(try account(second.id).archived)
    XCTAssertEqual(actions.archive([second.id, cash.id], books: books), .done)
    XCTAssertTrue(try account(second.id).archived)
    XCTAssertTrue(try account(cash.id).archived)
    store.undo()
    XCTAssertFalse(try account(second.id).archived)
    XCTAssertFalse(try account(cash.id).archived)
  }

  /// The cashback of the panel: «Меняются каждый месяц» when the bank opens a choice, «Постоянные»
  /// with rules of the account or of its cards, «Нет» otherwise.
  func testTheCashbackOfThePanelIsReadFromTheAccount() {
    var account = second
    let card = PaymentCard(accountId: account.id, name: "Black")
    XCTAssertEqual(
      AccountsSettingsView.cashbackKey(of: account, cards: [card], rules: []),
      "panel.cashback.none")
    let rule = CashbackRule(
      accountId: account.id, cardId: card.id, percent: CashbackPercent(e4: 10_000)!)
    XCTAssertEqual(
      AccountsSettingsView.cashbackKey(of: account, cards: [card], rules: [rule]),
      "panel.cashback.constant")
    account.cashbackChoiceDay = 25
    XCTAssertEqual(
      AccountsSettingsView.cashbackKey(of: account, cards: [card], rules: [rule]),
      "panel.cashback.monthly")
  }

  /// The groups folded in the main sidebar: a chevron folds and unfolds, the rest stay.
  func testTheFoldOfTheSidebarGroups() {
    let one = UUID()
    let two = UUID()
    var stored = AccountsSidebarFold.toggled(one, in: "")
    XCTAssertEqual(AccountsSidebarFold.decode(stored), [one])
    stored = AccountsSidebarFold.toggled(two, in: stored)
    XCTAssertEqual(AccountsSidebarFold.decode(stored), [one, two])
    stored = AccountsSidebarFold.toggled(one, in: stored)
    XCTAssertEqual(AccountsSidebarFold.decode(stored), [two])
    XCTAssertEqual(AccountsSidebarFold.decode("garbage,\(two.uuidString)"), [two])
    XCTAssertEqual(AccountsSidebarMetrics.dot, 9)
    XCTAssertEqual(AccountsSidebarMetrics.memberIndent, 18)
  }
}
