import AppCore
import SwiftUI

/// «Прогноз остатка на 30 сентября» under the balances of an account: for each currency of the
/// account, about how much will be on it at the end of the month, the interval, and what the
/// figure is made of — the balance now, what is already written for later days, the expected
/// income, the interest a deposit is expected to pay (grey: an estimate, income only once
/// recorded), the payments and subscriptions, the debt payments, what counts keep finding missing,
/// what is paid for others less money back, and the day-to-day spending by the account's
/// share. Whole units everywhere: it is an estimate, and the exact balance is
/// the card above it.
///
/// The forecast step gives the day-to-day spending; everything else is the data of the moment
/// (`DataSnapshot.accountPlan`), so a write shows at once.
struct AccountForecastCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  let accountId: UUID

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    ComputedBlock(
      title: AccountForecastText.title(through: through, environment),
      state: state, emptyReason: t("account.forecast.notCounted"),
      retry: { compute.retry(ComputeStep.forecast) }
    ) { model in
      AccountForecastLines(model: model)
    }
    .accessibilityIdentifier("account.forecast")
  }

  /// The last day of the month the data was built for.
  private var through: DateOnly {
    compute.snapshot?.accountPlan.through ?? environment.today.monthKey.lastDay
  }

  /// The forecast step's state, its remainder laid over the plan of the current data. An
  /// account none of whose currencies was ever counted has nothing to forecast from.
  private var state: BlockState<AccountForecastModel> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      let model = AccountForecastModel(
        forecast: snapshot.accountPlan.forecast(remainder: remainder), accountId: accountId)
      return model.hasForecast ? .ready(model, at: at) : .notEnoughData
    }
  }
}

/// The lines of one account in a forecast, as the card shows them.
struct AccountForecastModel: Hashable, Sendable {
  var lines: [AccountForecast.Line]
  var lowData: Bool
  var through: DateOnly

  init(forecast: AccountForecast, accountId: UUID) {
    lines = forecast.lines(of: accountId)
    lowData = forecast.lowData
    through = forecast.through
  }

  /// Some currency of the account was counted: there is a figure or a reason to show.
  var hasForecast: Bool { lines.contains { $0.status != .notCounted } }
}

private struct AccountForecastLines: View {
  @Dependency(\.environment) private var environment
  let model: AccountForecastModel

