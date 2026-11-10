import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The debts of the design's frames of «Долги», as data: two loans and an instalment plan I owe
/// and Anna, who owes me — every figure of the frames comes out of them.
@MainActor
enum DebtsFigmaBoard {
  static let anna = Person(name: "Анна")
  static let credit = Debt(
    direction: .iOwe, type: .loan, name: "Кредит · Т-Банк", interestRate: Decimal(string: "14.5"),
    monthlyPaymentE4: AmountE4(whole: 18_400), origin: .purchase)
  static let mortgage = Debt(
    direction: .iOwe, type: .loan, name: "Ипотека · Сбербанк",
    interestRate: Decimal(string: "9.8"), monthlyPaymentE4: AmountE4(whole: 16_402))
  static let laptop = Debt(
    direction: .iOwe, type: .installment, name: "Рассрочка · Ноутбук", interestRate: 0,
    monthlyPaymentE4: AmountE4(whole: 3_300), origin: .purchase, parts: 6)
  static let lent = Debt(
    direction: .owedToMe, type: .personal, name: "Анне", personId: anna.id, interestRate: 0,
    monthlyPaymentE4: AmountE4(whole: 2_000))

  static func line(_ debt: Debt, borrowed: Int64, balance: Int64, next: DateOnly) -> DebtLine {
    DebtLine(
      debt: debt, balance: AmountE4(whole: balance), balanceRub: nil, groups: [],
      nextPayment: next, paidThisMonth: false,
      entries: [DebtEntry(debtId: debt.id, amountE4: AmountE4(whole: borrowed), kind: .borrowed)])
  }

  static var overview: DebtsOverview {
    let owed = line(
      lent, borrowed: 16_000, balance: 12_000, next: DateOnly(year: 2026, month: 12, day: 5))
    return DebtsOverview(
      iOwe: [
        line(
          laptop, borrowed: 19_800, balance: 13_200, next: DateOnly(year: 2026, month: 11, day: 15)),
        line(
          mortgage, borrowed: 1_400_000, balance: 1_120_000,
          next: DateOnly(year: 2026, month: 11, day: 20)),
        line(
          credit, borrowed: 230_000, balance: 142_600,
          next: DateOnly(year: 2026, month: 11, day: 28)),
      ],
      owedToMe: [
        OwedToMeGroup(
          personId: anna.id, debts: [owed], parts: [], totalRub: AmountE4(whole: 12_000),
          oldest: nil)
      ],
      closed: [], totalIOweRub: AmountE4(whole: 1_275_800),
      totalOwedToMeRub: AmountE4(whole: 12_000), monthlyPaymentsRub: AmountE4(whole: 38_102),
      withoutRate: [])
  }

  static var board: DebtsBoard { DebtsBoard(overview: overview, people: [anna]) }

  static let ladderDebts: [LadderDebt] = [credit, mortgage, laptop].map { debt in
    let balance: Int64 =
      switch debt.id {
      case credit.id: 142_600
      case mortgage.id: 1_120_000
      default: 13_200
      }
    return LadderDebt(
      id: debt.id, source: .debt(debt.id), name: debt.name, balanceRub: AmountE4(whole: balance),
      ratePercent: debt.interestRate ?? 0, minimumRub: debt.monthlyPaymentE4 ?? .zero)
  }

  static func ladder(extra: Int64) -> DebtsLadderCard? {
    DebtsLadderCard(
      candidates: ladderDebts, extra: AmountE4(whole: extra), method: .avalanche,
      start: MonthKey(year: 2026, month: 11))
  }
}

/// «Долги» without a debt open: the summary, the cards by group and the payoff ladder, worked
/// out of the data as the design's frames show it, and the page laid out by the frame's numbers.
@MainActor
final class DebtsBoardTests: XCTestCase {
  private var windows: [NSWindow] = []
  private var languageBefore: AppLanguage.Choice?
  private let environment = AppEnvironment()

  override func setUp() {
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  override func tearDown() {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment.language.choice = languageBefore }
  }

  // MARK: The figures

