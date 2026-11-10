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
  @Environment(\.layoutIdiom) private var idiom
  /// «Компактно» of this list: the rows alone, without the history of the prices under them.
  @AppStorage(DensityList.purchases.key) private var compact = false

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: PurchasesMetrics.stackGap(LayoutIdiom.resolved(idiom))) {
      if page.wishes.isEmpty {
        Text(verbatim: t("purchases.wishes.empty"))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .sectionCard()
          .accessibilityIdentifier("purchases.wishes.empty")
      } else {
        PurchasesListCard(count: page.wishes.count) { index in
          row(page.wishes[index])
        }
        .accessibilityIdentifier("purchases.wishes.list")
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
          .appFont(SectionType.cardTitle)
        }
        .sectionCard()
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

  /// A row of the frame: the tag in its pastel circle, the name over what the pace of «can save»
  /// says, the chip of the verdict and the price. A click opens what can be done with the wish —
  /// a new price, «Купил», the link, a change, off the list, delete —; so does a right click. In
  /// «Подробно» the history of the prices and the note follow under the row.
  private func row(_ line: WishLine) -> some View {
    let wish = line.wish
    let verdict = PurchasesWishVerdict.of(line)
    return VStack(alignment: .leading, spacing: 6) {
      Menu {
        menu(line)
      } label: {
        PurchasesRow(
          symbol: "tag", title: wish.name,
          detail: detail(line),
          chip: verdict.map { (t($0.titleKey), $0.tone) },
          figure: PurchasesText.price(of: wish, environment))
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .contextMenu { menu(line) }
      .accessibilityIdentifier("purchases.wish.\(wish.id.uuidString)")
      if !compact, line.tracking.history.count >= 2 || wish.note != nil {
        VStack(alignment: .leading, spacing: 4) {
          history(line)
          if let note = wish.note {
            Text(verbatim: note)
              .appFont(SectionType.rowDetail)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, PurchasesMetrics.rowHorizontal(LayoutIdiom.resolved(idiom)))
        .padding(.bottom, 6)
      }
    }
  }

  /// What the pace says, and why it is time to buy when the prices say so.
  private func detail(_ line: WishLine) -> String? {
    if let reason = line.tracking.timeToBuy {
      return t("purchases.timeToBuy") + " · " + PurchasesText.reason(reason, environment)
    }
    return PurchasesText.afford(line, environment)
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
      .appFont(SectionType.rowDetail)
      .foregroundStyle(.secondary)
      if let change = PurchasesText.change(line, environment) {
        Text(verbatim: change).appFont(SectionType.rowDetail).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func menu(_ line: WishLine) -> some View {
    let wish = line.wish
    Button(t("purchases.wish.price")) { open(.price(wish)) }
      .accessibilityIdentifier("purchases.wish.price")
    Button(t("purchases.wish.bought")) { open(.bought(wish)) }
      .accessibilityIdentifier("purchases.wish.bought")
    if let url = PurchaseActions.link(wish.url) {
      Button(t("purchases.wish.link")) { openURL(url) }
        .accessibilityIdentifier("purchases.wish.link")
    }
    Divider()
    Button(t("purchases.wish.edit")) { open(.editWish(wish)) }
    Button(t("purchases.wish.archive")) {
      if let dependencies { report(PurchaseActions(dependencies).archive(wish)) }
    }
    Button(environment.language("action.delete"), role: .destructive) { deleting = wish }
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