  var body: some View {
    let pairs = AccountForecastText.pairs(model.lines, environment)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(pairs, id: \.id) { pair in
        PairView(pair: pair)
      }
      if model.lowData {
        NoteView(note: AccountForecastText.lowDataNote(environment))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private struct PairView: View {
    let pair: AccountForecastText.Pair

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        if let header = pair.header {
          Text(verbatim: header)
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        if let middle = pair.middle {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: middle)
              .appFont(.title3.monospacedDigit())
            if let range = pair.range {
              Text(verbatim: range)
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(verbatim: pair.spoken))
        }
        ForEach(pair.breakdown, id: \.label) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: row.label)
            Spacer(minLength: 8)
            Text(verbatim: row.value)
              .monospacedDigit()
          }
          .appFont(.callout)
          .foregroundStyle(row.isEstimate ? .secondary : .primary)
          .accessibilityElement(children: .combine)
        }
        ForEach(Array(pair.notes.enumerated()), id: \.offset) { _, note in
          NoteView(note: note)
        }
      }
    }
  }

  /// A remark with its symbol: never a colour alone.
  private struct NoteView: View {
    let note: AccountForecastText.Note

    var body: some View {
      Label {
        Text(verbatim: note.text)
      } icon: {
        Image(systemName: note.symbol)
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

/// The words of the forecast card, built without a view so they can be checked in both
/// languages.
@MainActor
enum AccountForecastText {
  /// One line of the breakdown: what it is and its signed amount.
  struct Row: Hashable, Sendable {
    var label: String
    var value: String
    /// Only expected, never money yet — the interest of a deposit: shown grey, with «≈».
    var isEstimate = false
  }

  /// A remark under a figure, with the symbol that tells it apart.
  struct Note: Hashable, Sendable {
    var symbol: String
    var text: String
  }

  /// One currency of the account.
  struct Pair: Hashable, Sendable {
    var id: String
    /// The currency's code, when the account has more than one currency.
    var header: String?
    /// «≈ 132,900 ₽»; `nil` without a forecast.
    var middle: String?
    /// «от 129,300 ₽ до 135,300 ₽»; `nil` when the three figures are one.
    var range: String?
    var breakdown: [Row]
    var notes: [Note]
    /// What VoiceOver says of the figure: «RUB, примерно 132,900 ₽, от 129,300 ₽ до 135,300 ₽»,
    /// or «RUB, примерно 132,900 ₽» when there is no interval.
    var spoken: String
  }

  static let table = "Accounts"

  static func title(through: DateOnly, _ environment: AppEnvironment) -> String {
    environment.format(
      "account.forecast.title", table: table, environment.dates.dayAndMonth(through))
  }

  static func lowDataNote(_ environment: AppEnvironment) -> Note {
    Note(symbol: "hourglass", text: environment.language("account.forecast.lowData", table: table))
  }

  /// Every currency of the account, in its own order: the currencies it holds, and one it does
  /// not hold only when money moved in it and it was counted.
  static func pairs(_ lines: [AccountForecast.Line], _ environment: AppEnvironment) -> [Pair] {
    let shown = lines.filter { $0.flows.isHeld || $0.status != .notCounted }
    return shown.map { pair($0, showsCurrency: shown.count > 1, environment) }
  }

  static func pair(
    _ line: AccountForecast.Line, showsCurrency: Bool, _ environment: AppEnvironment
  ) -> Pair {
    let money = environment.money
    let currency = line.key.currency
    let flows = line.flows
    func t(_ key: String) -> String { environment.language(key, table: table) }
    func whole(_ amount: AmountE4) -> String { money.rounded(amount, currency: currency) }
    func signed(_ amount: AmountE4) -> String { money.signedRounded(amount, currency: currency) }

    var notes: [Note] = []
    var middle: String?
    var range: String?
    var breakdown: [Row] = []
    var spoken = currency.code
    switch line.status {
    case .notCounted:
      notes.append(Note(symbol: "hourglass", text: t("account.forecast.notCounted")))
    case .noRate(let code):
      notes.append(
        Note(
          symbol: "exclamationmark.octagon",
          text: environment.format("account.forecast.noRate", table: table, code.code)))
    case .ready:
      if let balance = line.balance {
        middle = "≈\u{00A0}\(whole(balance.middle))"
        let rounded = [balance.low, balance.middle, balance.high].map {
          DecimalMath.round($0.decimal, scale: 0)
        }
        if rounded[0] != rounded[2] {
          range = environment.format(
            "account.forecast.range", table: table, whole(balance.low), whole(balance.high))
        }
        // One figure for the whole range is said once, not a second time as its interval.
        spoken =
          range.map {
            environment.format(
              "account.forecast.spoken", table: table, currency.code, whole(balance.middle), $0)
          }
          ?? environment.format(
            "account.forecast.spokenFlat", table: table, currency.code, whole(balance.middle))
      }
    }

    if let now = flows.now {
      breakdown.append(Row(label: t("account.forecast.now"), value: whole(now)))
      // The interest of a deposit right after the income: money expected in, an estimate —
      // grey, with «≈» —, never income until it is recorded.
      let parts: [(label: String, amount: AmountE4, isEstimate: Bool)] = [
        (t("account.forecast.ahead"), flows.writtenAhead, false),
        (t("account.forecast.income"), flows.income, false),
        (t("account.forecast.interest"), flows.interest, true),
        (t("account.forecast.scheduled"), -flows.scheduled, false),
        (t("account.forecast.debts"), -flows.debts, false),
      ]
      for part in parts where !isWholeZero(part.amount) {
        let value = signed(part.amount)
        breakdown.append(
          Row(
            label: part.label, value: part.isEstimate ? "≈\u{00A0}\(value)" : value,
            isEstimate: part.isEstimate))
      }
      // Money that leaves without being my spending goes on at the pace of the window: an
      // estimate, marked as the spending is.
      let paced: [(label: String, amount: AmountE4)] = [
        (t("account.forecast.countLosses"), -flows.reconcileLoss),
        (t("account.forecast.forOthers"), -flows.othersSpending),
      ]
      for part in paced where !isWholeZero(part.amount) {
        breakdown.append(Row(label: part.label, value: "≈\u{00A0}\(signed(part.amount))"))
      }
      if let spending = line.spending, !isWholeZero(spending.middle) {
        let share = line.shareBp.map { money.percent(basisPoints: $0, fractionDigits: 0) } ?? "—"
        breakdown.append(
          Row(
            label: environment.format("account.forecast.spending", table: table, share),
            value: "≈\u{00A0}\(signed(-spending.middle))"))
      }
    }

    if !flows.withoutRate.isEmpty {
      notes.append(
        Note(
          symbol: "exclamationmark.circle",
          text: environment.format(
            "account.forecast.leftOut", table: table,
            flows.withoutRate.map(\.code).joined(separator: ", "))))
    }
    // The remark names only the day: two expectations missed on one day are asked about once.
    var askedDays: Set<DateOnly> = []
    for overdue in flows.overdueIncome where askedDays.insert(overdue.due).inserted {
      notes.append(
        Note(
          symbol: "questionmark.circle",
          text: environment.format(
            "account.forecast.overdueIncome", table: table,
            environment.dates.dayAndMonth(overdue.due))))
    }
    if line.mayGoNegative {
      notes.append(
        Note(symbol: "exclamationmark.triangle", text: t("account.forecast.negative")))
    }

    return Pair(
      id: "\(line.key.accountId.uuidString).\(currency.code)",
      header: showsCurrency ? currency.code : nil, middle: middle, range: range,
      breakdown: breakdown, notes: notes, spoken: spoken)
  }

  /// Rounds to no whole unit: a line of «0 ₽» says nothing and is left out.
  private static func isWholeZero(_ amount: AmountE4) -> Bool {
    DecimalMath.round(amount.decimal, scale: 0) == 0
  }
}
