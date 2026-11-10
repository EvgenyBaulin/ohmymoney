import AppCore
import SwiftUI

// «Итоги» as the frames of «По периодам» draw them: a week, a month or a year in coloured cards.
// The numbers are the core's `PeriodBoard`, built off the main thread; this file holds the
// numbers of the layout, the words, and the store the tab and the page of a phone share.

/// The numbers of the frames: Mac 34:17697 and 68:18433, tablet 572:224407, phone 68:18578 and
/// 264:91420.
struct PeriodsBoardMetrics: Equatable, Sendable {
  /// Between the cards of a row and of a column.
  var cardGap: CGFloat
  /// Inside the coloured card, between its lines, its radius.
  var heroPadding: CGFloat
  var heroGap: CGFloat
  var heroRadius: CGFloat
  /// Between the three figures at the foot of the coloured card.
  var heroFigureGap: CGFloat
  /// Inside a white card and its radius.
  var cardPadding: CGFloat
  var cardRadius: CGFloat
  /// «Главные категории»: its margin and the room under its title.
  var topPadding: CGFloat
  var topGap: CGFloat
  /// The track of a grade.
  var gradeTrack: CGFloat
  /// The plot of the columns, its width (`nil` — the card's), and the type of its labels.
  var plotHeight: CGFloat
  var plotWidth: CGFloat?
  var axisSize: CGFloat
  /// The figures at the foot of the coloured card.
  var heroValueSize: CGFloat
  /// One column of cards (a phone), or two side by side.
  var twoColumns: Bool

  static let mac = PeriodsBoardMetrics(
    cardGap: 16, heroPadding: 20, heroGap: 8, heroRadius: StyleMetrics.cardRadius,
    heroFigureGap: 12, cardPadding: 16, cardRadius: StyleMetrics.cardRadius, topPadding: 16,
    topGap: 10, gradeTrack: 200, plotHeight: 160, plotWidth: 468, axisSize: 11, heroValueSize: 13,
    twoColumns: true)

  static let pad = PeriodsBoardMetrics(
    cardGap: 16, heroPadding: 20, heroGap: 8, heroRadius: touchRadius, heroFigureGap: 12,
    cardPadding: 16, cardRadius: touchRadius, topPadding: 16, topGap: 10, gradeTrack: 200,
    plotHeight: 160, plotWidth: 468, axisSize: 11, heroValueSize: 13, twoColumns: true)

  static let phone = PeriodsBoardMetrics(
    cardGap: 12, heroPadding: 16, heroGap: 7, heroRadius: touchRadius, heroFigureGap: 10,
    cardPadding: 16, cardRadius: touchRadius, topPadding: 14, topGap: 8, gradeTrack: 140,
    plotHeight: 128.5, plotWidth: nil, axisSize: 9, heroValueSize: 12, twoColumns: false)

  /// The cards of a phone and a tablet.
  static let touchRadius: CGFloat = 22

  static func of(_ idiom: LayoutIdiom) -> PeriodsBoardMetrics {
    switch idiom {
    case .mac: .mac
    case .pad: .pad
    case .phone: .phone
    }
  }

  /// The left column of two: half of what the gap leaves on the Mac (568 of 1152), 411 of 1060
  /// on the tablet, as their frames draw it.
  static func leftColumn(_ idiom: LayoutIdiom, width: CGFloat) -> CGFloat {
    switch idiom {
    case .pad: (width * 411 / 1060).rounded()
    case .mac, .phone: ((width - PeriodsBoardMetrics.of(idiom).cardGap) / 2).rounded(.down)
    }
  }

  /// The narrowest a column of two is drawn: the ring and its legend side by side. A window
  /// narrower than two of them stacks the cards in one column.
  static let narrowestColumn: CGFloat = 367

  static func fitsTwoColumns(_ idiom: LayoutIdiom, width: CGFloat) -> Bool {
    let metrics = of(idiom)
    guard metrics.twoColumns else { return false }
    let left = leftColumn(idiom, width: width)
    return left >= narrowestColumn && width - left - metrics.cardGap >= narrowestColumn
  }

  /// The ring and its legend: the side, the room to the legend and between its lines, the word.
  static let donut: CGFloat = 160
  static let donutToLegend: CGFloat = 24
  static let legendGap: CGFloat = 8
  static let legendDot: CGFloat = 10
  static let legendName: CGFloat = 90
  /// A row of grades: the symbol, its word, the room between them.
  static let gradeSymbol: CGFloat = 20
  static let gradeWord: CGFloat = 70
  static let gradeGap: CGFloat = 12
  static let gradeHeight: CGFloat = 10
  /// The bar of the coloured card.
  static let heroBar: CGFloat = 8
  /// The columns card is at least this tall on the Mac and the tablet, beside the two cards at
  /// its right.
  static let columnsCardHeight: CGFloat = 302
  /// The chip of a category: 18 tall, radius 5, 6 to its name; two rows of two, 16 apart.
  static let chipHeight: CGFloat = 18
  static let chipRadius: CGFloat = 5
  static let chipPadding: CGFloat = 4
  static let chipGap: CGFloat = 6
  static let topColumnsGap: CGFloat = 16
  /// The segment of a phone: a capsule 34 tall over the width.
  static let phoneSegmentHeight: CGFloat = 34
  /// The legend under the columns: 16 between the two, 4 between a sample and its words.
  static let legendItemGap: CGFloat = 16
  static let legendWordGap: CGFloat = 4
  static let axisGap: CGFloat = 12
  /// The empty board: as tall as its frame (62:37169).
  static let emptyHeight: CGFloat = 290
}

