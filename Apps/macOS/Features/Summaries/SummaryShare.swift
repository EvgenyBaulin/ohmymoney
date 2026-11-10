import AppCore
import SwiftUI

/// The page of a summary for the PDF, the picture and the print: with amounts the money is
/// written in full even when the interface hides it; without, no line carries an amount at all.
enum SummaryShare {
  @MainActor
  static func page(
    for content: SummaryContent, id: SummaryID, snapshot: DataSnapshot,
    environment: AppEnvironment, withAmounts: Bool
  ) -> SummaryPage {
    let money =
      withAmounts
      ? MoneyFormatter(
        locale: environment.language.locale, hidesAmounts: false,
        currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
      : environment.money
    let text = SummaryText(
      environment: environment, names: SummaryNames(dataset: snapshot.dataset), money: money)
    let cards = content.cards(hideAmounts: !withAmounts)
    let title = environment.language("summaries.title", table: "Summaries")
    return SummaryPage(
      title: "\(title) · \(PeriodsBoardStore.label(of: id, environment))",
      cards: cards.map { (title: text.title($0), lines: text.lines($0)) })
  }

  /// «Итоги 2026-09.pdf».
  @MainActor
  static func fileName(_ id: SummaryID?, _ environment: AppEnvironment) -> String {
    environment.format("summaries.pdf.fileName", table: "Summaries", id?.key ?? "summary")
  }
}

/// «Поделиться…»: a quiet button of the header of «По периодам» on the Mac and a tablet, beside
/// «Выгрузить CSV…», the one orange button of Reports; the word in the accent on a phone. A menu of the PDF, the picture of a month or a year, and on the Mac
/// «Печать…» and, for a month, «Markdown…». With the amounts hidden the PDF and the print ask
/// whether to keep them.
struct SummaryShareMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let store: PeriodsBoardStore
  /// The phone's word in the accent instead of the orange button.
  var plain = false

  @State private var pdfDocument = SummaryPDFDocument(data: Data())
  @State private var exportingPDF = false
  @State private var askingAboutAmounts = false
  #if os(macOS)
    @State private var markdown = MarkdownDocument(text: "")
    @State private var exportingMarkdown = false
  #endif

  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  private var ready: Bool { store.content?.hasData == true && store.selected != nil }

  var body: some View {
    Menu {
      Button(t("summaries.pdf")) {
        if environment.amounts.hidesAmounts {
          askingAboutAmounts = true
        } else {
          preparePDF(withAmounts: true)
        }
      }
      .accessibilityIdentifier("summaries.pdf")
      if let url = store.shareURL {
        ShareLink(item: url) { Text(verbatim: t("summaries.board.picture")) }
          .accessibilityIdentifier("summaries.share")
      }
      #if os(macOS)
        Button(environment.language("mac.print.button", table: MacCommands.table)) { print() }
          .accessibilityIdentifier("summaries.print")
        if let month = store.selected?.monthKey {
          Button(environment.language("mac.markdown.button", table: MacCommands.table)) {
            prepareMarkdown(month)
          }
          .accessibilityIdentifier("summaries.markdown")
        }
      #endif
    } label: {
      Text(verbatim: t(plain ? "summaries.share" : "summaries.board.share"))
    }
    .modifier(ShareLook(plain: plain))
    .disabled(!ready)
    .help(t("summaries.board.share.help"))
    .accessibilityIdentifier("summaries.shareMenu")
    .confirmationDialog(
      t("summaries.pdf.ask"), isPresented: $askingAboutAmounts, titleVisibility: .visible
    ) {
      Button(t("summaries.pdf.with")) { preparePDF(withAmounts: true) }
      Button(t("summaries.pdf.without")) { preparePDF(withAmounts: false) }
      Button(t("summaries.pdf.cancel"), role: .cancel) {}
    } message: {
      Text(verbatim: t("summaries.pdf.askMessage"))
    }
    .fileExporter(
      isPresented: $exportingPDF, document: pdfDocument, contentType: .pdf,
      defaultFilename: SummaryShare.fileName(store.selected, environment)
    ) { _ in }
    #if os(macOS)
      .fileExporter(
        isPresented: $exportingMarkdown, document: markdown,
        contentType: MarkdownDocument.markdown,
        defaultFilename: store.selected?.monthKey.map(MonthMarkdownExport.fileName) ?? "summary"
      ) { _ in }
    #endif
  }

  private struct ShareLook: ViewModifier {
    @Environment(\.appTheme) private var theme
    let plain: Bool

    func body(content: Content) -> some View {
      if plain {
        content
          .menuStyle(.button)
          .buttonStyle(.plain)
          .appFont(AppFont.system(size: 15, weight: .medium))
          .foregroundStyle(theme.accentDefault)
          .fixedSize()
      } else {
        content
          .menuStyle(.button)
          .buttonStyle(.quietAction)
          .menuIndicator(.hidden)
          .fixedSize()
      }
    }
  }

  private func page(withAmounts: Bool) -> SummaryPage? {
    guard let content = store.content, let id = store.selected, let snapshot = compute.snapshot
    else { return nil }
    return SummaryShare.page(
      for: content, id: id, snapshot: snapshot, environment: environment,
      withAmounts: withAmounts)
  }

  private func preparePDF(withAmounts: Bool) {
    guard let page = page(withAmounts: withAmounts), let data = SummaryExport.pdf(of: page)
    else { return }
    pdfDocument = SummaryPDFDocument(data: data)
    exportingPDF = true
  }

  #if os(macOS)
    /// «Печать…»: the page of the PDF on paper, after «Печатать с суммами?» when the amounts are
    /// hidden.
    private func print() {
      var withAmounts = true
      if PrintAmounts.asks(hidesAmounts: environment.amounts.isHidingNow) {
        switch PrintFlow.askAboutAmounts(environment) {
        case .with: withAmounts = true
        case .without: withAmounts = false
        case .cancel: return
        }
      }
      guard let page = page(withAmounts: withAmounts) else { return }
      MacPrint.run(page, width: SummaryPage.width, jobTitle: page.title)
    }

    /// «Markdown…» of a month: the summary as a Markdown file in a folder the owner chooses,
    /// without amounts when they are hidden.
    private func prepareMarkdown(_ month: MonthKey) {
      guard let dependencies,
        let text = MonthMarkdownExport.text(
          month: month, dependencies: dependencies,
          hidesAmounts: environment.amounts.isHidingNow)
      else { return }
      markdown = MarkdownDocument(text: text)
      exportingMarkdown = true
      AppLog.info("summaries.markdown", .ui, "a month was exported as Markdown")
    }
  #endif
}