  func testTheSummaryHasTheFiguresOfTheFrame() {
    let summary = DebtsFigmaBoard.board.summary
    XCTAssertEqual(summary.iOwe, AmountE4(whole: 1_275_800))
    XCTAssertEqual(summary.iOweCount, 3)
    XCTAssertEqual(summary.monthly, AmountE4(whole: 38_102))
    XCTAssertEqual(summary.nextPayment, DateOnly(year: 2026, month: 11, day: 15))
    XCTAssertEqual(summary.owedToMe, AmountE4(whole: 12_000))
    XCTAssertEqual(summary.peopleCount, 1)
    let language = environment.language
    XCTAssertEqual(language.format("debts.summary.debts", table: "Debts", counts: 3), "3 долга")
    XCTAssertEqual(language.format("debts.summary.debts", table: "Debts", counts: 5), "5 долгов")
    XCTAssertEqual(language.format("debts.summary.people", table: "Debts", counts: 1), "1 человек")
    XCTAssertEqual(
      environment.format("debts.summary.next", table: "Debts", "15 ноя"), "следующий платёж 15 ноя")
  }

  func testTheGroupsAreTheFramesAndTheSingleCardsShareARow() {
    let board = DebtsFigmaBoard.board
    XCTAssertEqual(board.groups.map(\.kind), [.iOwe, .owedToMe, .instalments])
    XCTAssertEqual(
      board.groups[0].cards.map(\.name).sorted(), ["Ипотека · Сбербанк", "Кредит · Т-Банк"])
    XCTAssertEqual(board.groups[1].cards.map(\.name), ["Анна"])
    XCTAssertEqual(board.groups[2].cards.map(\.name), ["Рассрочка · Ноутбук"])
    // «Мне должны · 1» beside «Рассрочки · 1» on the Mac and the iPad; one under the other on
    // the phone.
    XCTAssertEqual(board.rows(columns: 2).map(\.id), [[.iOwe], [.owedToMe, .instalments]])
    XCTAssertEqual(board.rows(columns: 1).map(\.id), [[.iOwe], [.owedToMe], [.instalments]])
  }

  func testAClosedGroupNeverSharesARow() {
    var board = DebtsFigmaBoard.board
    let closed = DebtsBoard.card(
      of: DebtsFigmaBoard.line(
        Debt(direction: .iOwe, type: .loan, name: "Старый", closed: true), borrowed: 100,
        balance: 0, next: DateOnly(year: 2026, month: 1, day: 1)))
    board.groups = [
      board.groups[2], DebtsBoard.Group(kind: .closed, cards: [closed]),
    ]
    XCTAssertEqual(board.rows(columns: 2).map(\.id), [[.instalments], [.closed]])
  }

  func testACardSaysWhatIsPaidOfWhatWasBorrowed() throws {
    let cards = DebtsFigmaBoard.board.groups.flatMap(\.cards)
    let byName = Dictionary(uniqueKeysWithValues: cards.map { ($0.name, $0) })
    let credit = try XCTUnwrap(byName["Кредит · Т-Банк"])
    XCTAssertEqual(credit.percent, 38)
    XCTAssertEqual(credit.paid, AmountE4(whole: 87_400))
    XCTAssertEqual(credit.total, AmountE4(whole: 230_000))
    XCTAssertEqual(credit.rate, Decimal(string: "14.5"))
    XCTAssertEqual(credit.payment, AmountE4(whole: 18_400))
    XCTAssertEqual(credit.labelKey, "debts.badge.purchase")
    XCTAssertEqual(credit.symbol, "creditcard")
    XCTAssertEqual(try XCTUnwrap(byName["Ипотека · Сбербанк"]).percent, 20)
    XCTAssertEqual(try XCTUnwrap(byName["Ипотека · Сбербанк"]).symbol, "house")
    let laptop = try XCTUnwrap(byName["Рассрочка · Ноутбук"])
    XCTAssertEqual(laptop.percent, 33)
    XCTAssertEqual(laptop.symbol, "calendar")
    let anna = try XCTUnwrap(byName["Анна"])
    XCTAssertEqual(anna.percent, 25)
    XCTAssertEqual(anna.paid, AmountE4(whole: 4_000))
    XCTAssertEqual(anna.total, AmountE4(whole: 16_000))
    XCTAssertEqual(anna.rate, 0)
    XCTAssertEqual(anna.payment, AmountE4(whole: 2_000))
    XCTAssertEqual(anna.nextDue, DateOnly(year: 2026, month: 12, day: 5))
    XCTAssertEqual(anna.progressKey, "debts.card.returnedShare")
    XCTAssertNil(anna.debtId, "a person is not deleted from the board")
    XCTAssertEqual(credit.progressKey, "debts.card.paidShare")
    XCTAssertEqual(
      environment.format("debts.card.paidShare", table: "Debts", "38 %"), "Выплачено 38 %")
    XCTAssertEqual(
      environment.format("debts.card.returnedShare", table: "Debts", "25 %"), "Возвращено 25 %")
    XCTAssertEqual(
      environment.format("debts.card.ofTotal", table: "Debts", "87 400", "230 000 ₽"),
      "87 400 из 230 000 ₽")
  }

