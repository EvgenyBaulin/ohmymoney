import AppCore
import AppDatabase
import SwiftUI

/// The rows of «Забытые деньги»: an account or a card, how long nothing moved on it, what it
/// holds or that it may charge. A click opens the account.
struct ForgottenRows: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let products: [ForgottenProduct]

  private func name(_ product: ForgottenProduct) -> String {
    let dataset = compute.snapshot?.dataset
    let account = dataset?.paymentMethods.first { $0.id == product.accountId }?.name ?? "—"
    guard let cardId = product.cardId,
      let card = dataset?.cards.first(where: { $0.id == cardId })
    else { return account }
    return "\(card.name) · \(account)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(products) { product in
        Button {
          NotificationCenter.default.post(
            name: .openSidebarItem, object: SidebarItem.account(product.accountId))
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Label(name(product), systemImage: "zzz")
              Spacer()
              if product.balanceRub.raw > 0 {
                Text(verbatim: environment.money.rounded(product.balanceRub)).monospacedDigit()
              }
            }
            Text(verbatim: BankText.idle(product.idleDays, environment))
              .appFont(.caption).foregroundStyle(.secondary)
            if product.mayCharge {
              Text(verbatim: BankText.t("bank.forgotten.mayCharge", environment))
                .appFont(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// «Забытые деньги»: every account and card nothing has moved on for the days the settings say,
/// with money or a charge on it.
struct ForgottenMoneySheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  private var products: [ForgottenProduct] { compute.snapshot?.planning.banks.forgotten ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: BankText.t("bank.forgotten.title", environment)).appFont(.headline)
      if products.isEmpty {
        Text(verbatim: BankText.t("bank.forgotten.empty", environment))
          .foregroundStyle(.secondary)
      } else {
        ScrollView { ForgottenRows(products: products) }
      }
      Text(
        verbatim: environment.format(
          "bank.forgotten.hint", table: BankText.table,
          "\(compute.snapshot?.dataset.bankData.settings.forgottenDays ?? BankSettings.defaultForgottenDays)"
        )
      )
      .appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 420)
    .accessibilityIdentifier("bank.forgotten.sheet")
  }
}

/// «Что перепривязать»: the payments and subscriptions paid with a card that ends or is
/// replaced. Nothing is moved here: the owner opens each one and picks another card.
struct CardRebindSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  let cardId: UUID

  private var dataset: Dataset? { compute.snapshot?.dataset }

  private var cardName: String {
    dataset?.cards.first { $0.id == cardId }?.name ?? "—"
  }

  private var attached: [CardExpiry.Attached] {
    dataset.map { CardExpiries.attached(to: cardId, dataset: $0) } ?? []
  }

  private var isMain: Bool {
    guard let dataset, let card = dataset.cards.first(where: { $0.id == cardId }) else {
      return false
    }
    return dataset.paymentMethods.first { $0.id == card.accountId }?.mainCardId == cardId
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: BankText.t("bank.card.rebind.title", environment) + " · " + cardName)
        .appFont(.headline)
      if isMain {
        Label(BankText.t("bank.card.rebind.main", environment), systemImage: "star")
          .appFont(.callout)
      }
      if attached.isEmpty {
        Text(verbatim: BankText.t("bank.card.rebind.empty", environment))
          .foregroundStyle(.secondary)
      } else {
        ForEach(attached) { item in
          Label(
            item.name,
            systemImage: item.isSubscription ? "arrow.triangle.2.circlepath" : "calendar")
        }
      }
      Text(verbatim: BankText.t("bank.card.rebind.hint", environment))
        .appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 320)
    .accessibilityIdentifier("bank.rebind.sheet")
  }
}

