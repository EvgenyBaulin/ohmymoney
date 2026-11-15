import AppCore
import CoreGraphics
import SwiftUI

/// The words a printed report for another person needs, in the language of the interface, and
/// the formatters of its figures. Amounts are never masked here: «Скрыть суммы» hides the screen,
/// a file the owner chose to make says what it says.
struct SharedReportWords: Sendable {
  var title: String
  var prepared: String
  var accounts: String
  var spending: String
  var income: String
  var total: String
  var empty: String
  var columns: [SharedReport.Column: String]
  var kinds: [TransactionKind: String]
  var page: @Sendable (Int, Int) -> String
  var money: MoneyFormatter
  var dates: DateFormatting

  /// The words of the CSV: the same columns and kinds, so both files say one thing.
  var csv: SharedReport.Words {
    SharedReport.Words(columns: columns, kinds: kinds, total: total)
  }

  static let table = "Utilities"

  @MainActor
  static func make(_ environment: AppEnvironment, report: SharedReport) -> SharedReportWords {
    func t(_ key: String) -> String { environment.language(key, table: table) }
    let dates = environment.dates
    let money = MoneyFormatter(
      locale: environment.language.locale, hidesAmounts: false,
      currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
    let accountNames = Set(
      report.lines.map(\.account)
    ).sorted()
    let pageFormat = t("sharedReport.pdf.page")
    var columns: [SharedReport.Column: String] = [:]
    for column in SharedReport.Column.allCases {
      columns[column] = t("sharedReport.column.\(column.rawValue)")
    }
    var kinds: [TransactionKind: String] = [:]
    for kind in TransactionKind.allCases {
      kinds[kind] = t("sharedReport.kind.\(kind.rawValue)")
    }
    return SharedReportWords(
      title: environment.format(
        "sharedReport.pdf.title", table: table, dates.span(report.request.range)),
      prepared: environment.format(
        "sharedReport.pdf.prepared", table: table, dates.longDay(report.preparedOn)),
      accounts: accountNames.isEmpty
        ? ""
        : environment.format(
          "sharedReport.pdf.accounts", table: table, accountNames.joined(separator: ", ")),
      spending: t("sharedReport.pdf.spending"), income: t("sharedReport.pdf.income"),
      total: t("sharedReport.pdf.total"), empty: t("sharedReport.pdf.empty"),
      columns: columns, kinds: kinds,
      page: { page, count in
        String(format: pageFormat, locale: Locale(identifier: "en_US_POSIX"), page, count)
      },
      money: money, dates: dates)
  }
}

/// A printed report for another person: A4 pages, the header and the totals on the first, the
/// lines after them, a page number at the foot of each. With a password the PDF is locked by the
/// format's own encryption, so any reader opens it with the password and none without.
enum SharedReportPDF {
  static let pageSize = CGSize(width: 595, height: 842)
  static let margin: CGFloat = 36
  static let rowHeight: CGFloat = 15
  /// What a full page of lines holds under the column titles, above the page number.
  static var linesPerPage: Int {
    Int((pageSize.height - 2 * margin - 3 * rowHeight) / rowHeight)
  }

  /// What the first page holds: the header, the totals and the column titles take their rows.
  static func firstPageLines(totals: Int) -> Int {
    max(0, linesPerPage - 6 - (totals + 2))
  }

  /// The page ranges of the lines of a report.
  static func pages(of report: SharedReport) -> [Range<Int>] {
    SharedReport.pages(
      lineCount: report.lines.count, firstPage: firstPageLines(totals: report.totals.count),
      perPage: linesPerPage)
  }