  func testThePercentIsRoundedHalfAwayFromZeroAndKeptWithinTheWhole() {
    XCTAssertEqual(DebtsBoard.percent(AmountE4(whole: 1), of: AmountE4(whole: 200)), 1)
    XCTAssertEqual(DebtsBoard.percent(AmountE4(whole: 1), of: AmountE4(whole: 201)), 0)
    XCTAssertEqual(DebtsBoard.percent(AmountE4(whole: 300), of: AmountE4(whole: 200)), 100)
    XCTAssertEqual(DebtsBoard.percent(AmountE4(whole: -5), of: AmountE4(whole: 200)), 0)
    XCTAssertEqual(DebtsBoard.percent(AmountE4(whole: 5), of: .zero), 0)
  }

  func testTheLadderGoesByTheRateAndSaysWhatTheMoneyAboveGives() throws {
    let ladder = try XCTUnwrap(DebtsFigmaBoard.ladder(extra: 20_000))
    XCTAssertEqual(
      ladder.steps.map(\.name), ["Кредит · Т-Банк", "Ипотека · Сбербанк", "Рассрочка · Ноутбук"])
    let free = try XCTUnwrap(ladder.freeFrom)
    let without = try XCTUnwrap(ladder.freeWithout, "the money above brings the day nearer")
    XCTAssertLessThan(free, without)
    XCTAssertGreaterThan(try XCTUnwrap(ladder.interestSaved).raw, 0)
    XCTAssertEqual(
      environment.format("ladder.card.instead", table: "Debts", "май 2028", "марта 2030"),
      "май 2028 вместо марта 2030")
    XCTAssertEqual(
      environment.language("ladder.card.avalanche", table: "Debts"),
      "Лавина: сначала долг с самой высокой ставкой — меньше переплата.")
  }

  func testWithoutMoneyAboveTheLadderSaysOnlyWhen() throws {
    let ladder = try XCTUnwrap(DebtsFigmaBoard.ladder(extra: 0))
    XCTAssertNotNil(ladder.freeFrom)
    XCTAssertNil(ladder.freeWithout)
    XCTAssertNil(ladder.interestSaved)
    XCTAssertNil(
      DebtsLadderCard(
        candidates: [], extra: .zero, method: .avalanche, start: MonthKey(year: 2026, month: 11)))
  }

  func testAMonthOfTheLadderIsSaidInTheCaseThePhraseAsks() {
    let ru = Locale(identifier: "ru")
    XCTAssertEqual(
      DebtsLadderCardView.month(MonthKey(year: 2028, month: 5), genitive: false, locale: ru),
      "май 2028")
    XCTAssertEqual(
      DebtsLadderCardView.month(MonthKey(year: 2030, month: 3), genitive: true, locale: ru),
      "марта 2030")
  }

