import AppCore
import SwiftUI

/// «Упущенный кэшбэк»: what the purchases of the last three months would have earned more with
/// the best of the owner's cards, month by month and the largest misses first. Hidden accounts
/// are neither compared nor are their purchases listed while they are covered.
struct MissedCashbackSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var report: MissedCashbackModel?

  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("cashback.missed.title")).appFont(.headline)
      if let report {
        if report.rows.isEmpty {
          Text(verbatim: t("cashback.missed.none")).foregroundStyle(.secondary)
            .accessibilityIdentifier("cashback.missed.none")
        } else {
          Text(
            verbatim: environment.format(
              "cashback.missed.total", table: "SyncHistory",
              environment.money.rounded(report.totalRub, currency: .rub))
          )
          .monospacedDigit()
          List {
            Section {
              ForEach(report.months, id: \.month) { month in
                HStack {
                  Text(verbatim: environment.dates.monthTitle(month.month))
                  Spacer()
                  Text(verbatim: environment.money.rounded(month.missedRub, currency: .rub))
                    .monospacedDigit()
                }
              }
            } header: {
              Text(verbatim: t("cashback.missed.byMonth"))
            }
            Section {
              ForEach(report.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                  HStack {
                    Text(verbatim: row.subject)
                    Spacer()
                    Text(verbatim: "+" + environment.money.exact(row.missedRub))
                      .monospacedDigit()
                  }
                  Text(
                    verbatim: environment.format(
                      "cashback.missed.line", table: "SyncHistory",
                      environment.dates.dayAndMonth(row.day), row.betterCard,
                      environment.money.exact(row.bestRub), environment.money.exact(row.actualRub))
                  )
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
                }
              }
            } header: {
              Text(verbatim: t("cashback.missed.largest"))
            }
          }
        }
      } else {
        ProgressView()
      }
      Text(verbatim: t("cashback.missed.hint")).appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 560, height: 560)
    .task(id: compute.generation) {
      guard let ledger = compute.snapshot?.ledger else { return }
      let today = environment.today
      let hidden = environment.shield.covering.ids
      report = await Task.detached(priority: .userInitiated) {
        MissedCashbackModel.build(ledger: ledger, today: today, hidden: hidden)
      }.value
    }
  }
}

/// The figures of the sheet, built off the main thread from the ledger.
struct MissedCashbackModel: Equatable, Sendable {
  struct Row: Identifiable, Equatable, Sendable {
    var id: UUID
    var day: DateOnly
    /// The place, else the category, else «покупка».
    var subject: String
    var betterCard: String
    var actualRub: AmountE4
    var bestRub: AmountE4
    var missedRub: AmountE4 { bestRub - actualRub }
  }

  struct Month: Equatable, Sendable {
    var month: MonthKey
    var missedRub: AmountE4
  }

  /// How many of the largest misses the sheet lists.
  static let shownRows = 30

  var totalRub: AmountE4
  var months: [Month]
  var rows: [Row]

  /// The three months up to `today`, the current one included.
  static func build(ledger: Ledger, today: DateOnly, hidden: Set<UUID>) -> MissedCashbackModel {
    let start = today.monthKey.adding(months: -2).firstDay
    let missed = MissedCashback(
      ledger: ledger, period: .days(DayRange(start, today)), hidden: hidden)
    let dataset = ledger.dataset
    let places = Dictionary(
      dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let categories = Dictionary(
      dataset.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let holders = Dictionary(
      (dataset.paymentMethods.map { ($0.id, $0.name) } + dataset.cards.map { ($0.id, $0.name) }),
      uniquingKeysWith: { first, _ in first })
    let rows = missed.items.prefix(shownRows).map { item -> Row in
      let holderId: UUID
      switch item.best.holder {
      case .card(let id), .account(let id): holderId = id
      }
      return Row(
        id: item.transactionId, day: item.day,
        subject: item.placeId.flatMap { places[$0] } ?? item.categoryId.flatMap { categories[$0] }
          ?? "—",
        betterCard: holders[holderId] ?? "—", actualRub: item.actualRub, bestRub: item.bestRub)
    }
    return MissedCashbackModel(
      totalRub: missed.totalRub,
      months: missed.byMonth.map { Month(month: $0.month, missedRub: $0.missedRub) }, rows: rows)
  }
}