  /// The PDF of a report, or nil when the system could not draw it.
  @MainActor
  static func data(
    _ report: SharedReport, words: SharedReportWords, password: String? = nil
  ) -> Data? {
    let ranges = pages(of: report)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(origin: .zero, size: pageSize)
    var info: [CFString: Any] = [
      kCGPDFContextCreator: "OhMyMoney", kCGPDFContextTitle: words.title,
    ]
    if let password, !password.isEmpty {
      info[kCGPDFContextUserPassword] = password
      info[kCGPDFContextOwnerPassword] = password
      info[kCGPDFContextEncryptionKeyLength] = 128
    }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
    else { return nil }
    for (index, range) in ranges.enumerated() {
      let page = SharedReportPage(
        report: report, words: words, lines: range, number: index + 1, count: ranges.count)
      let renderer = ImageRenderer(content: page)
      renderer.proposedSize = ProposedViewSize(pageSize)
      context.beginPDFPage(nil)
      renderer.render { _, draw in draw(context) }
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
}

/// One page of a printed report. The sizes are those of a paper page, not of the screen.
struct SharedReportPage: View {
  let report: SharedReport
  let words: SharedReportWords
  let lines: Range<Int>
  let number: Int
  let count: Int

  private var showsDetail: Bool { report.request.showsNotes || report.request.showsPlaces }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if number == 1 { header }
      columnTitles
      ForEach(Array(report.lines[lines].enumerated()), id: \.offset) { _, line in
        row(line)
      }
      if report.lines.isEmpty {
        Text(verbatim: words.empty)
          .font(.system(size: 10))  // font-fixed: a paper page has its own sizes
          .foregroundStyle(Color.gray)
          .frame(height: SharedReportPDF.rowHeight * 2)
      }
      Spacer(minLength: 0)
      HStack {
        Text(verbatim: words.prepared)
        Spacer()
        Text(verbatim: words.page(number, count))
      }
      .font(.system(size: 8))  // font-fixed: a paper page has its own sizes
      .foregroundStyle(Color.gray)
    }
    .padding(SharedReportPDF.margin)
    .frame(width: SharedReportPDF.pageSize.width, height: SharedReportPDF.pageSize.height)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .environment(\.colorScheme, .light)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: words.title)
        .font(.system(size: 18, weight: .bold))  // font-fixed: a paper page has its own sizes
      Text(verbatim: words.prepared)
        .font(.system(size: 10))  // font-fixed: a paper page has its own sizes
        .foregroundStyle(Color.gray)
      if !words.accounts.isEmpty {
        Text(verbatim: words.accounts)
          .font(.system(size: 10))  // font-fixed: a paper page has its own sizes
          .lineLimit(1)
      }
      VStack(alignment: .leading, spacing: 0) {
        totalRow(words.spending, report.spendingRub, bold: true)
        totalRow(words.income, report.incomeRub, bold: true)
        ForEach(Array(report.totals.enumerated()), id: \.offset) { _, total in
          totalRow(total.category, total.amountRub, bold: false)
        }
      }
      .padding(.top, 6)
    }
    .padding(.bottom, SharedReportPDF.rowHeight)
  }

  private func totalRow(_ name: String, _ amount: AmountE4, bold: Bool) -> some View {
    HStack {
      Text(verbatim: name).lineLimit(1)
      Spacer()
      Text(verbatim: words.money.exact(amount)).monospacedDigit()
    }
    .font(.system(size: 10, weight: bold ? .semibold : .regular))  // font-fixed: a paper page has its own sizes
    .frame(height: SharedReportPDF.rowHeight)
  }

  private var columnTitles: some View {
    HStack(spacing: 6) {
      cell(words.columns[.date] ?? "", width: 62)
      cell(words.columns[.category] ?? "", width: 130)
      cell(words.columns[.account] ?? "", width: 80)
      if showsDetail {
        cell(detailTitle, width: nil)
      } else {
        Spacer(minLength: 0)
      }
      Text(verbatim: words.columns[.amount] ?? "")
        .frame(width: 90, alignment: .trailing)
    }
    .font(.system(size: 9, weight: .semibold))  // font-fixed: a paper page has its own sizes
    .foregroundStyle(Color.gray)
    .frame(height: SharedReportPDF.rowHeight)
    .overlay(alignment: .bottom) { Rectangle().fill(.tertiary).frame(height: 0.5) }
  }

  private var detailTitle: String {
    [
      report.request.showsNotes ? words.columns[.note] : nil,
      report.request.showsPlaces ? words.columns[.place] : nil,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func row(_ line: SharedReport.Line) -> some View {
    HStack(spacing: 6) {
      cell(words.dates.dayMonth(line.day), width: 62)
      cell(line.category, width: 130)
      cell(line.account, width: 80)
      if showsDetail {
        cell([line.note, line.place].compactMap { $0 }.joined(separator: " · "), width: nil)
      } else {
        Spacer(minLength: 0)
      }
      Text(verbatim: signed(line.amount))
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: 90, alignment: .trailing)
    }
    .font(.system(size: 9))  // font-fixed: a paper page has its own sizes
    .frame(height: SharedReportPDF.rowHeight)
  }

  /// «−1,200 ₽» for spending, «+5,000 ₽» for money that came; the minus is U+2212.
  private func signed(_ money: Money) -> String {
    let text = words.money.exact(money.amount.magnitude, currency: money.currency)
    return (money.amount.isNegative ? "\u{2212}" : "+") + text
  }

  @ViewBuilder
  private func cell(_ text: String, width: CGFloat?) -> some View {
    if let width {
      Text(verbatim: text).lineLimit(1).truncationMode(.tail)
        .frame(width: width, alignment: .leading)
    } else {
      Text(verbatim: text).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