  func testTheNumbersOfTheFrame() {
    XCTAssertEqual(DebtsMetrics.columnGap, 16)
    XCTAssertEqual(DebtsMetrics.headerGap, 16)
    XCTAssertEqual(DebtsMetrics.sectionGap, 20)
    XCTAssertEqual(DebtsMetrics.groupTitleGap, 8)
    XCTAssertEqual(DebtsMetrics.summaryPadding, 16)
    XCTAssertEqual(DebtsMetrics.summaryIcon, 24)
    XCTAssertEqual(DebtsMetrics.cardPadding, 16)
    XCTAssertEqual(DebtsMetrics.cardGap, 10)
    XCTAssertEqual(DebtsMetrics.cardIcon, 32)
    XCTAssertEqual(DebtsMetrics.trackHeight, 6)
    XCTAssertEqual(DebtsMetrics.ladderPadding, 16)
    XCTAssertEqual(DebtsMetrics.ladderGap, 12)
    XCTAssertEqual(DebtsMetrics.phoneCardPadding, 14)
    XCTAssertEqual(DebtsMetrics.phoneStackGap, 14)
    XCTAssertEqual(DebtsMetrics.phoneCardStackGap, 12)
    // The content of the Mac frame is 1152 wide: three columns of 373.33, the groups 762.67.
    XCTAssertEqual(DebtsMetrics.column(in: 1_152), 373.333, accuracy: 0.01)
    XCTAssertEqual(
      2 * DebtsMetrics.column(in: 1_152) + DebtsMetrics.columnGap, 762.667, accuracy: 0.01)
    XCTAssertEqual(ContentCard.cornerRadius, 12, "a card of the Mac is rounded 12")
  }

  // MARK: The page

  private func show(
    width: CGFloat, height: CGFloat, board: DebtsBoard = DebtsFigmaBoard.board
  ) -> NSWindow {
    let view = DebtsBoardView(
      board: board, ladder: DebtsFigmaBoard.ladder(extra: 20_000), cardDebts: [], withoutRate: 0,
      reviewCount: 0, select: { _ in }, delete: { _ in }, create: {}, review: {}
    )
    .appDependencies(.forTests(environment))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderFront(nil)
    windows.append(window)
    settle(window)
    return window
  }

