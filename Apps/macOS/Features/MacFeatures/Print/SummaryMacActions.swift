import AppCore
import SwiftUI

/// The buttons of the Mac under a summary in «Итоги»: «Печать…» — the page of the PDF on paper,
/// after «Печатать с суммами?» when the amounts are hidden — and, for a month, «Markdown…» — the
/// summary as a Markdown file in a folder the owner chooses, without amounts when they are hidden.
struct SummaryMacActions: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let id: SummaryID?
  let hasData: Bool
  /// The page of the summary, with or without its amounts.
  let page: (_ withAmounts: Bool) -> SummaryPage

  @State private var markdown = MarkdownDocument(text: "")
  @State private var exporting = false

  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  var body: some View {
    Button(t("mac.print.button")) { print() }
      .disabled(!hasData)
      .accessibilityIdentifier("summaries.print")
    if let month = id?.monthKey {
      Button(t("mac.markdown.button")) { prepareMarkdown(month) }
        .disabled(!hasData)
        .accessibilityIdentifier("summaries.markdown")
        .fileExporter(
          isPresented: $exporting, document: markdown, contentType: MarkdownDocument.markdown,
          defaultFilename: MonthMarkdownExport.fileName(month)
        ) { _ in }
    }
  }

  private func print() {
    var withAmounts = true
    if PrintAmounts.asks(hidesAmounts: environment.amounts.isHidingNow) {
      switch PrintFlow.askAboutAmounts(environment) {
      case .with: withAmounts = true
      case .without: withAmounts = false
      case .cancel: return
      }
    }
    let page = page(withAmounts)
    MacPrint.run(page, width: SummaryPage.width, jobTitle: page.title)
  }

  private func prepareMarkdown(_ month: MonthKey) {
    guard let dependencies,
      let text = MonthMarkdownExport.text(
        month: month, dependencies: dependencies, hidesAmounts: environment.amounts.isHidingNow)
    else { return }
    markdown = MarkdownDocument(text: text)
    exporting = true
    AppLog.info("summaries.markdown", .ui, "a month was exported as Markdown")
  }
}