/// «Банкам за год»: the fees and the interest on credits of a year, month by month, with the
/// CSV of the other reports.
struct BankFeesSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var year = 0
  @State private var report: BankFeesYear?
  @State private var exportRequest: PersonalDataExport?
  @State private var exportFailed = false

  private func t(_ key: String) -> String { BankText.t(key, environment) }

  private var years: [Int] {
    let this = environment.today.year
    let first = compute.snapshot?.ledger.firstDay?.year ?? this
    return Array((min(first, this)...this).reversed())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: t("bank.fees.title")).appFont(.headline)
        Spacer()
        Picker(selection: $year) {
          ForEach(years, id: \.self) { Text(verbatim: String($0)).tag($0) }
        } label: {
          Text(verbatim: t("bank.fees.title"))
        }
        .labelsHidden()
        .fixedSize()
      }
      if let report {
        Text(
          verbatim: environment.format(
            "bank.fees.summary", table: BankText.table,
            environment.money.rounded(report.feesRub),
            environment.money.rounded(report.interestRub))
        )
        .appFont(.title3.monospacedDigit())
        .accessibilityIdentifier("bank.fees.summary")
        if report.isEmpty {
          Text(verbatim: t("bank.fees.empty")).foregroundStyle(.secondary)
        } else {
          Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
              Text(verbatim: t("bank.fees.month")).gridColumnAlignment(.leading)
              Text(verbatim: t("bank.fees.fees"))
              Text(verbatim: t("bank.fees.interest"))
              Text(verbatim: t("bank.fees.total"))
            }
            .appFont(.caption).foregroundStyle(.secondary)
            ForEach(report.months) { month in
              GridRow {
                Text(verbatim: environment.dates.shortMonth(month.month)).gridColumnAlignment(
                  .leading)
                Text(verbatim: environment.money.rounded(month.feesRub))
                Text(verbatim: environment.money.rounded(month.interestRub))
                Text(verbatim: environment.money.rounded(month.totalRub))
              }
              .monospacedDigit()
            }
          }
        }
      } else {
        ProgressView()
      }
      Text(verbatim: t("bank.fees.hint")).appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Button(t("bank.fees.export")) { export() }
          .disabled(report == nil)
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 560)
    .task {
      if year == 0 { year = environment.today.year }
    }
    .task(id: year) {
      guard year != 0, let snapshot = compute.snapshot else { return }
      let chosen = year
      report = await Task.detached(priority: .userInitiated) {
        BankFeesReport.year(
          chosen, ledger: snapshot.ledger, rubPerUnit: snapshot.planning.rubPerUnit)
      }.value
    }
    .exportsPersonalData(
      $exportRequest, environment: environment,
      onFinished: { result in
        if case .failure = result { exportFailed = true }
      }
    )
    .alert(ReportsText.t("reports.export.failed", environment), isPresented: $exportFailed) {
      Button(environment.language("action.ok")) {}
    }
    .accessibilityIdentifier("bank.fees.sheet")
  }

  private func export() {
    guard let report else { return }
    let name = "bank-fees-\(report.year)"
    exportRequest = PersonalDataExport(
      defaultName: name,
      files: [.init(name: name + ".csv", data: BankFeesReport.csv(report))])
  }
}

/// «Забытыми считать через (дней)» of the settings of accounts: after how many days without a
/// movement an account or a card with money or a charge on it is listed as forgotten. One choice
/// is one write and one step of ⌘Z.
struct ForgottenDaysSetting: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  /// The choices; a value kept from elsewhere is listed too.
  static let choices = [30, 60, 90, 120, 180, 365]

  private var settings: BankSettings {
    compute.snapshot?.dataset.bankData.settings ?? .standard
  }

  var body: some View {
    let current = settings.forgottenDays
    let options = Array(Set(Self.choices + [current])).sorted()
    VStack(alignment: .leading, spacing: 2) {
      Picker(
        selection: Binding(get: { current }, set: { set($0) })
      ) {
        ForEach(options, id: \.self) { Text(verbatim: String($0)).tag($0) }
      } label: {
        Text(verbatim: BankText.t("bank.settings.forgottenDays", environment))
      }
      .fixedSize()
      .accessibilityIdentifier("settings.banks.forgottenDays")
      Text(verbatim: BankText.t("bank.settings.forgottenDays.hint", environment))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  private func set(_ days: Int) {
    var next = settings
    next.forgottenDays = days
    let key = BankSettings.forgottenDaysKey
    var values: [String: String?] = [:]
    values.updateValue(next.storedValues[key] ?? nil, forKey: key)
    _ = AccountActions(environment: environment, store: store)
      .apply(PlanningChange(settings: values, at: environment.now()))
  }
}
