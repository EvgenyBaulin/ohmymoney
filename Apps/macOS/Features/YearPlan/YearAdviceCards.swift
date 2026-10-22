import AppCore
import SwiftUI

// The cards of the page «Год» that offer something: limits for a dear month, a saving for a
// yearly expense, the property tax. An offer does nothing until the owner answers it (the
// distribution of income works the same way), and «Не сейчас» is kept on this Mac.

/// «В декабре подарки обычно ≈ 20 000 ₽ — поднять лимит на декабрь?», and the limits that
/// differ in one month with «Убрать».
struct YearLimitsCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: YearPage
  let open: (YearSheet) -> Void
  let dismiss: (String) -> Void

  var body: some View {
    YearCard(
      title: YearText.t("year.limits.title", environment),
      symbol: "gauge.with.dots.needle.33percent",
      subtitle: YearText.t("year.limits.subtitle", environment), identifier: "year.limits"
    ) {
      ForEach(page.limitSeasons) { suggestion in
        VStack(alignment: .leading, spacing: 6) {
          Text(
            verbatim: YearText.limitQuestion(
              suggestion, name: page.name(ofBudget: suggestion.budgetId), environment)
          )
          .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button(
              YearText.f(
                "year.limits.raise", environment, environment.money.rounded(suggestion.suggested))
            ) {
              if let dependencies { YearActions(dependencies).raiseLimit(suggestion) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("year.limits.raise")
            Button(YearText.t("year.later", environment)) { dismiss(suggestion.id) }
              .buttonStyle(.bordered)
          }
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
      }
      if page.limitSeasons.isEmpty {
        Text(verbatim: YearText.t("year.limits.none", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      if !page.exceptions.isEmpty {
        Divider()
        Text(verbatim: YearText.t("year.limits.exceptions", environment))
          .appFont(.callout.weight(.semibold))
        ForEach(sorted(page.exceptions), id: \.id) { exception in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
              Text(
                verbatim:
                  "\(environment.dates.monthTitle(exception.month)) · \(page.name(ofBudget: exception.budgetId))"
              )
              .lineLimit(1)
              Text(verbatim: environment.money.rounded(exception.amountE4))
                .monospacedDigit()
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(environment.language("action.edit")) {
              open(.monthLimit(budget: exception.budgetId, month: exception.month))
            }
            .buttonStyle(.link)
            Button(YearText.t("year.limits.remove", environment)) {
              if let dependencies { YearActions(dependencies).removeMonthLimit(exception) }
            }
            .buttonStyle(.link)
          }
          .appFont(.callout)
          .accessibilityElement(children: .contain)
        }
      }
      Button(YearText.t("year.limits.add", environment)) {
        open(.monthLimit(budget: nil, month: nil))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(page.budgets.isEmpty)
      .accessibilityIdentifier("year.limits.add")
    }
  }

  private func sorted(_ exceptions: [LimitMonthException]) -> [LimitMonthException] {
    exceptions.filter { $0.month >= page.today.monthKey }
      .sorted { ($0.month, $0.id.uuidString) < ($1.month, $1.id.uuidString) }
  }
}

/// «Похоже, снова страховка ≈ 12 000 ₽ — завести копилку?» and «В прошлом году был налог
/// 8 000 ₽ — запланировать?».
struct YearAdviceCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: YearPage
  let dismiss: (String) -> Void

  var body: some View {
    YearCard(
      title: YearText.t("year.advice.title", environment), symbol: "lightbulb",
      subtitle: YearText.t("year.advice.subtitle", environment), identifier: "year.advice"
    ) {
      ForEach(page.yearly) { expense in
        VStack(alignment: .leading, spacing: 6) {
          Text(
            verbatim: YearText.reserveQuestion(expense, name: page.name(of: expense), environment)
          )
          .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button(YearText.t("year.reserve.start", environment)) {
              if let dependencies {
                YearActions(dependencies).startReserve(expense, name: page.name(of: expense))
              }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("year.reserve.start")
            Button(YearText.t("year.later", environment)) { dismiss(expense.id) }
              .buttonStyle(.bordered)
          }
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
      }
      ForEach(page.propertyTax) { hint in
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: YearText.taxQuestion(hint, environment))
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button(YearText.t("year.tax.plan", environment)) {
              if let dependencies { YearActions(dependencies).planTax(hint) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("year.tax.plan")
            Button(YearText.t("year.later", environment)) { dismiss(hint.id) }
              .buttonStyle(.bordered)
          }
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
      }
      if page.yearly.isEmpty, page.propertyTax.isEmpty {
        Text(verbatim: YearText.t("year.advice.none", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - The buffer and the week

/// The sum set aside for the unexpected, apart from the cushion: how much of it is left, the
/// free sum without it, the week, and the offer to raise it when income grew by more than a
/// tenth. Spending from it is marked on the operations of the month («Отметить траты…»).
struct YearBufferCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: YearPage
  let open: (YearSheet) -> Void

  var body: some View {
    YearCard(
      title: YearText.t("year.buffer.title", environment), symbol: "lifepreserver",
      subtitle: YearText.t("year.buffer.subtitle", environment), identifier: "year.buffer"
    ) {
      if let state = page.buffer {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: YearText.bufferLine(state, environment))
            .appFont(.callout.monospacedDigit())
            .accessibilityIdentifier("year.buffer.state")
          Label {
            Text(verbatim: YearText.bufferUsed(state, environment))
          } icon: {
            Image(systemName: state.isOverrun ? "exclamationmark.triangle" : "circle.dashed")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
          if let free = page.freeToMonthEnd {
            Text(
              verbatim: YearText.f(
                "year.buffer.free", environment,
                environment.money.rounded(free),
                environment.money.rounded(state.left))
            )
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          }
        }
        if let offer = page.bufferRaise {
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: YearText.raiseQuestion(offer, environment))
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              Button(
                YearText.f("year.buffer.raiseYes", environment, environment.money.rounded(offer))
              ) {
                answer(accepted: offer)
              }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("year.buffer.raiseYes")
              Button(YearText.t("year.buffer.raiseNo", environment)) { answer(accepted: nil) }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
          }
        }
        HStack(spacing: 8) {
          Button(YearText.t("year.buffer.change", environment)) { open(.buffer) }
          Button(YearText.t("year.buffer.marks", environment)) { open(.bufferMarks) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      } else {
        Text(verbatim: YearText.t("year.buffer.off", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
        Button(YearText.t("year.buffer.set", environment)) { open(.buffer) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("year.buffer.set")
      }
      if let week = page.week {
        Divider()
        Label {
          Text(verbatim: YearText.weekLine(week, environment))
        } icon: {
          Image(systemName: week.isOverspent ? "exclamationmark.triangle" : "calendar")
        }
        .appFont(.callout.monospacedDigit())
        .accessibilityIdentifier("year.week")
      }
    }
  }

  private func answer(accepted: AmountE4?) {
    guard let dependencies, let state = page.buffer else { return }
    YearActions(dependencies).answerRaise(
      settings: MonthBufferSettings(amount: state.amount), income: page.incomeNow,
      accepted: accepted)
  }
}

// MARK: - Events

/// The budgets of events with their articles, «Новое событие из шаблона…» and «Сохранить как
/// шаблон…».
struct YearEventsCard: View {
  @Dependency(\.environment) private var environment
  let page: YearPage
  let open: (YearSheet) -> Void

  var body: some View {
    YearCard(
      title: YearText.t("year.events.title", environment), symbol: "party.popper",
      subtitle: YearText.t("year.events.subtitle", environment), identifier: "year.events"
    ) {
      ForEach(page.events) { event in
        let items = page.eventItems[event.id] ?? []
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: event.name).lineLimit(1)
            Spacer(minLength: 8)
            if let budget = event.budgetE4 {
              Text(verbatim: environment.money.rounded(budget)).monospacedDigit()
            }
          }
          Text(
            verbatim: items.isEmpty
              ? YearText.t("year.events.noItems", environment)
              : YearText.f("year.events.items", environment, items.count)
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          HStack(spacing: 8) {
            Button(YearText.t("year.events.edit", environment)) { open(.eventItems(event)) }
              .accessibilityIdentifier("year.events.items")
            if !items.isEmpty {
              Button(YearText.t("year.events.saveTemplate", environment)) {
                open(.saveTemplate(event))
              }
            }
          }
          .buttonStyle(.link)
          .appFont(.caption)
        }
        .accessibilityElement(children: .contain)
      }
      if page.events.isEmpty {
        Text(verbatim: YearText.t("year.events.none", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      Button(YearText.t("year.events.fromTemplate", environment)) { open(.fromTemplate) }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("year.events.fromTemplate")
    }
  }
}
