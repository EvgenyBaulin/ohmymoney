import AppCore
import SwiftUI

/// The words of one row of «Что сделать сейчас».
struct DoNowRowText: Equatable {
  var title: String
  var detail: String
  var button: String
  /// Whether the dot is the warm one (overdue or today, something to sort out) or the grey one.
  var urgent: Bool
}

enum OverviewDoNow {
  static let table = "Overview"

  /// The list the block shows, from the snapshot: due payments, operations to sort out and
  /// banks whose statement is old. Accounts hidden by «Только просмотр» stay out of the lists.
  @MainActor
  static func list(snapshot: DataSnapshot, environment: AppEnvironment) -> DoNowList {
    let hidden = snapshot.hiding
    let entries = snapshot.dataset.entries.filter {
      guard let account = $0.transaction.paymentMethodId else { return true }
      return !hidden.isHidden(account)
    }
    let payments = snapshot.dataset.planning.scheduled.filter {
      guard let account = $0.paymentMethodId else { return true }
      return !hidden.isHidden(account)
    }
    return WhatToDoNow.list(
      payments: payments,
      reviews: DoNowSources.reviews(
        entries: entries, today: environment.today, calendar: environment.calendar),
      statements: DoNowSources.statements(
        entries: entries, today: environment.today, calendar: environment.calendar),
      today: environment.today)
  }

  @MainActor
  static func text(
    _ item: DoNowItem, snapshot: DataSnapshot, environment: AppEnvironment
  ) -> DoNowRowText {
    let money = environment.money
    switch item.action {
    case .post:
      let payment = snapshot.dataset.planning.scheduled.first { $0.id == item.paymentId }
      let due = item.day ?? environment.today
      let amount = payment.map {
        money.rounded(
          SubscriptionMath.price(of: $0, on: due, prices: snapshot.dataset.planning.prices),
          currency: $0.currency)
      } ?? ""
      let when: String
      if due == environment.today {
        when = environment.language("overview.doNow.today", table: table)
      } else if due < environment.today {
        when = environment.format(
          "overview.doNow.overdue", table: table, environment.dates.dayAndMonth(due))
      } else {
        when = environment.dates.dayAndMonth(due)
      }
      return DoNowRowText(
        title: environment.format("overview.doNow.post", table: table, payment?.name ?? ""),
        detail: environment.format("overview.doNow.postDetail", table: table, when, amount),
        button: environment.language("overview.doNow.postButton", table: table), urgent: true)
    case .review:
      return DoNowRowText(
        title: environment.format("overview.doNow.review", table: table, counts: item.count),
        detail: environment.language("overview.doNow.reviewDetail", table: table),
        button: environment.language("overview.doNow.reviewButton", table: table), urgent: true)
    case .load:
      let name = snapshot.dataset.paymentMethods.first { $0.id == item.accountId }?.name ?? ""
      return DoNowRowText(
        title: environment.format("overview.doNow.load", table: table, name),
        detail: environment.format("overview.doNow.loadDetail", table: table, counts: item.daysAgo),
        button: environment.language("overview.doNow.loadButton", table: table), urgent: false)
    }
  }
}

