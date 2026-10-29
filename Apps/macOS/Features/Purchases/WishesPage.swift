import AppCore
import SwiftUI

/// «Хочу купить»: the wishes, the most wanted first. Each card says what it costs, how many
/// months it takes at the pace of «can save», what the prices noted by hand did and whether it
/// is time to buy; «Купил» ties it to the operation and tells what came out against what was
/// thought. Bought wishes are kept below with that comparison.
struct WishesPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.openURL) private var openURL
  let page: PurchasesPage
  let open: (PurchasesSheet) -> Void
  let report: (PurchaseOutcome) -> Void
  @State private var deleting: Wish?
  @State private var showsBought = false

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(verbatim: t("purchases.wishes.heading")).appFont(.headline)
        Spacer()
        Button {
          open(.newWish)
        } label: {
          Label {
            Text(verbatim: t("purchases.wishes.add"))
          } icon: {
            Image(systemName: "plus")
          }
        }
        .accessibilityIdentifier("purchases.wishes.add")
      }
      if page.wishes.isEmpty {
        Text(verbatim: t("purchases.wishes.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .contentCard()
          .accessibilityIdentifier("purchases.wishes.empty")
      }
      ForEach(page.wishes) { line in
        card(line)
      }
      if !page.bought.isEmpty {
        DisclosureGroup(isExpanded: $showsBought) {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(page.bought) { line in boughtRow(line) }
          }
          .padding(.top, 8)
        } label: {
          Text(
            verbatim: PurchasesText.count(
              "purchases.bought.heading", environment, page.bought.count)
          )
          .appFont(.headline)
        }
        .contentCard()
        .accessibilityIdentifier("purchases.bought")
      }
    }
    .confirmationDialog(
      PurchasesText.f("purchases.wish.delete.title", environment, deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting, let dependencies {
          report(PurchaseActions(dependencies).delete(wish: deleting.id))
        }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("purchases.wish.delete.message"))
    }
  }

  // MARK: A wish

  private func card(_ line: WishLine) -> some View {
    let wish = line.wish
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: wish.name).appFont(.headline)
          if wish.priority > 0 {
            Text(
              verbatim: PurchasesText.f("purchases.wish.priority", environment, wish.priority)
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Text(verbatim: PurchasesText.price(of: wish, environment))
          .appFont(.title3.monospacedDigit())
      }
      if let text = PurchasesText.afford(line, environment) {
        Label {
          Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "calendar")
        }
        .appFont(.callout)
        .accessibilityIdentifier("purchases.wish.afford")
      }
      if let reason = line.tracking.timeToBuy {
        Label {
          Text(
            verbatim: t("purchases.timeToBuy") + " · " + PurchasesText.reason(reason, environment)
          )
          .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "bell")
        }
        .appFont(.callout.weight(.semibold))
        .accessibilityIdentifier("purchases.wish.timeToBuy")
      }
      history(line)
      if let note = wish.note {
        Text(verbatim: note)
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      actions(line)
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("purchases.wish.\(wish.id.uuidString)")
  }

  @ViewBuilder
  private func history(_ line: WishLine) -> some View {
    let tracking = line.tracking
    if tracking.history.count >= 2 {
      WishPriceChart(
        prices: tracking.history, calendar: environment.calendar,
        describe: { price in
          environment.dates.longDay(price.onDate) + ", "
            + environment.money.rounded(price.priceE4, currency: line.wish.currency)
        }
      )
      .frame(height: 72)
      .accessibilityIdentifier("purchases.wish.chart")
      HStack(spacing: 12) {
        if let lowest = tracking.lowestE4 {
          Text(
            verbatim: PurchasesText.f(
              "purchases.price.lowest", environment,
              environment.money.rounded(lowest, currency: line.wish.currency))
          )
        }
        if let highest = tracking.highestE4 {
          Text(
            verbatim: PurchasesText.f(
              "purchases.price.highest", environment,
              environment.money.rounded(highest, currency: line.wish.currency))
          )
        }
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      if let change = PurchasesText.change(line, environment) {
        Text(verbatim: change).appFont(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func actions(_ line: WishLine) -> some View {
    let wish = line.wish
    return HStack {
      Button(t("purchases.wish.price")) { open(.price(wish)) }
        .accessibilityIdentifier("purchases.wish.price")
      Button(t("purchases.wish.bought")) { open(.bought(wish)) }
        .accessibilityIdentifier("purchases.wish.bought")
      if let url = PurchaseActions.link(wish.url) {
        Button(t("purchases.wish.link")) { openURL(url) }
          .accessibilityIdentifier("purchases.wish.link")
      }
      Spacer()
      Menu {
        Button(t("purchases.wish.edit")) { open(.editWish(wish)) }
        Button(t("purchases.wish.archive")) {
          if let dependencies { report(PurchaseActions(dependencies).archive(wish)) }
        }
        Button(environment.language("action.delete"), role: .destructive) { deleting = wish }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: t("purchases.wish.more")))
      .accessibilityIdentifier("purchases.wish.more")
    }
    .buttonStyle(.bordered)
  }

  // MARK: Bought

  private func boughtRow(_ line: BoughtWishLine) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: line.wish.name).appFont(.callout.weight(.semibold))
      if let outcome = line.outcome {
        Text(
          verbatim: PurchasesText.outcome(outcome, currency: line.wish.currency, environment)
        )
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      } else {
        Text(verbatim: t("purchases.bought.noOutcome"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
