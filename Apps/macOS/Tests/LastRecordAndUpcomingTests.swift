import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Two lines of Overview in words, in both languages: «Последняя запись» — when the owner last
/// wrote something down — and the grey «≈ N» under a payment of «Платежи на 7 дней» in another
/// currency than the default one.
@MainActor
final class LastRecordAndUpcomingTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)

  /// 14:35 of a day, in the calendar the app shows times in.
  private func at(_ day: DateOnly, _ environment: AppEnvironment) -> Date {
    environment.calendar.moment(day, hour: 14, minute: 35)
  }

  func testTheLastRecordLineInBothLanguages() {
    let environment = AppEnvironment()
    let now = environment.calendar.moment(today, hour: 18, minute: 0)
    environment.now = { now }
    let yesterday = DateOnly(year: 2026, month: 9, day: 26)
    let earlier = DateOnly(year: 2026, month: 9, day: 25)
    let lastYear = DateOnly(year: 2025, month: 9, day: 25)

    environment.language.choice = .russian
    XCTAssertEqual(
      OverviewText.lastRecord(at(today, environment), environment),
      "Последняя запись: сегодня, 14:35")
    XCTAssertEqual(
      OverviewText.lastRecord(at(yesterday, environment), environment),
      "Последняя запись: вчера, 14:35")
    let russianEarlier = OverviewText.lastRecord(at(earlier, environment), environment)
    XCTAssertTrue(russianEarlier.hasPrefix("Последняя запись: 25 сент"), russianEarlier)
    XCTAssertTrue(russianEarlier.hasSuffix("14:35"), russianEarlier)
    XCTAssertFalse(russianEarlier.contains("2026"), russianEarlier)
    let russianLastYear = OverviewText.lastRecord(at(lastYear, environment), environment)
    XCTAssertTrue(russianLastYear.hasPrefix("Последняя запись: 25 сентября 2025"), russianLastYear)
    XCTAssertTrue(russianLastYear.hasSuffix(", 14:35"), russianLastYear)

    environment.language.choice = .english
    XCTAssertEqual(
      OverviewText.lastRecord(at(today, environment), environment),
      "Last entry: today, 14:35")
    XCTAssertEqual(
      OverviewText.lastRecord(at(yesterday, environment), environment),
      "Last entry: yesterday, 14:35")
    let englishEarlier = OverviewText.lastRecord(at(earlier, environment), environment)
    XCTAssertTrue(englishEarlier.hasPrefix("Last entry: Sep 25"), englishEarlier)
    XCTAssertTrue(englishEarlier.hasSuffix("14:35"), englishEarlier)
    XCTAssertFalse(englishEarlier.contains("2026"), englishEarlier)
    let englishLastYear = OverviewText.lastRecord(at(lastYear, environment), environment)
    XCTAssertTrue(englishLastYear.hasPrefix("Last entry: September 25, 2025"), englishLastYear)
    XCTAssertTrue(englishLastYear.hasSuffix(", 14:35"), englishLastYear)
  }

  /// The line reads the moment from the data: the latest write, lines of the books left out.
  func testTheLineFollowsTheLatestWrite() {
    let environment = AppEnvironment()
    let now = environment.calendar.moment(today, hour: 18, minute: 0)
    environment.now = { now }
    environment.language.choice = .english
    let id = UUID()
    let written = at(today, environment)
    let coffee = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense,
        occurredAt: environment.calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 12)),
        amountE4: AmountE4(whole: 250), createdAt: written, updatedAt: now),
      parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 250))])
    let moment = OverviewSummary.lastRecordedAt(Dataset(entries: [coffee]))
    XCTAssertEqual(moment, written)
    XCTAssertEqual(
      moment.map { OverviewText.lastRecord($0, environment) }, "Last entry: today, 14:35")
    XCTAssertNil(OverviewSummary.lastRecordedAt(Dataset()), "nothing written, no line")
  }

  /// Laid out with the app's dependencies, the line takes room once something is written and
  /// none while the book is empty — and it finds every dependency it reads.
  func testTheLineIsDrawnOnlyOnceSomethingIsWritten() throws {
    let missingBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    defer { AppDependencies.missingReaders = missingBefore }
    let environment = AppEnvironment()
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    func height(of dataset: Dataset) -> CGFloat {
      compute.applyLight(
        DataSnapshot.build(
          dataset: dataset, calendar: .system, today: environment.today,
          context: SnapshotContext(), version: DataVersion(load: 0)))
      let host = NSHostingView(rootView: LastRecordLine().appDependencies(deps))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }
    let id = UUID()
    let coffee = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 250)),
      parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 250))])

    XCTAssertEqual(height(of: Dataset()), 0, "nothing written, nothing drawn")
    XCTAssertGreaterThan(height(of: Dataset(entries: [coffee])), 0)
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// 1 $ = 90 ₽, 1 ₸ = 0.2 ₽, no rate for the euro — the rates handed straight to the rule.
  func testTheUpcomingRowShowsTheApproximateAmount() {
    let environment = AppEnvironment()
    let kzt = CurrencyCode("KZT")
    let rates: [CurrencyCode: Decimal] = [.usd: 90, kzt: Decimal(string: "0.2") ?? 0]
    func payment(_ amount: AmountE4, _ currency: CurrencyCode) -> UpcomingPayment {
      UpcomingPayment(
        kind: .scheduled, id: UUID(), name: "iCloud", due: today, currency: currency,
        amount: amount, isOverdue: false)
    }
    let iCloud = payment(AmountE4(raw: 29_900), .usd)
    let domain = payment(AmountE4(whole: 20), .eur)
    let internet = payment(AmountE4(whole: 1_000), .rub)
    func line(_ payment: UpcomingPayment, to target: CurrencyCode = .rub) -> String? {
      UpcomingPaymentsCard.approximateText(
        payment.approximate(to: target, rubPerUnit: rates), environment)
    }

    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      XCTAssertEqual(line(iCloud), "≈\u{00A0}269\u{00A0}₽", "\(choice)")
      XCTAssertNil(line(internet), "the default currency needs no second line")
      // The default currency tenge: 2.99 × 90 ÷ 0.2 = 1,345.5 → 1,346 ₸.
      XCTAssertEqual(line(iCloud, to: kzt), "≈\u{00A0}1,346\u{00A0}₸", "\(choice)")
      XCTAssertEqual(line(internet, to: kzt), "≈\u{00A0}5,000\u{00A0}₸", "\(choice)")
    }
    environment.language.choice = .russian
    XCTAssertEqual(line(domain), "нет курса")
    XCTAssertEqual(
      environment.language("overview.upcoming.approxHelp", table: "Planning"),
      "Примерно в валюте по умолчанию, по сегодняшнему курсу ЦБ")
    environment.language.choice = .english
    XCTAssertEqual(line(domain), "no rate")
    XCTAssertEqual(
      environment.language("overview.upcoming.approxHelp", table: "Planning"),
      "About this much in the default currency, at today's CBR rate")
  }
}
