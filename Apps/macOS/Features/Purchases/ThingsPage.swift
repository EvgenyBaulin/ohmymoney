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
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(verbatim: t("purchases.things.heading")).appFont(.headline)
        Spacer()
        Button {
          open(.newThing)
        } label: {
          Label {
            Text(verbatim: t("purchases.things.add"))
          } icon: {
            Image(systemName: "plus")
          }
        }
        .accessibilityIdentifier("purchases.things.add")
      }
      if page.things.isEmpty {
        Text(verbatim: t("purchases.things.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentCard()
          .accessibilityIdentifier("purchases.things.empty")
      }
      ForEach(page.things) { line in card(line) }
      if !page.soldThings.isEmpty {
        DisclosureGroup(isExpanded: $showsSold) {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(page.soldThings) { line in soldRow(line) }
          }
          .padding(.top, 8)
        } label: {
          Text(
            verbatim: PurchasesText.count(
              "purchases.things.sold", environment, page.soldThings.count)
          )
          .appFont(.headline)
        }
        .contentCard()
        .accessibilityIdentifier("purchases.things.soldGroup")
      }
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

  private func card(_ line: OwnedLine) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: line.name).appFont(.headline)
          Text(verbatim: origin(line)).appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if !line.cost.priceMissing {
          Text(verbatim: environment.money.rounded(line.cost.priceRubE4))
            .appFont(.title3.monospacedDigit())
        }
      }
      Label {
        Text(verbatim: PurchasesText.ownership(line.cost, environment))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "sum")
      }
      .appFont(.callout.monospacedDigit())
      .accessibilityIdentifier("purchases.thing.cost")
      if line.cost.priceMissing {
        Text(verbatim: t("purchases.thing.noPrice"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let warranty = PurchasesText.warranty(line.cost, environment) {
        Label {
          Text(verbatim: warranty)
        } icon: {
          Image(systemName: "checkmark.shield")
        }
        .appFont(.callout)
      }
      if let vehicle = line.vehicle, let text = PurchasesText.vehicle(vehicle, environment) {
        Label {
          Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "fuelpump")
        }
        .appFont(.callout.monospacedDigit())
        .accessibilityIdentifier("purchases.thing.vehicle")
      }
      if line.subject.tagId == nil {
        Text(verbatim: t("purchases.thing.noTag"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button(t("purchases.thing.sell")) { open(.sell(line)) }
          .accessibilityIdentifier("purchases.thing.sell")
        if case .item(let item) = line.origin {
          Button(t("purchases.thing.edit")) { open(.editThing(item)) }
          Button(environment.language("action.delete"), role: .destructive) { deleting = item }
        }
      }
      .buttonStyle(.bordered)
    }
    .contentCard()
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
