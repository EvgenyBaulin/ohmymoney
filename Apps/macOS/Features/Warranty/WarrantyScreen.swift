import AppCore
import SwiftUI

/// «Гарантии»: the purchases that have a warranty or a term of return, the nearest end first —
/// what is still running, then what has ended. A search looks at the name and at the place of the
/// original; a row opens the operation to change it. Content cards without glass; every state is
/// told in words and a symbol, never by colour alone. The order and the days are the core's
/// (`WarrantyList`).
struct WarrantyScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  @State private var items: [WarrantyItem] = []
  @State private var query = ""
  @State private var editing: TransactionEntry?

  private func t(_ key: String) -> String { WarrantyText.t(key, environment) }

  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  /// The items the search leaves, split into those with a term still running and the rest.
  private var shown: (running: [WarrantyItem], ended: [WarrantyItem]) {
    let found = WarrantyList.sorted(WarrantyList.matching(items, query: query), today: today)
    return (
      found.filter { $0.nextEnd(today: today) != nil },
      found.filter { $0.nextEnd(today: today) == nil }
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          ScreenTitleBlock(
            title: t("warranty.title"), subtitle: t("warranty.subtitle"),
            identifier: "warranty.screen.title")
          Spacer(minLength: 8)
          Button(environment.language("action.ok")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("warranty.screen.done")
        }
        if items.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: t("warranty.empty")).appFont(.headline)
            Text(verbatim: t("warranty.empty.hint")).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityIdentifier("warranty.empty")
        } else {
          TextField(text: $query, prompt: Text(verbatim: t("warranty.search"))) {
            Text(verbatim: t("warranty.search"))
          }
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("warranty.search")
          let split = shown
          if split.running.isEmpty && split.ended.isEmpty {
            Text(verbatim: t("warranty.nothingFound")).foregroundStyle(.secondary)
          }
          section("warranty.section.running", split.running)
          section("warranty.section.ended", split.ended)
        }
      }
      .padding(20)
    }
    .background(surfaces.background)
    .sheetFrame(minWidth: 480, idealWidth: 640, minHeight: 420, idealHeight: 640)
    .task(id: compute.generation) { reload() }
    .onAppear { reload() }
    .sheet(item: $editing) { entry in
      EditTransactionSheet(entry: entry).handingOver(dependencies)
    }
    .accessibilityIdentifier("warranty.screen")
  }

  private func reload() {
    guard let snapshot = compute.snapshot else { return }
    items = WarrantyList.items(from: snapshot.dataset.entries)
  }

  @ViewBuilder
  private func section(_ titleKey: String, _ rows: [WarrantyItem]) -> some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: t(titleKey)).appFont(.headline)
        ForEach(rows) { item in row(item) }
      }
    }
  }

  private func row(_ item: WarrantyItem) -> some View {
    let name = WarrantyText.name(item.title, occurredAt: item.occurredAt, environment)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: name).appFont(.body.weight(.semibold)).lineLimit(2)
        Spacer(minLength: 8)
        Button(t("warranty.open")) { open(item) }
          .buttonStyle(.link)
          .appFont(.caption)
          .accessibilityIdentifier("warranty.row.open")
      }
      if let until = item.warrantyUntil {
        termLine(
          symbol: "checkmark.shield", key: "warranty.row.until", day: until,
          left: item.warrantyDaysLeft(today: today))
      }
      if let until = item.returnUntil {
        termLine(
          symbol: "arrow.uturn.backward.circle", key: "warranty.row.return", day: until,
          left: item.returnDaysLeft(today: today))
      }
      if let place = item.warrantyWhere {
        Label {
          Text(verbatim: WarrantyText.f("warranty.row.place", environment, place))
        } icon: {
          Image(systemName: "shippingbox")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("warranty.row")
  }

  private func termLine(symbol: String, key: String, day: DateOnly, left: Int?) -> some View {
    let text =
      WarrantyText.f(key, environment, environment.dates.longDay(day))
      + (left.map { " · " + WarrantyText.left($0, environment) } ?? "")
    let over = (left ?? 0) < 0
    return Label {
      Text(verbatim: text).monospacedDigit()
    } icon: {
      Image(systemName: over ? "clock.badge.xmark" : symbol)
    }
    .appFont(.callout)
    .foregroundStyle(over ? .secondary : .primary)
  }

  private func open(_ item: WarrantyItem) {
    guard let entry = compute.snapshot?.dataset.entries.first(where: { $0.id == item.id }) else {
      return
    }
    editing = entry
  }
}
