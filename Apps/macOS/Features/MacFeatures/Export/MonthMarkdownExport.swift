import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// The summary of a month as a Markdown file (`MonthMarkdown`), in the interface language: by
/// the button «Markdown…» of a month in «Итоги», and by the command of «Быстрые команды» — which
/// is how the owner puts it on a schedule.
///
/// With «Скрыть суммы» on, the file carries no amount: the figures the screen hides are not
/// handed to a file either.
@MainActor
enum MonthMarkdownExport {
  /// The text of `month`, or `nil` while there is nothing to read it from.
  static func text(month: MonthKey, dependencies: AppDependencies, hidesAmounts: Bool) -> String? {
    let environment = dependencies.environment
    guard let snapshot = dependencies.compute.snapshot,
      let summary = SummaryBuilder.summary(
        id: .month(month), ledger: snapshot.ledger, today: snapshot.today)
    else { return nil }
    return MonthMarkdown.text(
      of: summary, title: environment.dates.monthTitle(month),
      words: words(environment, names: SummaryNames(dataset: snapshot.dataset)),
      hidesAmounts: hidesAmounts)
  }

  /// The words of the file. Amounts are written in full — the file is asked for with them —
  /// by a formatter that does not mask; without them `MonthMarkdown` writes none at all.
  static func words(_ environment: AppEnvironment, names: SummaryNames) -> MonthMarkdown.Words {
    let money = MoneyFormatter(
      locale: environment.language.locale, hidesAmounts: false,
      currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
    var texts: [MonthMarkdown.Key: String] = [:]
    for key in MonthMarkdown.Key.allCases {
      texts[key] = environment.language(key.rawValue, table: MacCommands.table)
    }
    let table = texts
    let categories = names.categories
    let places = names.places
    return MonthMarkdown.Words(
      text: { table[$0] ?? $0.rawValue },
      money: { money.rounded($0) },
      percent: { money.percent(basisPoints: $0) },
      signedPercent: { money.signedPercent(basisPoints: $0) },
      categoryName: { categories[$0] },
      placeName: { places[$0] })
  }

  /// `OhMyMoney 2026-10.md`.
  static func fileName(_ month: MonthKey) -> String { "OhMyMoney \(month.iso).md" }
}

/// The Markdown text as a document `fileExporter` can save.
struct MarkdownDocument: FileDocument {
  static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
  static var readableContentTypes: [UTType] { [markdown, .plainText] }
  var text: String

  init(text: String) { self.text = text }

  init(configuration: ReadConfiguration) throws {
    text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