/// The type of the frames: the titles of the white cards 11 bold, «Главные категории» 14
/// semibold; the coloured card 14 semibold, 12, the figure 34 semibold, the figures at its foot 11
/// and 13 semibold (12 on a phone); a line of a legend 11, its percent 13 medium.
enum PeriodsBoardType {
  static let cardTitle = AppFont.system(size: 11, weight: .bold)
  static let topTitle = AppFont.system(size: 14, weight: .semibold)
  static let heroTitle = AppFont.system(size: 14, weight: .semibold)
  static let heroLine = AppFont.system(size: 12)
  static let heroFigure = AppFont.system(size: 34, weight: .semibold).monospacedDigit()
  static let heroLabel = AppFont.system(size: 11)
  static func heroValue(_ metrics: PeriodsBoardMetrics) -> AppFont {
    AppFont.system(size: metrics.heroValueSize, weight: .semibold).monospacedDigit()
  }
  static let legendName = AppFont.system(size: 11)
  static let figure = AppFont.system(size: 13, weight: .medium).monospacedDigit()
  static let chipLetter = AppFont.system(size: 10, weight: .bold)
  static let chipName = AppFont.system(size: 12.5, weight: .medium)
  static let donutFigure = AppFont.system(size: 13)
  static let donutCaption = AppFont.system(size: 9)
  static let segmentPhone = AppFont.system(size: 13, weight: .medium)
  static let emptyTitle = AppFont.system(size: 13, weight: .semibold)
  static let emptyText = AppFont.system(size: 11)
}

/// The words of the board, in the language of the window.
@MainActor
struct PeriodsBoardText {
  let environment: AppEnvironment
  let names: SummaryNames

  func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  private func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), locale: environment.language.locale, arguments: arguments)
  }

  private var money: MoneyFormatter { environment.money }

  /// «Неделя в цифрах», «Октябрь в цифрах», «2026 в цифрах».
  func title(_ id: SummaryID) -> String {
    switch id.kind {
    case .week: t("summaries.card.weekTotal")
    case .month:
      f("summaries.board.title", environment.dates.monthName(id.monthKey?.month ?? 1))
    case .year: f("summaries.board.title", id.key)
    }
  }

  func spentCaption(_ kind: SummaryKind) -> String { t("summaries.board.spent.\(kind.rawValue)") }

  /// «как на прошлой неделе», «−3 % к 2025», «+6 % к сентябрю»; «не с чем сравнить» with no base.
  func change(_ board: PeriodBoard) -> String {
    guard let percent = board.changePercent else { return t("summaries.board.noBase") }
    guard percent != 0 else { return t("summaries.board.same.\(board.id.kind.rawValue)") }
    let signed = money.signedPercent(basisPoints: percent * 100, fractionDigits: 0)
    switch board.id.kind {
    case .week: return f("summaries.board.change.week", signed)
    case .month:
      let before = (board.id.monthKey ?? MonthKey(year: 2026, month: 1)).previous.month
      return f("summaries.board.change.to", signed, t("summaries.month.to.\(before)"))
    case .year:
      return f("summaries.board.change.to", signed, String((board.id.yearNumber ?? 1) - 1))
    }
  }

  /// The arrow before a change; none when it is the same or has no base.
  func changeSymbol(_ board: PeriodBoard) -> String? {
    guard let percent = board.changePercent, percent != 0 else { return nil }
    return percent > 0 ? "arrow.up.right" : "arrow.down.right"
  }

  func rubles(_ amount: AmountE4) -> String { money.rounded(amount) }

  func percent(_ basisPoints: Int?) -> String {
    money.percent(basisPoints: basisPoints ?? 0, fractionDigits: 0)
  }

  /// «13 600 ₽ · 42 %».
  func saved(_ board: PeriodBoard) -> String {
    guard let kept = board.savedBP else { return rubles(board.saved) }
    return "\(rubles(board.saved)) · \(percent(kept))"
  }

  /// «Дорогой день» or «Лучший месяц».
  func highlightLabel(_ board: PeriodBoard) -> String {
    if case .bestMonth = board.highlight { return t("summaries.card.best") }
    return t("summaries.board.dearestDay")
  }

  /// «Пятница» for a week, «15 октября» for a month or a year, «Март» for the best month; «—»
  /// for a period without spending.
  func highlight(_ board: PeriodBoard) -> String {
    switch board.highlight {
    case .dearestDay(let day):
      board.id.kind == .week
        ? Self.upperFirst(environment.dates.weekday(day.weekday))
        : environment.dates.dayAndMonth(day)
    case .bestMonth(let month): environment.dates.monthName(month.month)
    case nil: "—"
    }
  }

  func category(_ id: UUID?) -> String {
    guard let id else { return t("summaries.board.other") }
    return names.categories[id] ?? t("summaries.unknown")
  }

  func columnsTitle(_ kind: SummaryKind) -> String {
    t(kind == .week ? "summaries.board.columns.weeks" : "summaries.board.columns.months")
  }

  /// «15 сен» under a week, «Июн» under a month.
  func axis(_ column: PeriodBoard.Column) -> String {
    if let month = column.month {
      // Three letters, as the frames write them: «Июн», «Сен», «Ноя».
      return String(environment.dates.monthName(month.month).prefix(3))
    }
    return environment.dates.dayAndShortMonth(column.range.start)
  }

  func spoken(_ column: PeriodBoard.Column) -> String {
    column.month.map(environment.dates.monthTitle) ?? environment.dates.span(column.range)
  }

  /// «пятница» → «Пятница»: the system writes names of days small.
  static func upperFirst(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  func gradeName(_ quality: Quality) -> String { t("summaries.board.grade.\(quality.rawValue)") }

  /// «7 900 ₽ · 43 %».
  func grade(_ grade: PeriodBoard.Grade) -> String {
    "\(rubles(grade.amount)) · \(percent(grade.shareBP))"
  }
}