  private func settle(_ window: NSWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private struct NotFound: Error {}

  /// The frame of the element with `identifier`, in the window's coordinates (y up).
  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView,
        let found = Self.element(in: root, where: { $0.accessibilityIdentifier?() == identifier }),
        let onScreen = found.accessibilityFrame?(), onScreen.width > 0
      {
        return window.convertFromScreen(onScreen)
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  /// The element with `identifier`, or `nil` once the window has settled without it.
  private func lookUp(_ identifier: String, in window: NSWindow) -> AnyObject? {
    settle(window, passes: 5)
    guard let root = window.contentView else { return nil }
    return Self.element(in: root, where: { $0.accessibilityIdentifier?() == identifier })
  }

  private static func element(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = element(in: child as AnyObject, depth: depth + 1, where: matches) {
        return found
      }
    }
    return nil
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private func attachPicture(of window: NSWindow, named name: String) throws {
    let view = try XCTUnwrap(window.contentView)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The Mac frame 68:18237: content 1152 wide 28 from the edges, three tiles of the summary,
  /// the groups two columns wide, the ladder in the third and as tall as the groups, the gaps of
  /// the frame — and no list of debts anywhere on the page.
  func testTheBoardHasTheNumbersOfTheMacFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let side = StyleMetrics.pageSide
    let width = 1_152 + 2 * side
    try TestEnvironment.requireScreen(width: width)
    let window = show(width: width, height: 860)
    try attachPicture(of: window, named: "Долги 1208 × 860 (Figma 68:18237)")

    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    XCTAssertTrue(tables.isEmpty, "no list stands on the board: \(tables)")

    let column = DebtsMetrics.column(in: 1_152)
    let iOwe = try frame(of: "debts.summary.iOwe", in: window)
    let monthly = try frame(of: "debts.summary.monthly", in: window)
    let owedToMe = try frame(of: "debts.summary.owedToMe", in: window)
    XCTAssertEqual(iOwe.minX, side, accuracy: 1, "the page stands 28 from the edge")
    for tile in [iOwe, monthly, owedToMe] {
      XCTAssertEqual(tile.width, column, accuracy: 1.5, "a tile of the summary: \(tile)")
    }
    XCTAssertEqual(monthly.minX - iOwe.maxX, 16, accuracy: 1)
    XCTAssertEqual(owedToMe.minX - monthly.maxX, 16, accuracy: 1)
    XCTAssertEqual(owedToMe.maxX, width - side, accuracy: 1.5)
    XCTAssertEqual(iOwe.height, monthly.height, accuracy: 0.5, "the tiles share their height")

    let groups = try frame(of: "debts.groups", in: window)
    let ladder = try frame(of: "debts.ladder.card", in: window)
    XCTAssertEqual(groups.width, 2 * column + 16, accuracy: 1.5, "the groups: \(groups)")
    XCTAssertEqual(ladder.width, column, accuracy: 1.5, "the ladder: \(ladder)")
    XCTAssertEqual(ladder.minX - groups.maxX, 16, accuracy: 1)
    XCTAssertEqual(iOwe.minY - groups.maxY, 20, accuracy: 1.5, "20 under the summary")
    XCTAssertEqual(ladder.maxY, groups.maxY, accuracy: 1, "the ladder starts with the groups")
    XCTAssertEqual(ladder.height, groups.height, accuracy: 1.5, "and is as tall as they are")

    let cards = DebtsFigmaBoard.board.groups.flatMap(\.cards)
    let frames = try cards.map {
      try frame(of: DebtsBoardCard.identifier(of: $0.selection), in: window)
    }
    for card in frames {
      XCTAssertEqual(card.width, column, accuracy: 1.5, "a card: \(card)")
    }
    // Anna's card and the laptop's share the second row, 16 apart.
    let anna = frames[2]
    let laptop = frames[3]
    XCTAssertEqual(anna.maxY, laptop.maxY, accuracy: 1)
    XCTAssertEqual(abs(laptop.minX - anna.maxX), 16, accuracy: 1)
    XCTAssertEqual(anna.minX, groups.minX, accuracy: 1)
    // The two cards of «Я должен · 2» side by side, 20 above the row of Anna.
    XCTAssertEqual(frames[0].maxY, frames[1].maxY, accuracy: 1)
    XCTAssertEqual(abs(frames[1].minX - frames[0].maxX), 16, accuracy: 1)
  }

  /// The phone's frame 68:18363 drawn at its width of 440: one column, the cards across it.
  func testThePhoneWidthIsOneColumn() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = show(width: 440, height: 1_600)
    try attachPicture(of: window, named: "Долги 440 (Figma 68:18363)")
    let summary = try frame(of: "debts.summary", in: window)
    XCTAssertEqual(summary.minX, 16, accuracy: 1)
    XCTAssertEqual(summary.width, 408, accuracy: 1.5)
    let cards = DebtsFigmaBoard.board.groups.flatMap(\.cards)
    var previous: CGRect?
    for card in cards {
      let frame = try frame(of: DebtsBoardCard.identifier(of: card.selection), in: window)
      XCTAssertEqual(frame.width, 408, accuracy: 1.5, "a card across the page: \(frame)")
      if let previous { XCTAssertLessThan(frame.maxY, previous.minY, "one under the other") }
      previous = frame
    }
    let ladder = try frame(of: "debts.ladder.card", in: window)
    XCTAssertEqual(ladder.width, 408, accuracy: 1.5)
  }

  /// «Закрытые» stays folded until its name is pressed: closed debts pile up over the years, and
  /// the board shows them only when asked.
  func testTheClosedDebtsAreFoldedUntilAsked() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    var board = DebtsFigmaBoard.board
    let old = DebtsBoard.card(
      of: DebtsFigmaBoard.line(
        Debt(direction: .iOwe, type: .loan, name: "Старый", closed: true), borrowed: 100,
        balance: 0, next: DateOnly(year: 2026, month: 1, day: 1)))
    board.groups.append(DebtsBoard.Group(kind: .closed, cards: [old]))
    let window = show(width: 1_152 + 2 * StyleMetrics.pageSide, height: 1_100, board: board)
    let id = DebtsBoardCard.identifier(of: old.selection)
    let toggle = try XCTUnwrap(lookUp("debts.closed.toggle", in: window), "the name of «Закрытые»")
    XCTAssertNil(lookUp(id, in: window), "the closed debt is folded away")
    XCTAssertTrue(toggle.accessibilityPerformPress?() ?? false, "the name folds and unfolds")
    _ = try frame(of: id, in: window)
    XCTAssertEqual(old.labelKey, "debts.badge.closed")
  }
}
