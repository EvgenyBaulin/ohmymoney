import AppCore
import SwiftUI

/// «Подписки» as a screen of its own: what everything that is charged by itself costs a month, a
/// year and a day; the notices (a trial ending, a yearly charge, a floating amount outside its
/// band); what could be cancelled; and one card per subscription with its price, the use marked
/// by hand, the people sharing it, the comparison of a year with twelve months and the history of
/// its price. Content cards without glass, two columns on a wide window and one on a phone. The
/// figures are the core's (`SubscriptionsPage`); the writes are the store's, each one step of ⌘Z.
struct SubscriptionsScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  @State private var width: CGFloat = 0
  @State private var page: SubscriptionsPage?
  @State private var dismissed: Set<String> = []
  @State private var termsOf: SubscriptionTermsRequest?
  @State private var cancelling: ScheduledPayment?
  @State private var paymentSheet: PlanningSheet?
  @State private var opened: Set<UUID> = []

  private func t(_ key: String) -> String { SubscriptionsText.t(key, environment) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          ScreenTitleBlock(
            title: t("subs.title"), subtitle: t("subs.subtitle"), identifier: "subs.screen.title")
          Spacer(minLength: 8)
          Button(environment.language("action.ok")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("subs.screen.done")
        }
        if let page, let snapshot = compute.snapshot {
          content(page, snapshot: snapshot)
        } else {
          Text(verbatim: t("subs.empty")).foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
    .background(surfaces.background)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .sheetFrame(minWidth: 520, idealWidth: 860, minHeight: 480, idealHeight: 680)
    .task(id: compute.generation) { await load() }
    .onAppear { dismissed = DebtReminderMarks.read(from: .standard).dismissed }
    .sheet(item: $termsOf) { request in
      SubscriptionTermsSheet(request: request).handingOver(dependencies)
    }
    .sheet(item: $cancelling) { payment in
      SubscriptionCancelSheet(payment: payment).handingOver(dependencies)
    }
    .sheet(item: $paymentSheet) { sheet in
      PlanningSheetView(sheet: sheet).handingOver(dependencies)
    }
    .accessibilityIdentifier("subs.screen")
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    guard let counted = try? await compute.analysis.subscriptionsPage(snapshot),
      !Task.isCancelled
    else { return }
    page = counted
  }

  // MARK: Content

  @ViewBuilder
  private func content(_ page: SubscriptionsPage, snapshot: DataSnapshot) -> some View {
    let names = Dictionary(
      page.rows.map { ($0.id, $0.line.payment.name) }, uniquingKeysWith: { first, _ in first })
    let people = Dictionary(
      snapshot.dataset.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    if page.rows.isEmpty {
      Text(verbatim: t("subs.empty"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .contentCard()
        .accessibilityIdentifier("subs.empty")
    } else {
      hero(page)
      let notices = page.shownNotices(dismissed: dismissed)
      if !notices.isEmpty { noticesCard(notices, names: names) }
      if !page.advice.isEmpty { adviceCard(page, names: names) }
      let columns = ScreenColumns.count(forWidth: width - 40)
      let laid = ScreenColumns.deal(page.rows, into: columns)
      HStack(alignment: .top, spacing: 16) {
        ForEach(Array(laid.enumerated()), id: \.offset) { _, column in
          VStack(alignment: .leading, spacing: 16) {
            ForEach(column) { row in
              rowCard(row, people: people)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    if !page.appStoreCandidates.isEmpty {
      Label {
        Text(verbatim: t("subs.appStore")).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "info.circle")
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .contentCard()
      .accessibilityIdentifier("subs.appStore")
    }
  }

  private func hero(_ page: SubscriptionsPage) -> some View {
    let money = environment.money
    var lines = [
      SubscriptionsText.f(
        "subs.hero.yearDay", environment, money.rounded(page.totals.yearlyRub),
        money.rounded(page.perDayRub))
    ]
    if !page.totals.withoutRate.isEmpty {
      lines.append(
        SubscriptionsText.count("subs.hero.noRate", environment, page.totals.withoutRate.count))
    }
    return ScreenHero(
      caption: t("subs.hero.caption"), figure: money.rounded(page.totals.monthlyRub), lines: lines,
      figureIdentifier: "subs.hero.figure")
  }

  // MARK: Notices

  private func noticesCard(_ notices: [SubscriptionNotice], names: [UUID: String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ScreenCardHeader(title: t("subs.notices"))
      ForEach(notices) { notice in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label {
            Text(verbatim: SubscriptionsText.notice(notice, names: names, environment))
              .monospacedDigit()
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: SubscriptionsText.symbol(notice.kind))
          }
          .appFont(.callout)
          Spacer(minLength: 6)
          Button(t("subs.notice.later")) {
            DebtReminderMarks.dismiss(notice.id, in: .standard)
            dismissed.insert(notice.id)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subs.notice")
      }
    }
    .contentCard()
  }

  // MARK: Advice

  private func adviceCard(_ page: SubscriptionsPage, names: [UUID: String]) -> some View {
    let money = environment.money
    return VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(
        title: t("subs.advice"),
        caption: SubscriptionsText.f(
          "subs.advice.saving", environment, money.rounded(page.advice.savingYearlyRub)))
      ForEach(page.advice.unused) { item in
        VStack(alignment: .leading, spacing: 6) {
          Label {
            Text(verbatim: unusedText(item, names: names)).monospacedDigit()
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "moon.zzz")
          }
          .appFont(.callout)
          HStack(spacing: 8) {
            Button(t("subs.advice.needed")) { setNeeded(item.paymentId, in: page) }
            if let row = page.row(item.paymentId) {
              Button(t("subs.advice.cancel")) { cancelling = row.line.payment }
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subs.advice.unused")
      }
      ForEach(page.advice.duplicates) { group in
        VStack(alignment: .leading, spacing: 6) {
          Label {
            Text(verbatim: duplicateText(group, names: names)).monospacedDigit()
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "square.on.square")
          }
          .appFont(.callout)
          Button(t("subs.advice.keepBoth")) {
            store.keepSubscriptionGroup(
              KeepGroup(type: group.type, paymentIds: Set(group.paymentIds)))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("subs.advice.keepBoth")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subs.advice.duplicate")
      }
    }
    .contentCard()
    .accessibilityIdentifier("subs.advice")
  }

  private func unusedText(_ item: UnusedSubscription, names: [UUID: String]) -> String {
    let name = names[item.paymentId] ?? "—"
    let yearly = environment.money.rounded(item.yearlyRub)
    guard let last = item.lastUsed else {
      return SubscriptionsText.f("subs.advice.unusedNever", environment, name, yearly)
    }
    return SubscriptionsText.f(
      "subs.advice.unused", environment, name, yearly, environment.dates.longDay(last))
  }

  private func duplicateText(_ group: DuplicateGroup, names: [UUID: String]) -> String {
    SubscriptionsText.f(
      "subs.advice.duplicates", environment, SubscriptionsText.typeName(group.type, environment),
      group.paymentIds.compactMap { names[$0] }.joined(separator: ", "),
      environment.money.rounded(group.monthlyRub))
  }

  private func setNeeded(_ id: UUID, in page: SubscriptionsPage) {
    var terms = page.row(id)?.terms ?? SubscriptionTerms(paymentId: id)
    terms.needed = true
    store.saveSubscriptionTerms(terms)
  }

  // MARK: One subscription

  private func rowCard(_ row: SubscriptionsPage.Row, people: [UUID: String]) -> some View {
    let payment = row.line.payment
    let isOpen = opened.contains(row.id)
    return VStack(alignment: .leading, spacing: 8) {
      ScreenCardHeader(
        title: payment.name,
        caption: row.line.type.map { SubscriptionsText.typeName($0, environment) })
      Text(verbatim: SubscriptionsText.cost(row.line, environment))
        .appFont(.body.monospacedDigit())
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: SubscriptionsText.charge(row.line, environment))
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      if row.line.yearlyRub == nil {
        flag(
          "questionmark.circle",
          SubscriptionsText.f(
            "subs.row.noRate", environment, payment.currency.code))
      }
      if let trial = payment.trialEnd, trial >= environment.today {
        flag(
          "hourglass",
          SubscriptionsText.f(
            "subs.row.trial", environment, environment.dates.longDay(trial)))
      }
      if let end = payment.endDate {
        flag(
          "calendar.badge.minus",
          SubscriptionsText.f(
            "subs.row.endsOn", environment, environment.dates.longDay(end)))
      }
      if row.isUnused { flag("moon.zzz", t("subs.row.unused")) }
      if row.terms?.needed == true { flag("pin", t("subs.row.needed")) }
      if let band = row.band {
        flag("plusminus", SubscriptionsText.band(band, environment))
      }
      if let usage = SubscriptionsText.usage(row.usage, environment) {
        flag("checkmark.circle", usage)
      }
      if let comparison = row.comparison {
        flag("arrow.left.arrow.right", SubscriptionsText.comparison(comparison, environment))
      }
      if let family = row.family {
        flag("person.2", SubscriptionsText.family(family, names: people, environment))
      }
      if !row.steps.isEmpty { history(row, isOpen: isOpen) }
      actions(row)
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: payment.name))
    .accessibilityIdentifier("subs.row")
  }

  private func flag(_ symbol: String, _ text: String) -> some View {
    Label {
      Text(verbatim: text).monospacedDigit().fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  private func history(_ row: SubscriptionsPage.Row, isOpen: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        if isOpen { opened.remove(row.id) } else { opened.insert(row.id) }
      } label: {
        Label {
          Text(verbatim: t("subs.row.history"))
        } icon: {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
        }
      }
      .buttonStyle(.borderless)
      .appFont(.callout)
      if isOpen {
        ForEach(row.steps.reversed()) { step in
          VStack(alignment: .leading, spacing: 2) {
            Text(
              verbatim: SubscriptionsText.step(
                step, currency: row.line.payment.currency, environment)
            )
            .appFont(.caption.monospacedDigit())
            if let split = step.split {
              Text(verbatim: SubscriptionsText.split(split, environment))
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func actions(_ row: SubscriptionsPage.Row) -> some View {
    let payment = row.line.payment
    return HStack(spacing: 8) {
      Button(t("subs.action.used")) {
        store.markSubscriptionUsed(payment: payment.id, on: environment.today)
      }
      .accessibilityIdentifier("subs.action.used")
      Button(t("subs.action.terms")) {
        termsOf = SubscriptionTermsRequest(
          payment: payment, terms: row.terms ?? SubscriptionTerms(paymentId: payment.id),
          people: row.line.people)
      }
      .accessibilityIdentifier("subs.action.terms")
      Menu {
        Button(t("subs.action.edit")) { paymentSheet = .payment(payment) }
        if payment.endDate == nil {
          Button(t("subs.action.cancel")) { cancelling = payment }
        }
        if let link = payment.cancelLink {
          Link(t("subs.action.cancelLink"), destination: link)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .fixedSize()
      .accessibilityLabel(Text(verbatim: environment.language("action.edit")))
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }
}