/// The colours of the ring and of the chips, by place: the first category purple, the second
/// green, the third orange, the fourth blue, the rest grey — as the frames paint them.
enum PeriodsBoardTint {
  static func slice(_ index: Int, isRest: Bool, _ theme: AppThemeColors) -> Color {
    if isRest { return theme.chart5 }
    switch index {
    case 0: return theme.chart7
    case 1: return theme.chart2
    case 2: return theme.chart4
    default: return theme.chart3
    }
  }
}

/// What the tab and the page hold: the kind and the period chosen, the board of that period and
/// the summary of it for «Поделиться…». One per screen; built off the main thread.
@MainActor
@Observable
final class PeriodsBoardStore {
  var kind: SummaryKind = .week
  var selected: SummaryID?
  private(set) var board: PeriodBoard?
  private(set) var content: SummaryContent?
  private(set) var calculating = true
  /// The picture of a month or a year to share, made once the period is shown.
  private(set) var shareURL: URL?
  let model: SummariesModel

  init(model: SummariesModel = SummariesModel(store: nil)) {
    self.model = model
  }

  /// The finished periods of the kind, the latest first, with the one asked for even when it
  /// is not finished.
  func archive(_ snapshot: DataSnapshot?) -> [SummaryID] {
    guard let snapshot else { return [] }
    var ids = SummaryScheduler.archive(
      kind: kind, today: snapshot.today, firstDay: snapshot.ledger.firstDay)
    if let selected, selected.kind == kind, !ids.contains(selected) { ids.insert(selected, at: 0) }
    return ids
  }

  /// Goes to a summary asked for from elsewhere.
  func show(_ id: SummaryID) {
    kind = id.kind
    selected = id
  }

  /// Builds the board and the cards of the chosen period.
  func reload(_ snapshot: DataSnapshot?, environment: AppEnvironment) async {
    guard let snapshot else { return }
    if selected == nil || selected?.kind != kind { selected = archive(snapshot).first }
    guard let id = selected else {
      board = nil
      content = nil
      calculating = false
      return
    }
    calculating = board?.id != id
    let ledger = snapshot.ledger
    let today = snapshot.today
    let moods = model.moods
    let made = await Task.detached(priority: .userInitiated) {
      (
        PeriodBoard.build(id, ledger: ledger, today: today),
        SummaryContent.make(id, ledger: ledger, today: today, moods: moods)
      )
    }.value
    guard selected == id else { return }
    board = made.0
    content = made.1
    calculating = false
    shareURL = nil
    if let content = made.1, content.hasData, id.kind != .week {
      shareURL = SummaryExport.pngFile(
        of: SummaryShare.page(
          for: content, id: id, snapshot: snapshot, environment: environment,
          withAmounts: !environment.amounts.hidesAmounts),
        name: "OhMyMoney-\(id.key)")
    }
  }

  /// «13–19 окт.», «Октябрь 2026», «2026»: a period in the chooser.
  static func label(of id: SummaryID, _ environment: AppEnvironment) -> String {
    switch id.kind {
    case .week: id.range.map { environment.dates.span($0) } ?? id.key
    case .month: id.monthKey.map { environment.dates.monthTitle($0) } ?? id.key
    case .year: id.key
    }
  }
}
