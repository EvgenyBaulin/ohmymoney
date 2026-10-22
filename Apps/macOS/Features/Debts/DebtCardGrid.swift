import AppCore
import SwiftUI

/// What a card of the debts overview says, worked out from a `DebtLine` without a view: the
/// kind of debt (with its own word and symbol, never colour alone), how far it is paid, the
/// payment and the nearest due.
struct DebtCardModel: Identifiable, Equatable {
  enum Badge: String, Equatable {
    case existing, purchase, instalment, closed

    var symbol: String {
      switch self {
      case .existing: "clock.arrow.circlepath"
      case .purchase: "cart"
      case .instalment: "calendar.badge.clock"
      case .closed: "checkmark.circle"
      }
    }

    var key: String { "debts.badge.\(rawValue)" }
  }

  let id: UUID
  let name: String
  let badge: Badge
  let balance: AmountE4
  let currency: CurrencyCode
  /// 0…1 of what was borrowed that is already paid; `nil` when the journal has no borrowing.
  let progress: Double?
  let payment: AmountE4?
  let nextPayment: DateOnly?
  let rate: Decimal?

  init(_ line: DebtLine) {
    let debt = line.debt
    id = line.id
    name = debt.name
    badge = Self.badge(of: debt)
    balance = line.balanceRub ?? line.balance
    currency = line.balanceRub == nil ? debt.currency : .rub
    progress = Self.progress(of: line)
    payment = debt.monthlyPaymentE4
    nextPayment = line.nextPayment
    rate = debt.interestRate
  }

  static func badge(of debt: Debt) -> Badge {
    if debt.closed { return .closed }
    if debt.isInstalmentPlan { return .instalment }
    return debt.origin == .purchase ? .purchase : .existing
  }

  /// Paid share of everything borrowed on the debt, clamped to 0…1.
  static func progress(of line: DebtLine) -> Double? {
    let borrowed = line.entries.filter { $0.amountE4.raw > 0 }
      .reduce(Decimal(0)) { $0 + Decimal($1.amountE4.raw) }
    guard borrowed > 0 else { return nil }
    let left = Decimal(max(line.balance.raw, 0))
    let share = (borrowed - left) / borrowed
    let value = NSDecimalNumber(decimal: share).doubleValue  // chart-only
    return min(max(value, 0), 1)
  }
}

/// The debts overview as cards, one per debt: kind badge, balance, progress, payment and the
/// nearest due; «Закрытые» below. A click opens the card of the debt.
struct DebtCardGrid: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let lines: [DebtCardModel]
  let closed: [DebtCardModel]
  let open: (UUID) -> Void
  let delete: (UUID) -> Void

  private let columns = [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 14)]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if lines.isEmpty {
        Text(verbatim: t("debts.none")).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
        ForEach(lines) { card($0) }
      }
      if !closed.isEmpty {
        Text(verbatim: t("debts.closed")).appFont(.headline).foregroundStyle(.secondary)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
          ForEach(closed) { card($0) }
        }
      }
    }
  }

  private func card(_ model: DebtCardModel) -> some View {
    Button {
      open(model.id)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: model.name).appFont(.headline).lineLimit(1)
          Spacer(minLength: 6)
          DebtBadgeCapsule(badge: model.badge)
        }
        Text(verbatim: environment.money.rounded(model.balance, currency: model.currency))
          .appFont(.title2.monospacedDigit().weight(.semibold))
        if let rate = model.rate, rate > 0 {
          Text(verbatim: "\(environment.money.number(rate)) %")
            .appFont(.caption).foregroundStyle(surfaces.secondary)
        }
        if let progress = model.progress {
          ProgressView(value: progress)
            .tint(model.badge == .closed ? surfaces.positive : surfaces.accent)
            .accessibilityLabel(t("debts.card.paid"))
            .accessibilityValue("\(Int((progress * 100).rounded())) %")
        }
        row(
          t("debts.card.payment"),
          model.payment.map { environment.money.rounded($0, currency: model.currency) })
        row(
          t("debts.card.nextDue"), model.nextPayment.map { environment.dates.dayAndMonth($0) })
      }
      .contentShape(Rectangle())
      .contentCard()
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(t("debts.delete"), role: .destructive) { delete(model.id) }
    }
    .accessibilityIdentifier("debts.card.\(model.id.uuidString)")
  }

  private func row(_ label: String, _ value: String?) -> some View {
    HStack {
      Text(verbatim: label)
      Spacer(minLength: 6)
      Text(verbatim: value ?? "—").monospacedDigit()
    }
    .appFont(.caption)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
