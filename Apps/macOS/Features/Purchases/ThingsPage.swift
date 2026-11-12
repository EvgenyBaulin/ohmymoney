import AppCore
import SwiftUI

/// «Вещи»: what the owner keeps — the assets of the capital (investments aside) and the things
/// noted apart — and what each costs to keep: the price plus what was spent on it under its tag,
/// per month owned, with the end of the warranty beside it. A car adds fuel and the cost of a
/// kilometre. «Продал…» turns the sale into income and closes the thing.
struct ThingsPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: PurchasesPage
  let open: (PurchasesSheet) -> Void
  let report: (PurchaseOutcome) -> Void
  @State private var deleting: OwnedItem?
  @State private var showsSold = false

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
      if page.things.isEmpty {
        Text(verbatim: t("purchases.things.empty"))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .sectionCard()
          .accessibilityIdentifier("purchases.things.empty")
      }
      PurchasesColumns(
        items: page.things,
        head: { EmptyView() },
        tail: { soldGroup },
        card: { card($0) })
    }
    .confirmationDialog(
      PurchasesText.f("purchases.thing.delete.title", environment, deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting, let dependencies {
          report(PurchaseActions(dependencies).delete(item: deleting.id))
        }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("purchases.thing.delete.message"))
    }
  }

  /// The sold things: one row «Проданные вещи: N ›» of the frame; a click lays the list open.
  @ViewBuilder
  private var soldGroup: some View {
    if !page.soldThings.isEmpty {
      PurchasesListCard(count: showsSold ? 1 + page.soldThings.count : 1) { index in
        if index == 0 {
          Button {
            showsSold.toggle()
          } label: {
            HStack(spacing: PurchasesMetrics.rowGap) {
              Text(
                verbatim: PurchasesText.count(
                  "purchases.things.sold", environment, page.soldThings.count)
              )
              .appFont(PurchasesType.title(.mac))
              .frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: showsSold ? "chevron.down" : "chevron.right")
                .font(.system(size: PurchasesMetrics.detailGlyph - 2))  // font-fixed: a 14 glyph
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, PurchasesMetrics.rowHorizontal(.mac))
            .padding(.vertical, PurchasesMetrics.rowVertical(.mac))
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("purchases.things.soldGroup")
        } else {
          soldRow(page.soldThings[index - 1])
            .padding(.horizontal, PurchasesMetrics.rowHorizontal(.mac))
            .padding(.vertical, PurchasesMetrics.rowVertical(.mac))
        }
      }
    }
  }

  private func card(_ line: OwnedLine) -> some View {
    PurchasesFactCard {
      PurchasesCardTitle(
        title: line.name, detail: origin(line),
        figure: line.cost.priceMissing ? nil : environment.money.rounded(line.cost.priceRubE4))
      PurchasesDetailLine(
        symbol: "chart.bar", text: PurchasesText.ownership(line.cost, environment)
      )
      .accessibilityIdentifier("purchases.thing.cost")
      if line.cost.priceMissing {
        PurchasesDetailLine(symbol: "questionmark.circle", text: t("purchases.thing.noPrice"))
      }
      if let warranty = PurchasesText.warranty(line.cost, environment) {
        PurchasesDetailLine(symbol: "checkmark", text: warranty)
      }
      if let vehicle = line.vehicle, let text = PurchasesText.vehicle(vehicle, environment) {
        PurchasesDetailLine(symbol: "fuelpump", text: text)
          .accessibilityIdentifier("purchases.thing.vehicle")
      }
      if line.subject.tagId == nil {
        PurchasesDetailLine(symbol: "tag", text: t("purchases.thing.noTag"))
      }
      PurchasesActionRow {
        Button(t("purchases.valuation.update")) { open(.valuation(line)) }
          .accessibilityIdentifier("purchases.valuation.update")
        Button(t("purchases.thing.files")) { open(.files(line)) }
        Button(t("purchases.thing.sell")) { open(.sell(line)) }
          .accessibilityIdentifier("purchases.thing.sell")
        if case .item(let item) = line.origin {
          Button(t("purchases.thing.edit")) { open(.editThing(item)) }
          Button(environment.language("action.delete"), role: .destructive) { deleting = item }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("purchases.thing.\(line.id)")
  }

  /// «Из «Капитала»» or the day of the purchase of a thing noted apart.
  private func origin(_ line: OwnedLine) -> String {
    switch line.origin {
    case .asset: t("purchases.thing.fromCapital")
    case .item(let item):
      item.boughtOn.map {
        PurchasesText.f("purchases.thing.boughtOn", environment, environment.dates.longDay($0))
      } ?? t("purchases.thing.noteApart")
    }
  }

  private func soldRow(_ line: OwnedLine) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: line.name).appFont(.callout.weight(.semibold))
      Text(verbatim: PurchasesText.ownership(line.cost, environment))
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      if !line.cost.saleRubE4.isZero {
        Text(
          verbatim: PurchasesText.f(
            "purchases.thing.soldFor", environment, environment.money.rounded(line.cost.saleRubE4))
        )
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
