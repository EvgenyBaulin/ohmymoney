import AppCore
import SwiftUI

/// The screen «Итоги»: a kind (week, month, year), a period of it, and the cards of that period
/// in a ribbon. Under the cards: the question of the week for a finished week, and the PDF and
/// the picture to share.
struct SummariesScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var model = SummariesModel(store: nil)
  @State private var kind: SummaryKind
  @State private var selected: SummaryID?
  @State private var content: SummaryContent?
  @State private var calculating = true
  @State private var pdfDocument = SummaryPDFDocument(data: Data())
  @State private var exporting = false
  @State private var askingAboutAmounts = false
  @State private var shareURL: URL?

  /// - Parameter initial: the summary to open; the latest finished month when `nil`.
  init(initial: SummaryID? = nil) {
    _kind = State(initialValue: initial?.kind ?? .month)
    _selected = State(initialValue: initial)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  private var snapshot: DataSnapshot? { compute.snapshot }

  private var archive: [SummaryID] {
    guard let snapshot else { return [] }
    var ids = SummaryScheduler.archive(
      kind: kind, today: snapshot.today, firstDay: snapshot.ledger.firstDay)
    if let selected, selected.kind == kind, !ids.contains(selected) { ids.insert(selected, at: 0) }
    return ids
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 12) {
          ribbon
        }
        .padding(16)
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 640)
    #endif
    .task {
      model = SummariesModel(environment: environment)
      await model.load()
    }
    .task(id: LoadKey(id: selected, generation: compute.generation, answers: model.moods.count)) {
      await reload()
    }
    .onChange(of: kind) { _, new in
      if selected?.kind != new { selected = archive.first }
    }
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
      isPresented: $exporting, document: pdfDocument, contentType: .pdf,
      defaultFilename: fileName
    ) { _ in }
  }

  // MARK: Pieces

  private var header: some View {
    VStack(spacing: 10) {
      HStack {
        Text(verbatim: t("summaries.title"))
          .appFont(.title2.bold())
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(t("summaries.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      Picker("", selection: $kind) {
        ForEach(SummaryKind.allCases, id: \.self) { kind in
          Text(verbatim: t("summaries.kind.\(kind.rawValue)")).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      if !archive.isEmpty {
        Picker("", selection: $selected) {
          ForEach(archive) { id in
            Text(verbatim: label(of: id)).tag(Optional(id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
  }

  @ViewBuilder private var ribbon: some View {
    if archive.isEmpty {
      Text(verbatim: t("summaries.empty"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if calculating {
      Text(verbatim: t("summaries.calculating"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    } else if let content, content.hasData, let snapshot {
      let text = SummaryText(
        environment: environment, names: SummaryNames(dataset: snapshot.dataset))
      SummaryRibbon(
        cards: content.cards(hideAmounts: environment.amounts.hidesAmounts), text: text)
      question(for: content, today: snapshot.today)
      actions
    } else {
      Text(verbatim: t("summaries.noData"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// A finished week asks how it went, one tap; an answer already given is marked and can be
  /// changed.
  @ViewBuilder private func question(for content: SummaryContent, today: DateOnly) -> some View {
    if case .week(let cards) = content, cards.week.end < today {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: t("summaries.question.title"))
          .appFont(.headline)
        WeekMoodRow(language: environment.language, chosen: cards.mood?.mood) { mood in
          Task {
            await model.answer(week: cards.week, mood: mood, at: environment.now())
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentCard()
    }
  }

  private var actions: some View {
    HStack {
      Button(t("summaries.pdf")) {
        if environment.amounts.hidesAmounts {
          askingAboutAmounts = true
        } else {
          preparePDF(withAmounts: true)
        }
      }
      .accessibilityIdentifier("summaries.pdf")
      if let shareURL {
        ShareLink(item: shareURL) { Text(verbatim: t("summaries.share")) }
          .accessibilityIdentifier("summaries.share")
      }
      Spacer()
    }
  }

  // MARK: Work

  private struct LoadKey: Hashable {
    var id: SummaryID?
    var generation: Int
    var answers: Int
  }

  private func label(of id: SummaryID) -> String {
    switch id.kind {
    case .week: id.range.map { environment.dates.span($0) } ?? id.key
    case .month: id.monthKey.map { environment.dates.monthTitle($0) } ?? id.key
    case .year: id.key
    }
  }

  private var fileName: String {
    let base = selected.map { SummariesPresentation.fileStem($0) } ?? "summary"
    return environment.format("summaries.pdf.fileName", table: "Summaries", base)
  }

  private func reload() async {
    guard let snapshot else { return }
    if selected == nil || selected?.kind != kind { selected = archive.first }
    guard let id = selected else {
      content = nil
      calculating = false
      return
    }
    calculating = content == nil
    let ledger = snapshot.ledger
    let today = snapshot.today
    let moods = model.moods
    let made = await Task.detached(priority: .userInitiated) {
      SummaryContent.make(id, ledger: ledger, today: today, moods: moods)
    }.value
    content = made
    calculating = false
    shareURL = nil
    if let made, made.hasData, id.kind != .week {
      shareURL = SummaryExport.pngFile(
        of: page(for: made, withAmounts: !environment.amounts.hidesAmounts),
        name: "OhMyMoney-\(SummariesPresentation.fileStem(id))")
    }
  }

  /// The page of the PDF and of the picture. With amounts the money is written in full even
  /// when the interface hides it; without, no line carries an amount at all.
  private func page(for content: SummaryContent, withAmounts: Bool) -> SummaryPage {
    guard let snapshot else { return SummaryPage(title: "", cards: []) }
    let money =
      withAmounts
      ? MoneyFormatter(
        locale: environment.language.locale, hidesAmounts: false,
        currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
      : environment.money
    let text = SummaryText(
      environment: environment, names: SummaryNames(dataset: snapshot.dataset), money: money)
    let cards = content.cards(hideAmounts: !withAmounts)
    let title = selected.map(label(of:)) ?? t("summaries.title")
    return SummaryPage(
      title: "\(t("summaries.title")) · \(title)",
      cards: cards.map { (title: text.title($0), lines: text.lines($0)) })
  }

  private func preparePDF(withAmounts: Bool) {
    guard let content,
      let data = SummaryExport.pdf(of: page(for: content, withAmounts: withAmounts))
    else { return }
    pdfDocument = SummaryPDFDocument(data: data)
    exporting = true
  }
}

enum SummariesPresentation {
  /// `2026-09`, `2025`, `2026-W43`: the id as part of a file name.
  static func fileStem(_ id: SummaryID) -> String { id.key }
}
