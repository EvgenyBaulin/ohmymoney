import AppCore
import AppDatabase
import SwiftUI

/// «Отложено за месяц» on the screen of an account the owner puts money aside to — a savings
/// account, a piggy bank, a cushion: what came to it from the accounts that are not saving places
/// themselves this month, less what went back out (`SavingsTotals.putAside`). Round-ups and
/// piggy-bank moves are ordinary transfers; there is no mark on them, so this is all of them.
struct AccountSavingsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  let accountId: UUID

  private var account: PaymentMethod? {
    compute.snapshot?.dataset.paymentMethods.first { $0.id == accountId }
  }

  private var month: MonthKey { environment.today.monthKey }

  var body: some View {
    if let account, account.piggy || account.interest != nil || account.cushion,
      let snapshot = compute.snapshot
    {
      let put = SavingsTotals.putAside(
        into: accountId, ledger: snapshot.ledger, in: Period.month(month).range)
      ComputedBlock(
        title: environment.format(
          "account.savings.title", table: "Accounts", environment.dates.monthTitle(month)),
        state: .ready(put, at: environment.now()), retry: nil
      ) { put in
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: environment.money.exact(put.amount))
            .appFont(.title3.weight(.semibold))
            .monospacedDigit()
            .accessibilityIdentifier("account.savings.amount")
          Text(verbatim: t("account.savings.hint"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
          if put.leftOutForeign > 0 {
            Label {
              Text(
                verbatim: environment.format(
                  "account.savings.foreign", table: "Accounts", String(put.leftOutForeign)))
            } icon: {
              Image(systemName: "globe")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("account.savings")
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }
}

/// «Баллы» on the screen of the account that holds points: what is about to burn and what it is
/// worth in rubles at the rate of the currency of the account, and «Сравнить баллы и деньги…».
struct AccountPointsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var compares = false

  private var accounts: [PaymentMethod] { compute.snapshot?.dataset.paymentMethods ?? [] }

  private var account: PaymentMethod? { accounts.first { $0.id == accountId } }

  /// Another account pays its cashback as points to this one.
  private var holdsPoints: Bool {
    CashbackPoints.owners(among: accounts)[accountId] != nil
  }

  var body: some View {
    if let account, holdsPoints || account.pointsBurn != nil {
      ComputedBlock(
        title: t("account.points.title"), state: .ready(account, at: environment.now()),
        retry: nil
      ) { account in
        VStack(alignment: .leading, spacing: 6) {
          ForEach(notices(account), id: \.self) { line in
            Label {
              Text(verbatim: line)
            } icon: {
              Image(systemName: "flame")
            }
            .monospacedDigit()
          }
          if notices(account).isEmpty {
            Text(verbatim: t("account.points.nothingBurns")).foregroundStyle(.secondary)
          }
          Text(verbatim: rateLine(account))
            .appFont(.caption)
            .foregroundStyle(.secondary)
          Button(t("account.points.compare")) { compares = true }
            .accessibilityIdentifier("account.points.compare")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("account.points")
      .sheet(isPresented: $compares) {
        PointsCompareSheet(rubPerPoint: rate(of: account)).handingOver(dependencies)
      }
    }
  }

  /// What one point is worth: the rate of the currency of the account, one ruble for rubles.
  private func rate(of account: PaymentMethod) -> Decimal {
    let currency = account.mainCurrency
    if currency == .rub { return 1 }
    return compute.snapshot?.context.rubPerUnit[currency] ?? 1
  }

  /// «Сгорит 300 баллов 1 декабря (≈ 150 ₽)», the nearest burning within the month ahead.
  private func notices(_ account: PaymentMethod) -> [String] {
    guard let snapshot = compute.snapshot else { return [] }
    let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
    let balance = snapshot.planning.accounts.balances.balance(key, at: environment.now())
    let found = PointsValue.burning(
      accounts: [account], today: environment.today,
      balances: balance.map { [account.id: $0] } ?? [:],
      rubPerPoint: [account.id: rate(of: account)])
    return found.map { notice in
      let points = environment.money.number(notice.points.decimal)
      let day = environment.dates.dayAndMonth(notice.on)
      guard let rubles = notice.rubles else {
        return environment.format("account.points.burns", table: "Accounts", points, day)
      }
      return environment.format(
        "account.points.burnsWorth", table: "Accounts", points, day,
        environment.money.exact(rubles))
    }
  }

  private func rateLine(_ account: PaymentMethod) -> String {
    environment.format(
      "account.points.rate", table: "Accounts", environment.money.number(rate(of: account)))
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }
}

/// «Сравнить баллы и деньги»: cashback of a percent in points at the rate of a point against
/// cashback of another percent in money, for one purchase — both sides in rubles. Nothing is
/// saved: it is a calculator, and it knows nothing of when the points burn.
struct PointsCompareSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  /// What one point is worth to start with.
  let rubPerPoint: Decimal

  @State private var pointsText = "5"
  @State private var moneyText = "3"
  @State private var rateText = ""
  @State private var spent = AmountE4(whole: 10_000)

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("account.points.compareTitle"))
        .appFont(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      Form {
        field("account.points.comparePoints", $pointsText, suffix: "%")
        field("account.points.compareRate", $rateText, suffix: "₽")
        field("account.points.compareMoney", $moneyText, suffix: "%")
        LabeledContent(t("account.points.compareSpent")) {
          AmountField(amount: $spent)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      if let result = comparison {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            verbatim: environment.format(
              "account.points.comparePointsLine", table: "Accounts",
              environment.money.number(result.pointsEffectivePercent),
              environment.money.exact(result.pointsRubles)))
          Text(
            verbatim: environment.format(
              "account.points.compareMoneyLine", table: "Accounts",
              environment.money.number(result.moneyPercent),
              environment.money.exact(result.moneyRubles)))
          Label {
            Text(verbatim: verdict(result))
          } icon: {
            Image(systemName: result.verdict == .money ? "banknote" : "star.circle")
          }
          .fontWeight(.semibold)
          .accessibilityIdentifier("account.points.compareVerdict")
          Text(verbatim: t("account.points.compareBurn"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        .monospacedDigit()
      } else {
        Text(verbatim: t("account.points.compareNone")).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .themedWindowBackground()
    .onAppear {
      if rateText.isEmpty { rateText = environment.money.number(rubPerPoint) }
    }
  }

  private func field(_ key: String, _ text: Binding<String>, suffix: String) -> some View {
    LabeledContent {
      HStack(spacing: 4) {
        TextField(text: text, prompt: Text(verbatim: "0")) { Text(verbatim: t(key)) }
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .appFont(.body.monospacedDigit())
          .frame(width: 80)
        Text(verbatim: suffix).foregroundStyle(.secondary)
      }
    } label: {
      Text(verbatim: t(key))
    }
  }

  private var comparison: PointsValue.Comparison? {
    guard let points = DebtPayoff.parseRate(pointsText),
      let money = DebtPayoff.parseRate(moneyText),
      let rate = DebtPayoff.parseRate(rateText), rate > 0, spent.raw > 0
    else { return nil }
    return PointsValue.compare(
      pointsPercent: points, rubPerPoint: rate, moneyPercent: money, spent: spent)
  }

  private func verdict(_ result: PointsValue.Comparison) -> String {
    let difference = environment.money.exact(result.difference)
    switch result.verdict {
    case .points:
      return environment.format("account.points.verdictPoints", table: "Accounts", difference)
    case .money:
      return environment.format("account.points.verdictMoney", table: "Accounts", difference)
    case .same: return t("account.points.verdictSame")
    }
  }
}
