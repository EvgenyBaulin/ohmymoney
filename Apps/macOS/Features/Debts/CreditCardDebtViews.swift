import AppCore
import SwiftUI

/// What a credit card in debt says, in the words of the interface and without a view so it can
/// be checked in both languages. The money is the card's balance on its account, counted there
/// once: these lines only show it, and the interest is a grey estimate.
@MainActor
struct CreditCardDebtText: Equatable {
  /// «Кредитная карта Т-Банк».
  var title: String
  /// «Долг 29,100.00 ₽».
  var debt: String
  /// «Срок выписки 30 ноября пропущен: вся задолженность по карте теперь долг».
  var missed: String
  /// «Проценты ≈ 1,205.01 ₽»; `nil` while the card likely charges none.
  var estimate: String?
  /// «Выше лимита на 1,000 ₽»; `nil` within the limit.
  var overLimit: String?

  static let table = "Debts"

  /// Every key the lines use, so a test finds each in both languages.
  static let keys = [
    "debts.cards.header", "debts.card.title", "debts.card.badge", "debts.card.debt",
    "debts.card.missed", "debts.card.missedNoDay", "debts.card.estimate", "debts.card.over",
    "debts.card.counted", "debts.card.open",
  ]

  init(_ line: CreditCardDebtLine, _ environment: AppEnvironment) {
    let money = environment.money
    let language = environment.language
    title = language.format("debts.card.title", table: Self.table, line.name)
    debt = language.format(
      "debts.card.debt", table: Self.table, money.exact(line.debtE4, currency: line.currency))
    missed =
      line.missedDue.map {
        language.format("debts.card.missed", table: Self.table, environment.dates.longDay($0))
      } ?? language("debts.card.missedNoDay", table: Self.table)
    estimate = line.estimateE4.map {
      language.format(
        "debts.card.estimate", table: Self.table,
        "≈\u{00A0}" + money.exact($0, currency: line.currency))
    }
    overLimit =
      line.overLimitE4.raw > 0
      ? language.format(
        "debts.card.over", table: Self.table,
        money.exact(line.overLimitE4, currency: line.currency)) : nil
  }
}

/// The credit cards in debt as cards of the debts overview. A click opens the card of the debt.
struct CreditCardDebtCards: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let lines: [CreditCardDebtLine]
  let open: (UUID) -> Void

  var body: some View {
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(verbatim: environment.language("debts.cards.header", table: "Debts"))
          .appFont(.headline).foregroundStyle(.secondary)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 14)],
          alignment: .leading, spacing: 14
        ) {
          ForEach(lines) { card($0) }
        }
      }
      .accessibilityIdentifier("debts.cards")
    }
  }

  private func card(_ line: CreditCardDebtLine) -> some View {
    let text = CreditCardDebtText(line, environment)
    return Button {
      open(line.accountId)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: text.title).appFont(.headline).lineLimit(1)
          Spacer(minLength: 6)
          Label(
            environment.language("debts.card.badge", table: "Debts"), systemImage: "creditcard"
          )
          .appFont(.caption).foregroundStyle(surfaces.secondary)
        }
        Text(verbatim: environment.money.exact(line.debtE4, currency: line.currency))
          .appFont(.title2.monospacedDigit().weight(.semibold))
        if let estimate = text.estimate {
          Text(verbatim: estimate)
            .appFont(.caption.monospacedDigit()).foregroundStyle(surfaces.secondary)
        }
        if let over = text.overLimit {
          Label(over, systemImage: "exclamationmark.octagon")
            .appFont(.caption.monospacedDigit()).foregroundStyle(.red)
        }
      }
      .contentShape(Rectangle())
      .contentCard()
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("debts.creditCard.\(line.accountId.uuidString)")
  }
}

/// The credit cards in debt as rows of the list on the left of Debts, and of a bank's tab: the
/// name, the debt, and the words that say why it is a debt.
struct CreditCardDebtRows: View {
  @Dependency(\.environment) private var environment
  let lines: [CreditCardDebtLine]

  var body: some View {
    ForEach(lines) { line in
      let text = CreditCardDebtText(line, environment)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Label(line.name, systemImage: "creditcard").lineLimit(1)
          Spacer(minLength: 6)
          Text(verbatim: environment.money.rounded(line.debtE4, currency: line.currency))
            .monospacedDigit()
        }
        if let over = text.overLimit {
          Label(over, systemImage: "exclamationmark.octagon")
            .appFont(.caption.monospacedDigit()).foregroundStyle(.red)
        }
      }
      .tag(DebtsSelection.card(line.accountId))
    }
  }
}

/// The card of a credit card in debt: how much, why it is a debt, the grey interest, the limit,
/// and the way to its account, where the money is.
struct CreditCardDebtDetail: View {
  @Dependency(\.environment) private var environment
  let line: CreditCardDebtLine

  var body: some View {
    let text = CreditCardDebtText(line, environment)
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Label(text.title, systemImage: "creditcard").appFont(.title3.weight(.semibold))
        Text(verbatim: environment.money.exact(line.debtE4, currency: line.currency))
          .appFont(.largeTitle.monospacedDigit().weight(.semibold))
        Label(text.missed, systemImage: "exclamationmark.triangle")
          .fixedSize(horizontal: false, vertical: true)
        if let estimate = text.estimate {
          Text(verbatim: estimate).monospacedDigit().foregroundStyle(.secondary)
        }
        if let over = text.overLimit {
          Label(over, systemImage: "exclamationmark.octagon")
            .monospacedDigit().foregroundStyle(.red)
        }
        Text(verbatim: environment.language("debts.card.counted", table: "Debts"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(environment.language("debts.card.open", table: "Debts")) {
          NotificationCenter.default.post(
            name: .openSidebarItem, object: SidebarItem.account(line.accountId))
        }
        .accessibilityIdentifier("debts.creditCard.open")
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
