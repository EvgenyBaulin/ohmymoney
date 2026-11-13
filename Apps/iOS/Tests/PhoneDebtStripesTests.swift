import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The stripes of the debt cards on the phone, at the two phone widths of the frames (402 and
/// 375): each mark's colour is on screen, as a bar of its own width inside the card's padding,
/// and drawing the stripes changes nothing of the layout.
@MainActor
final class PhoneDebtStripesTests: XCTestCase {
  private func line(_ name: String, stripe: DebtPaymentMark?, day: Int) -> DebtLine {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: name, interestRate: 12,
      monthlyPaymentE4: AmountE4(whole: 10_000))
    return DebtLine(
      debt: debt, balance: AmountE4(whole: 80_000), balanceRub: nil, groups: [],
      nextPayment: DateOnly(year: 2026, month: 11, day: day), paidThisMonth: false,
      entries: [
        DebtEntry(debtId: debt.id, amountE4: AmountE4(whole: 100_000), kind: .borrowed)
      ], stripe: stripe)
  }

  private func board(striped: Bool) -> DebtsBoard {
    let lines = [
      line("Кредит А", stripe: striped ? .overdue : nil, day: 12),
      line("Кредит Б", stripe: striped ? .extra : nil, day: 15),
      line("Кредит В", stripe: striped ? .regular : nil, day: 20),
    ]
    let overview = DebtsOverview(
      iOwe: lines, owedToMe: [], closed: [], totalIOweRub: AmountE4(whole: 240_000),
      totalOwedToMeRub: .zero, monthlyPaymentsRub: AmountE4(whole: 30_000), withoutRate: [])
    return DebtsBoard(overview: overview, people: [])
  }

  private struct Drawing {
    var image: UIImage
    var height: CGFloat
  }

  private func draw(_ board: DebtsBoard, width: CGFloat) throws -> Drawing {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let view = DebtsBoardView(
      board: board, ladder: nil, cardDebts: [], withoutRate: 0, reviewCount: 0,
      select: { _ in }, delete: { _ in }, create: {}, review: {}
    )
    .appDependencies(
      AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system)))
    let controller = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
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
    let height = controller.sizeThatFits(
      in: CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    window.isHidden = true
    return Drawing(image: image, height: height)
  }

  /// The columns, in points, that have a pixel within a few levels of `color`, and how many
  /// pixels do.
  private func columns(
    of color: ThemeColor, in image: UIImage
  ) throws -> (
    range: ClosedRange<CGFloat>?, count: Int
  ) {
    let cg = try XCTUnwrap(image.cgImage)
    let width = cg.width
    let height = cg.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let context = try XCTUnwrap(
      CGContext(
        data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: try XCTUnwrap(space),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    let scale = image.scale
    var low = Int.max
    var high = Int.min
    var count = 0
    for y in 0..<height {
      for x in 0..<width {
        let at = (y * width + x) * 4
        if abs(Int(data[at]) - Int(color.red)) <= 8, abs(Int(data[at + 1]) - Int(color.green)) <= 8,
          abs(Int(data[at + 2]) - Int(color.blue)) <= 8
        {
          low = min(low, x)
          high = max(high, x)
          count += 1
        }
      }
    }
    guard count > 0 else { return (nil, 0) }
    return (CGFloat(low) / scale...CGFloat(high + 1) / scale, count)
  }

  func testTheThreeStripesAreOnScreenAsBarsInsideTheCardPadding() throws {
    let palette = AppThemeColors.fallback.palette
    let colors = [
      palette.debtStripeOverdue, palette.debtStripeExtra, palette.debtStripeRegular,
    ]
    for width in [CGFloat(402), 375] {
      let drawing = try draw(board(striped: true), width: width)
      for color in colors {
        let found = try columns(of: color, in: drawing.image)
        let range = try XCTUnwrap(found.range, "a stripe is missing at \(width)")
        XCTAssertGreaterThan(found.count, 100, "the stripe is a bar, not a speck, at \(width)")
        XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound, 6, "a bar \(width)")
        // The bar lies inside the card, in the padding: right of the page margin, left of the
        // icon of the card.
        XCTAssertGreaterThanOrEqual(range.lowerBound, PhoneMetrics.screenMargin)
        XCTAssertLessThanOrEqual(
          range.upperBound, PhoneMetrics.screenMargin + DebtsMetrics.phoneCardPadding)
      }
    }
  }

  func testTheStripesAddNothingToTheHeightOfTheBoard() throws {
    for width in [CGFloat(402), 375] {
      let plain = try draw(board(striped: false), width: width).height
      let striped = try draw(board(striped: true), width: width).height
      XCTAssertEqual(striped, plain, accuracy: 0.5, "stripes move nothing at \(width)")
    }
  }

  func testEveryMarkHasItsOwnSymbolAndWords() {
    XCTAssertEqual(Set(DebtPaymentMark.allCases.map(\.symbol)).count, 3)
    let environment = AppEnvironment()
    environment.language.choice = .russian
    for mark in DebtPaymentMark.allCases {
      for key in [mark.paymentKey, mark.debtKey] {
        let words = environment.language(key, table: "Debts")
        XCTAssertNotEqual(words, key, "\(key) is not in the catalog")
      }
    }
    XCTAssertTrue(DebtPaymentMark.isShown)
  }
}
