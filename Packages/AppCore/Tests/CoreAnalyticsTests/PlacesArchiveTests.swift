import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A place in the archive is gone from entry and pickers only: its operations keep it, and
/// Analytics «Места» and Reports grouped by place show it with unchanged figures.
@Suite("An archived place stays in analytics")
struct PlacesArchiveTests {
  private static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  private static let coffee = id(1)
  private static let cafe = id(2)
  private static let september = MonthKey(year: 2026, month: 9)

  /// «Кофемания», archived, and one purchase «кофе 450» there on 12.09.
  private func ledger(archived: Bool) -> Ledger {
    let calendar = CalendarContext.utc
    let when = calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 12))
      .addingTimeInterval(9 * 3600)
    let amount = AmountE4(whole: 450)
    let transactionId = Self.id(100)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense, occurredAt: when, amountE4: amount,
        amountRubE4: amount, note: "кофе", placeId: Self.coffee, createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          id: Self.id(101), transactionId: transactionId, categoryId: Self.cafe,
          quality: .neutral, qualitySource: .category, amountE4: amount, amountRubE4: amount)
      ])
    return Ledger(
      dataset: Dataset(
        entries: [entry],
        categories: [
          CoreKit.Category(id: Self.cafe, kind: .expense, name: "Кафе", quality: .neutral)
        ],
        places: [Place(id: Self.coffee, name: "Кофемания", archived: archived)]),
      calendar: calendar)
  }

  /// Analytics «Места», September: «Кофемания» with 450 of my spending, one purchase, an
  /// average receipt of 450 — the same figures as before it went to the archive.
  @Test func anArchivedPlaceStaysInPlaces() throws {
    let period = Period.month(Self.september)
    let report = PlacesReport(ledger: ledger(archived: true), period: period)
    let place = try #require(report.places.first)
    #expect(report.places.count == 1)
    #expect(place.placeId == Self.coffee)
    #expect(place.mySpending == AmountE4(whole: 450))
    #expect(place.purchases == 1)
    #expect(place.averageReceipt == AmountE4(whole: 450))
    #expect(report == PlacesReport(ledger: ledger(archived: false), period: period))
  }

  /// Reports, spending grouped by place: «Кофемания» 450, the archive changes nothing.
  @Test func reportsGroupedByPlaceKeepAnArchivedPlace() throws {
    let period = Period.month(Self.september)
    let today = DateOnly(year: 2026, month: 9, day: 27)
    for kind in [ReportTable.Kind.expensesByCategory, .expensesByCategoryAndSubcategory] {
      let archived = ReportBuilder(ledger: ledger(archived: true), today: today)
        .table(kind, period: period, grouping: .place)
      let line = try #require(archived.rows.first)
      #expect(line.key == .place(Self.coffee))
      #expect(line.amount == AmountE4(whole: 450))
      let live = ReportBuilder(ledger: ledger(archived: false), today: today)
        .table(kind, period: period, grouping: .place)
      #expect(archived == live)
    }
  }
}
