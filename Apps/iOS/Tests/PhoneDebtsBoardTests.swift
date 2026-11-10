import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Долги» on the phone and the tablet as their frames draw it: one column on the phone (68:18363,
/// 440 wide), three on the tablet (572:224041, the content 1116 wide beside its sidebar), the
/// cards rounded to 22 — and a picture of each kept with the result, to lay beside the frame.
@MainActor
final class PhoneDebtsBoardTests: XCTestCase {
  private let anna = Person(name: "Анна")

  private func line(_ debt: Debt, borrowed: Int64, balance: Int64, day: Int) -> DebtLine {
    DebtLine(
      debt: debt, balance: AmountE4(whole: balance), balanceRub: nil, groups: [],
      nextPayment: DateOnly(year: 2026, month: 11, day: day), paidThisMonth: false,
      entries: [DebtEntry(debtId: debt.id, amountE4: AmountE4(whole: borrowed), kind: .borrowed)])
  }

  /// The debts of the frames: two loans and an instalment plan I owe, and Anna who owes me.
  private var board: DebtsBoard {
    let credit = Debt(
      direction: .iOwe, type: .loan, name: "Кредит · Т-Банк", interestRate: 14,
      monthlyPaymentE4: AmountE4(whole: 18_400), origin: .purchase)
    let mortgage = Debt(
      direction: .iOwe, type: .loan, name: "Ипотека · Сбербанк", interestRate: 10,
      monthlyPaymentE4: AmountE4(whole: 16_402))
    let laptop = Debt(
      direction: .iOwe, type: .installment, name: "Рассрочка · Ноутбук", interestRate: 0,
      monthlyPaymentE4: AmountE4(whole: 3_300), origin: .purchase, parts: 6)
    let lent = Debt(
      direction: .owedToMe, type: .personal, name: "Анне", personId: anna.id, interestRate: 0,
      monthlyPaymentE4: AmountE4(whole: 2_000))
    let overview = DebtsOverview(
      iOwe: [
        line(laptop, borrowed: 19_800, balance: 13_200, day: 15),
        line(mortgage, borrowed: 1_400_000, balance: 1_120_000, day: 20),
        line(credit, borrowed: 230_000, balance: 142_600, day: 28),
      ],
      owedToMe: [
        OwedToMeGroup(
          personId: anna.id, debts: [line(lent, borrowed: 16_000, balance: 12_000, day: 5)],
          parts: [], totalRub: AmountE4(whole: 12_000), oldest: nil)
      ],
      closed: [], totalIOweRub: AmountE4(whole: 1_275_800),
      totalOwedToMeRub: AmountE4(whole: 12_000), monthlyPaymentsRub: AmountE4(whole: 38_102),
      withoutRate: [])
    return DebtsBoard(overview: overview, people: [anna])
  }

  private func ladder(_ board: DebtsBoard) -> DebtsLadderCard? {
    let debts = board.groups.filter { $0.kind == .iOwe || $0.kind == .instalments }
      .flatMap(\.cards)
    return DebtsLadderCard(
      candidates: debts.map { card in
        LadderDebt(
          id: card.debtId ?? UUID(), source: .debt(card.debtId ?? UUID()), name: card.name,
          balanceRub: card.amount, ratePercent: card.rate ?? 0,
          minimumRub: card.payment ?? .zero)
      }, extra: AmountE4(whole: 20_000), method: .avalanche, start: MonthKey(year: 2026, month: 11))
  }

  /// Draws the board `width` wide and keeps a picture of it; returns the height it takes.
  private func draw(width: CGFloat, named name: String) throws -> CGFloat {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let board = board
    let view = DebtsBoardView(
      board: board, ladder: ladder(board), cardDebts: [], withoutRate: 0, reviewCount: 0,
      select: { _ in }, delete: { _ in }, create: {}, review: {}
    )
    .appDependencies(
      AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system)))
    let controller = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_400))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    for _ in 0..<20 {
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let png = try XCTUnwrap(image.pngData())
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let fitting = controller.sizeThatFits(
      in: CGSize(width: width, height: .greatestFiniteMagnitude))
    window.isHidden = true
    return fitting.height
  }

  func testTheCardsOfTouchAreRoundedTo22() {
    XCTAssertEqual(ContentCard.cornerRadius, 22)
    XCTAssertEqual(DebtsMetrics.phoneCardPadding, 14)
    XCTAssertEqual(DebtsMetrics.phoneCardGap, 8)
    XCTAssertEqual(DebtsMetrics.stepNumber, 22)
  }

  func testThePhoneHasOneColumnAndTheTabletThree() {
    XCTAssertLessThan(440, DebtsMetrics.phoneWidth, "the phone's 440 is the phone's page")
    XCTAssertGreaterThanOrEqual(1_116, DebtsMetrics.phoneWidth, "the tablet's page is wide")
    // On the tablet the groups take two of three columns of the 1060 between the margins.
    XCTAssertEqual(DebtsMetrics.column(in: 1_060), 342.667, accuracy: 0.01)
    XCTAssertEqual(board.rows(columns: 2).map(\.id), [[.iOwe], [.owedToMe, .instalments]])
  }

  func testThePhoneAndTheTabletDrawTheBoard() throws {
    let phone = try draw(width: 440, named: "Долги, iPhone 440 (Figma 68:18363)")
    let tablet = try draw(width: 1_116, named: "Долги, iPad 1116 (Figma 572:224041)")
    XCTAssertGreaterThan(phone, tablet, "one column is taller than three")
  }
}
