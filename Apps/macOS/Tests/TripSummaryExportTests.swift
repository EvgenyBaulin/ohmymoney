import AppCore
import CoreCSV
import XCTest

@testable import OhMyMoney

/// «Итог поездки» as CSV: the same family as the Reports files, one file for each section, the
/// shares of a file adding up to exactly one, and the files written whole into a folder.
@MainActor
final class TripSummaryExportTests: XCTestCase {
  private let anna = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
  private let food = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
  private let hotel = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  private var trip: Event {
    Event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Турция, лето",
      kind: .trip, startDate: day("2026-10-05"), endDate: day("2026-10-15"),
      tripCurrency: CurrencyCode("TRY"))
  }

  private func spending(
    _ iso: String, rubles: String, own: String? = nil, currency: CurrencyCode = .rub,
    category: UUID, debtor: UUID? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
    let rub = try! AmountE4(decimal: Decimal(string: rubles)!)
    let amount = own.map { try! AmountE4(decimal: Decimal(string: $0)!) } ?? rub
    return TransactionEntry(
      transaction: CoreKit.Transaction(
        id: id, kind: .expense, occurredAt: when, currency: currency, amountE4: amount,
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category, amountE4: amount, amountRubE4: rub,
          reimbursable: debtor != nil, debtorPersonId: debtor,
          reimbursementStatus: debtor == nil ? nil : .expected, eventId: trip.id)
      ])
  }

  private func summary() -> TripSummary {
    let dataset = Dataset(
      entries: [
        spending("2026-10-06", rubles: "3000", category: food),
        spending(
          "2026-10-06", rubles: "5000", own: "2000", currency: CurrencyCode("TRY"), category: hotel),
        spending("2026-10-07", rubles: "2000", category: food),
        spending("2026-10-07", rubles: "2000", category: food, debtor: anna),
      ], events: [trip])
    return TripSummary(
      event: trip, ledger: Ledger(dataset: dataset, calendar: .utc), budgetRub: nil)
  }

  private func files() -> [TripSummaryCSV.File] {
    TripSummaryCSV.files(
      for: summary(), tripName: trip.name,
      category: { $0 == self.food ? "Еда" : $0 == self.hotel ? "Жильё" : "Без категории" },
      person: { _ in "Аня" })
  }

  private func lines(_ file: TripSummaryCSV.File) -> [String] {
    String(decoding: file.data, as: UTF8.self).split(separator: "\n").map(String.init)
  }

  func testOneFileForEachSectionNamedAfterTheTrip() {
    XCTAssertEqual(
      files().map(\.name),
      [
        "trip-Турция-лето-by-day.csv", "trip-Турция-лето-by-category.csv",
        "trip-Турция-лето-by-currency.csv", "trip-Турция-лето-settlement.csv",
      ])
  }

  func testTheFilesOfTheTableFamilyStartWithTheColumnsOfTheReports() {
    let all = files()
    for file in all.prefix(3) {
      XCTAssertEqual(
        lines(file)[0].split(separator: ",").prefix(5).map(String.init),
        ["row_type", "name", "amount_rub", "amount_rub_exact", "share"])
    }
    XCTAssertEqual(
      lines(all[2])[0], "row_type,name,amount_rub,amount_rub_exact,share,amount,amount_exact")
    XCTAssertEqual(lines(all[3])[0], "row_type,name,amount_rub,amount_rub_exact,parts")
  }

  func testByDayHasADayAndItsMoneyAndATotalThatIsTheTotalOfTheTrip() {
    XCTAssertEqual(
      lines(files()[0]),
      [
        "row_type,name,amount_rub,amount_rub_exact,share",
        "item,2026-10-06,8000,8000.0000,0.8000",
        "item,2026-10-07,2000,2000.0000,0.2000",
        "total,Total,10000,10000.0000,1.0000",
      ])
  }

  func testByCategoryNamesTheCategoriesAndTheSharesAddUpToOne() {
    XCTAssertEqual(
      lines(files()[1]),
      [
        "row_type,name,amount_rub,amount_rub_exact,share",
        "item,Еда,5000,5000.0000,0.5000",
        "item,Жильё,5000,5000.0000,0.5000",
        "total,Total,10000,10000.0000,1.0000",
      ])
  }

  func testByCurrencyKeepsTheOwnCurrencyBesideTheRubles() {
    XCTAssertEqual(
      lines(files()[2]),
      [
        "row_type,name,amount_rub,amount_rub_exact,share,amount,amount_exact",
        "item,RUB,5000,5000.0000,0.5000,5000,5000.0000",
        "item,TRY,5000,5000.0000,0.5000,2000,2000.0000",
        "total,Total,10000,10000.0000,1.0000,,",
      ])
  }

  func testTheSettlementNamesWhoOwesHowMuchAndOfHowManyParts() {
    XCTAssertEqual(
      lines(files()[3]),
      [
        "row_type,name,amount_rub,amount_rub_exact,parts",
        "item,Аня,2000,2000.0000,1",
        "total,Total,2000,2000.0000,1",
      ])
  }

  func testATripNobodyPaidForHasAnEmptySettlementWithAZeroTotal() {
    let dataset = Dataset(
      entries: [spending("2026-10-06", rubles: "100", category: food)], events: [trip])
    let summary = TripSummary(
      event: trip, ledger: Ledger(dataset: dataset, calendar: .utc), budgetRub: nil)
    let all = TripSummaryCSV.files(
      for: summary, tripName: "x", category: { _ in "Еда" }, person: { _ in "" })
    XCTAssertEqual(
      lines(all[3]), ["row_type,name,amount_rub,amount_rub_exact,parts", "total,Total,0,0.0000,0"])
  }

  func testTheCsvReadsBackWithTheCsvReaderOfTheApp() throws {
    for file in files() {
      let rows = try CSVReader.rows(from: file.data)
      XCTAssertGreaterThanOrEqual(rows.count, 2, file.name)
    }
  }

  func testTheNameOfTheFileKeepsLettersAndDigitsAndNothingElse() {
    XCTAssertEqual(TripSummaryCSV.slug("  Турция / лето 2026!! "), "Турция-лето-2026")
    XCTAssertEqual(TripSummaryCSV.slug("///"), "trip")
    XCTAssertEqual(TripSummaryCSV.slug("Бали"), "Бали")
  }

  func testTheFilesAreWrittenWholeIntoAFolderAndAnExistingOneIsCounted() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("trip-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let all = files()
    XCTAssertEqual(TripSummaryExport.replacing(all, in: folder), 0)
    XCTAssertEqual(TripSummaryExport.write(all, to: folder), .written(files: 4))
    XCTAssertEqual(TripSummaryExport.replacing(all, in: folder), 4)
    let back = try Data(contentsOf: folder.appendingPathComponent(all[0].name))
    XCTAssertEqual(back, all[0].data)
  }

  func testAFolderThatCannotBeWrittenIntoFailsInsteadOfPretending() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/folder")
    XCTAssertEqual(TripSummaryExport.write(files(), to: missing), .failed)
  }
}
