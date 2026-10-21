import CoreAccounting
import CoreAnalytics
import CoreCSV
import CoreKit
import CoreModel
import CoreSample
import Foundation
import Testing

@testable import CoreInsights

/// The synthetic CSV export `make eval-model` is checked against, and the promise that it is
/// still what the generator produces.
///
/// It is committed rather than generated on the fly so that the tool has something to be run
/// against on a tree where nothing has been built — and it is checked against the generator
/// every run, so a change to the sample cannot quietly leave it stale. Regenerate with
/// `OHMYMONEY_WRITE_FIXTURES=1 make test-core`.
///
/// One test at a time: with `OHMYMONEY_WRITE_FIXTURES=1` one of them writes the files another reads.
@Suite("The synthetic export make eval-model is checked against", .serialized)
struct ExportFixtureTests {
  private static let endingOn = DateOnly(year: 2026, month: 9, day: 18)

  private var folder: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/export", isDirectory: true)
  }

  private func dataset() -> Dataset {
    let set = SampleDataGenerator(seed: 20_260_920).generate(
      months: 6, endingOn: Self.endingOn, calendar: .moscow, language: "en")
    return Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  }

  /// The three files the model reads, written with the very same rows the application's
  /// export writes (`ExportTables.row`), so the fixture is that export and not a lookalike.
  private func files(of dataset: Dataset) -> [String: Data] {
    var transactions = CSVWriter(columns: ExportTables.transactions.columns)
    var parts = CSVWriter(columns: ExportTables.transactionParts.columns)
    for entry in dataset.entries {
      transactions.append(ExportTables.row(entry.transaction))
      for part in entry.parts { parts.append(ExportTables.row(part)) }
    }
    var categories = CSVWriter(columns: ExportTables.categories.columns)
    for category in dataset.categories { categories.append(ExportTables.row(category)) }
    return [
      ExportTables.transactions.fileName: transactions.data(),
      ExportTables.transactionParts.fileName: parts.data(),
      ExportTables.categories.fileName: categories.data(),
    ]
  }

  @Test func theFixtureIsStillWhatTheGeneratorProduces() throws {
    let expected = files(of: dataset())
    if ProcessInfo.processInfo.environment["OHMYMONEY_WRITE_FIXTURES"] == "1" {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (name, data) in expected {
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
      }
      print("MEASURE fixture written to \(folder.path)")
      return
    }

    for (name, data) in expected {
      let url = folder.appendingPathComponent(name)
      guard let onDisk = try? Data(contentsOf: url) else {
        Issue.record("\(name) is missing: run OHMYMONEY_WRITE_FIXTURES=1 make test-core")
        return
      }
      #expect(
        onDisk == data,
        "\(name) no longer matches the generator: run OHMYMONEY_WRITE_FIXTURES=1 make test-core")
    }
  }

  /// The export read back asks the model the questions the application asks it
  /// (`LedgerTraining`), day and weekday included. The export writes every moment in UTC; the
  /// day is the owner's. A coffee at 00:30 in Moscow on Friday 18 September is 21:30 UTC on
  /// the 17th — and still Friday's coffee to the tool. And 119 886.59 is 119 887 whole rubles,
  /// rounded as the application rounds them, not cut to 119 886.
  @Test func theExportAsksTheQuestionsTheApplicationAsks() throws {
    var dataset = dataset()
    let category = try #require(
      dataset.entries.lazy.flatMap(\.parts).first { $0.categoryId != nil }?.categoryId)
    for (number, moment) in [1_789_680_600, 1_789_766_700, 1_789_724_400].enumerated() {
      let when = Date(timeIntervalSince1970: TimeInterval(moment))
      let id = UUID(uuidString: String(format: "0000AAAA-0000-0000-0000-%012d", number))!
      dataset.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: .expense, occurredAt: when, amountE4: AmountE4(whole: 250),
            amountRubE4: AmountE4(whole: 250), note: "late coffee", createdAt: when,
            updatedAt: when),
          parts: [
            TransactionPart(
              id: UUID(uuidString: String(format: "0000BBBB-0000-0000-0000-%012d", number))!,
              transactionId: id, categoryId: category, amountE4: AmountE4(whole: 250),
              amountRubE4: AmountE4(whole: 250))
          ]))
    }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (name, data) in files(of: dataset) {
      try data.write(to: folder.appendingPathComponent(name))
    }

    let read = try CSVExportReader(folder: folder, calendar: .moscow).examples()
    let taught = LedgerTraining.examples(of: dataset, calendar: .moscow)
    #expect(read.count == taught.count)
    let byPart = Dictionary(uniqueKeysWithValues: taught.map { ($0.partId, $0) })
    for example in read where byPart[example.partId] != example {
      Issue.record(
        "\(example.query.text) on \(example.query.day.iso): not the application's question")
    }
  }

  /// And the tool's own promise: the model beats both baselines on that export.
  @Test func theModelBeatsTheBaselinesOnTheFixture() throws {
    let reader = try CSVExportReader(folder: folder, calendar: .moscow)
    let examples = reader.examples()
    #expect(examples.count > 50, "the fixture teaches the model nothing")

    let metrics = PrequentialEvaluation.run(on: examples)
    #expect(metrics.asked > 0)
    #expect(
      metrics.top1Bp > metrics.baselineMostFrequentBp,
      "the model did no better than the commonest category")
  }
}