/// «Что сделать сейчас»: up to three things with a button. With nothing to do the block is not
/// drawn at all. «Все» opens the full list of «Стоит посмотреть». A white card with the theme's
/// card edge, as the main card wears it — not the outline of a tile.
struct OverviewDoNowCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.openWindow) private var openWindow
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let screen: OverviewScreen
  /// In a row of tiles the card takes the height of the row.
  var fillsHeight = false
  @State private var failure: [String: String] = [:]

  /// The colour of a row's dot: the accent for what is due, the secondary ink for the rest; the
  /// words of the row say which it is.
  static func dot(urgent: Bool, in theme: AppThemeColors) -> Color {
    urgent ? theme.accentDefault : theme.contentSecondary
  }

  /// «3 дела · Все»: the secondary ink on the Mac, the accent's words on the phone, as their
  /// frames draw it.
  static func countInk(in theme: AppThemeColors) -> Color {
    #if os(iOS)
      theme.accentContent
    #else
      theme.contentSecondary
    #endif
  }

  var body: some View {
    if let snapshot = compute.snapshot {
      let list = OverviewDoNow.list(snapshot: snapshot, environment: environment)
      if !list.isEmpty {
        let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
        VStack(alignment: .leading, spacing: StyleMetrics.doNowGap) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: t("overview.doNow.title"))
              .appFont(StyleType.groupName)
              .foregroundStyle(surfaces.primary)
              .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
              Text(
                verbatim: environment.format(
                  "overview.doNow.count", table: OverviewDoNow.table, counts: list.items.count)
                  + " · ")
              Button(t("overview.doNow.all")) { screen.open(.worthALook) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overview.doNow.all")
            }
            .appFont(StyleType.rowDetail)
            .foregroundStyle(Self.countInk(in: theme))
          }
          ForEach(Array(list.items.enumerated()), id: \.element.id) { position, item in
            if position > 0 {
              Rectangle().fill(theme.borderHairline).frame(height: 1)
            }
            row(item, snapshot: snapshot)
          }
        }
        .frame(
          maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading
        )
        .padding(.horizontal, StyleMetrics.doNowHorizontal)
        .padding(.top, StyleMetrics.doNowTop)
        .padding(.bottom, StyleMetrics.doNowBottom)
        .background(surfaces.card, in: shape)
        .overlay {
          shape.strokeBorder(surfaces.cardBorder, lineWidth: StyleMetrics.cardBorder)
          if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.doNow")
      }
    }
  }

  private func row(_ item: DoNowItem, snapshot: DataSnapshot) -> some View {
    let text = OverviewDoNow.text(item, snapshot: snapshot, environment: environment)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: StyleMetrics.doNowRowGap) {
        Circle()
          .fill(Self.dot(urgent: text.urgent, in: theme))
          .frame(width: StyleMetrics.doNowDot, height: StyleMetrics.doNowDot)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: text.title)
            .appFont(StyleType.rowTitle)
            .foregroundStyle(surfaces.primary)
          Text(verbatim: text.detail)
            .appFont(StyleType.rowDetail)
            .foregroundStyle(surfaces.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button(text.button) { perform(item, snapshot: snapshot) }
          .buttonStyle(.rowAction)
          .accessibilityIdentifier("overview.doNow.\(item.action.rawValue)")
      }
      .padding(.vertical, StyleMetrics.doNowRowVertical)
      if let message = failure[item.id] {
        Text(verbatim: message).appFont(.footnote).foregroundStyle(surfaces.negative)
      }
    }
  }

  private func perform(_ item: DoNowItem, snapshot: DataSnapshot) {
    switch item.action {
    case .post: post(item, snapshot: snapshot)
    case .review:
      TileWhyNavigation.go(.section(.operations), environment: environment, openWindow: openWindow)
    case .load:
      environment.statementImportRequest = StatementImportRequest(urls: [])
    }
  }

  /// «Провести» without a form, as a row of the reminders does it: on the payment's own account.
  private func post(_ item: DoNowItem, snapshot: DataSnapshot) {
    guard let dependencies, let id = item.paymentId,
      let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == id }),
      let due = item.day
    else { return }
    let actions = PlanningActions(dependencies)
    let moment = PlanningActions.paidAt(
      due: due, today: environment.today, calendar: environment.calendar)
    let price = SubscriptionMath.price(
      of: payment, on: due, prices: snapshot.dataset.planning.prices)
    if actions.markAsPaid(
      payment, due: due, amount: price, on: moment, account: payment.paymentMethodId,
      charged: nil, updatePrice: false)
    {
      failure[item.id] = nil
    } else {
      failure[item.id] = environment.format(
        actions.failureKey(currency: payment.currency, on: moment, at: .reminder),
        table: "Planning", payment.currency.code)
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewDoNow.table)
  }
}
