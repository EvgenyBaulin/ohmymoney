import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A custom currency and its rates typed by hand are written as changes of the planning: a new
/// currency with its first rate, an edit, the archive, a rate of a day and its removal, a
/// deletion with all its rates — each one write and one step of ⌘Z that gives the database back
/// as it found it.
@Suite("Custom currencies and their rates")
struct CurrencyRepositoryTests {
  let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4)
  let september10 = DateOnly(year: 2026, month: 9, day: 10)
  let september20 = DateOnly(year: 2026, month: 9, day: 20)

  struct Fixture {
    let stack: DatabaseStack
    let currencies: CurrencyRepository
    let planning: PlanningRepository

    init() throws {
      stack = try TestSupport.makeStack()
      currencies = CurrencyRepository(writer: stack.writer)
      planning = PlanningRepository(writer: stack.writer)
    }

    func tables() throws -> [String: ExactTable] {
      try stack.writer.read { db in try ExactTables.read(db) }
    }

    /// Applies the change, checks ⌘Z gives the tables back, and applies it again.
    @discardableResult
    func applyUndoable(_ change: PlanningChange) throws -> PlanningUndo {
      let before = try tables()
      let undo = try planning.apply(change)
      _ = try planning.revert(undo)
      #expect(try tables() == before)
      return try planning.apply(change)
    }
  }

  @Test func aNewCurrencyWithItsFirstRateIsOneStep() throws {
    let f = try Fixture()
    let change = try f.currencies.saving(tether, firstRate: (september10, 95.5))
    try f.applyUndoable(change)
    #expect(try f.currencies.customCurrencies() == [tether])
    let rates = try f.currencies.rates(of: tether.code)
    #expect(rates.map(\.perUnit) == [95.5])
    #expect(rates.first?.source == .manual)
    #expect(try f.currencies.catalog().symbol(tether.code) == "₮")
  }

  @Test func theRateOfADayIsTheLastTypedNotAfterItAndNoneBeforeTheFirst() throws {
    let f = try Fixture()
    try f.applyUndoable(try f.currencies.saving(tether, firstRate: (september10, 95)))
    try f.applyUndoable(try f.currencies.savingRate(tether.code, on: september20, rubPerUnit: 97))
    #expect(try f.currencies.rate(of: tether.code, on: september10)?.perUnit == 95)
    #expect(
      try f.currencies.rate(of: tether.code, on: DateOnly(year: 2026, month: 9, day: 15))?
        .perUnit == 95)
    #expect(try f.currencies.rate(of: tether.code, on: september20)?.perUnit == 97)
    #expect(
      try f.currencies.rate(of: tether.code, on: DateOnly(year: 2026, month: 9, day: 1)) == nil)
    // The rate cache reads it the same way, never asking the bank.
    let table = try RateRepository(writer: f.stack.writer).table()
    #expect(table.resolve(tether.code, on: september20)?.rate.perUnit == 97)
    #expect(!table.needsFetch(currency: tether.code, on: september20))
  }

  @Test func aRetypedDayReplacesItsRateAndUndoGivesTheOldOneBack() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether, firstRate: (september10, 95)))
    let undo = try f.applyUndoable(
      try f.currencies.savingRate(tether.code, on: september10, rubPerUnit: 99))
    #expect(try f.currencies.rates(of: tether.code).map(\.perUnit) == [99])
    #expect(undo.before.rates.map(\.perUnit) == [95])
    _ = try f.planning.revert(undo)
    #expect(try f.currencies.rates(of: tether.code).map(\.perUnit) == [95])
  }

  @Test func aRateCanBeTakenAway() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether, firstRate: (september10, 95)))
    _ = try f.planning.apply(
      try f.currencies.savingRate(tether.code, on: september20, rubPerUnit: 97))
    try f.applyUndoable(try f.currencies.removingRate(tether.code, on: september20))
    #expect(try f.currencies.rate(of: tether.code, on: september20)?.perUnit == 95)
  }

  @Test func anEditKeepsTheCodeAndTheOrder() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether))
    let points = CustomCurrency(code: CurrencyCode("PTS"), name: "баллы", fractionDigits: 0)
    _ = try f.planning.apply(try f.currencies.saving(points))
    #expect(try f.currencies.customCurrencies().map(\.sort) == [0, 1])
    var renamed = tether
    renamed.name = " USDT "
    renamed.symbol = " "
    try f.applyUndoable(try f.currencies.saving(renamed))
    let stored = try #require(try f.currencies.customCurrencies().first)
    #expect(stored.name == "USDT")
    #expect(stored.symbol == nil)
    #expect(stored.sort == 0)
    try f.applyUndoable(try f.currencies.reordering([points.code]))
    #expect(try f.currencies.customCurrencies().map(\.code) == [points.code, tether.code])
  }

  @Test func whatCannotBeACustomCurrencyIsRefusedBeforeAnythingIsWritten() throws {
    let f = try Fixture()
    let iso = CustomCurrency(code: .usd, name: "Dollar")
    #expect(throws: CustomCurrencyWriteError.refused(.isoCode)) {
      try f.currencies.saving(iso)
    }
    var dollar = tether
    dollar.symbol = "$"
    #expect(throws: CustomCurrencyWriteError.refused(.symbolOfBankCurrency)) {
      try f.currencies.saving(dollar)
    }
    #expect(throws: CustomCurrencyWriteError.rateNotPositive) {
      try f.currencies.saving(tether, firstRate: (september10, 0))
    }
    #expect(throws: CustomCurrencyWriteError.notCustom(.usd)) {
      try f.currencies.savingRate(.usd, on: september10, rubPerUnit: 90)
    }
    #expect(throws: CustomCurrencyWriteError.notThere(tether.code)) {
      try f.currencies.savingRate(tether.code, on: september10, rubPerUnit: 90)
    }
    #expect(try f.currencies.customCurrencies().isEmpty)
  }

  @Test func theArchiveKeepsItAndTheDefaultCurrencyStays() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether))
    try f.applyUndoable(try f.currencies.archiving(tether.code))
    #expect(try f.currencies.catalog().active.isEmpty)
    #expect(try f.currencies.catalog().isCustom(tether.code))
    try f.applyUndoable(try f.currencies.archiving(tether.code, archived: false))
    #expect(try f.currencies.catalog().active == [tether])
    try SettingsRepository(writer: f.stack.writer).setDefaultCurrency(tether.code)
    #expect(throws: CustomCurrencyWriteError.isDefault(tether.code)) {
      try f.currencies.archiving(tether.code)
    }
  }

  @Test func onlyACurrencyNothingNamesIsDeletedAndItsRatesGoWithIt() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether, firstRate: (september10, 95)))
    _ = try f.planning.apply(
      try f.currencies.savingRate(tether.code, on: september20, rubPerUnit: 97))
    #expect(try !f.currencies.isUsed(tether.code))
    try f.applyUndoable(try f.currencies.deleting(tether.code))
    #expect(try f.currencies.customCurrencies().isEmpty)
    #expect(try f.currencies.rates(of: tether.code).isEmpty)

    _ = try f.planning.apply(try f.currencies.saving(tether, firstRate: (september10, 95)))
    let goal = Goal(name: "Крипта", targetE4: AmountE4(whole: 1_000), currency: tether.code)
    _ = try f.planning.apply(PlanningChange(upsert: PlanningRows(goals: [goal])))
    #expect(try f.currencies.isUsed(tether.code))
    #expect(throws: CustomCurrencyWriteError.inUse(tether.code)) {
      try f.currencies.deleting(tether.code)
    }
  }

  @Test func anAccountHoldingItAmongOthersIsAUse() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether))
    var account = PaymentMethod(name: "Биржа", kind: .card)
    account.otherCurrencies = [tether.code]
    _ = try f.planning.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [account])))
    #expect(try f.currencies.isUsed(tether.code))
    #expect(try !f.currencies.isUsed(CurrencyCode("PTS")))
  }

  @Test func theExportWritesTheCustomCurrencies() throws {
    let f = try Fixture()
    _ = try f.planning.apply(try f.currencies.saving(tether, firstRate: (september10, 95)))
    let table = try #require(
      try ExportRepository(writer: f.stack.writer).tables().first {
        $0.fileName == "custom_currencies.csv"
      })
    let rows = try CSVReader.dictionaries(from: table.data)
    #expect(rows.count == 1)
    #expect(rows.first?["code"] == "UST")
    #expect(rows.first?["symbol"] == "₮")
    #expect(rows.first?["fraction_digits"] == "4")
    #expect(rows.first?["archived"] == "false")
    let rates = try #require(
      try ExportRepository(writer: f.stack.writer).tables().first { $0.fileName == "rates.csv" })
    let rateRows = try CSVReader.dictionaries(from: rates.data)
    #expect(rateRows.contains { $0["currency"] == "UST" && $0["source"] == "manual" })
  }
}
