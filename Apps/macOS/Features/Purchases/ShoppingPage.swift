import AppCore
import SwiftUI

/// «Покупки»: the second list, for what is to be bought on the next trip to the shop. A line is
/// added by typing and Return, ticked with its box, and the ticked ones are cleared in one go.
struct ShoppingPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: PurchasesPage
  let report: (PurchaseOutcome) -> Void
  @State private var draft = ""
  @FocusState private var typing: Bool
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.layoutIdiom) private var idiom

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var doneCount: Int { page.shopping.filter(\.done).count }

  var body: some View {
    VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
      VStack(alignment: .leading, spacing: PurchasesMetrics.fieldLabelGap) {
        Text(verbatim: t("purchases.shopping.add"))
          .appFont(PurchasesType.fieldLabel)
          .foregroundStyle(.secondary)
        TextField(text: $draft) { Text(verbatim: t("purchases.shopping.add")) }
          .textFieldStyle(.plain)
          .appFont(PurchasesType.field)
          .padding(.horizontal, PurchasesMetrics.fieldHorizontal)
          .padding(.vertical, PurchasesMetrics.fieldVertical)
          .background(
            surfaces.card, in: RoundedRectangle(cornerRadius: PurchasesMetrics.fieldRadius)
          )
          .overlay {
            RoundedRectangle(cornerRadius: PurchasesMetrics.fieldRadius)
              .strokeBorder(theme.borderOutline, lineWidth: 1)
          }
          .focused($typing)
          .onSubmit(add)
          .accessibilityIdentifier("purchases.shopping.field")
      }
      Button(t("purchases.shopping.addButton"), action: add)
        .buttonStyle(PurchasesAccentButtonStyle())
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("purchases.shopping.addButton")
      if page.shopping.isEmpty {
        Text(verbatim: t("purchases.shopping.empty"))
          .appFont(SectionType.rowDetail)
          .foregroundStyle(.secondary)
          .sectionCard()
          .accessibilityIdentifier("purchases.shopping.empty")
      } else {
        PurchasesListCard(count: page.shopping.count) { index in
          row(page.shopping[index])
        }
        .accessibilityIdentifier("purchases.shopping.list")
        if doneCount > 0 {
          Button(PurchasesText.count("purchases.shopping.clear", environment, doneCount)) {
            if let dependencies { report(PurchaseActions(dependencies).clearDone()) }
          }
          .buttonStyle(PurchasesActionButtonStyle())
          .accessibilityIdentifier("purchases.shopping.clear")
        }
      }
    }
  }

  private func add() {
    guard let dependencies else { return }
    let outcome = PurchaseActions(dependencies).addShopping(draft)
    report(outcome)
    if outcome == .done { draft = "" }
    typing = true
  }

  /// A line of the frame: the cart in its pastel circle, a ring to tick (a tick when done) and
  /// the name, 13 medium — the ticked one in the grey. «Убрать из списка» is the context menu.
  private func row(_ item: ShoppingItem) -> some View {
    HStack(spacing: PurchasesMetrics.rowGap) {
      if design != .phone {
        Image(systemName: "cart")
          .font(.system(size: 14, weight: .medium))  // font-fixed: the glyph of a fixed badge
          .foregroundStyle(theme.accentDefault)
          .frame(width: PurchasesMetrics.badge, height: PurchasesMetrics.badge)
          .background(theme.accentTint, in: Circle())
          .accessibilityHidden(true)
      }
      Button {
        if let dependencies { report(PurchaseActions(dependencies).setDone(item.id, !item.done)) }
      } label: {
        Image(systemName: item.done ? "checkmark" : "circle")
          .font(.system(size: 15, weight: .regular))  // font-fixed: the mark of a fixed 20 box
          .foregroundStyle(item.done ? theme.statusPositive : theme.contentSecondary)
          .frame(width: PurchasesMetrics.markSize, height: PurchasesMetrics.markSize)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(verbatim: t(item.done ? "purchases.shopping.untick" : "purchases.shopping.tick"))
      )
      .accessibilityIdentifier("purchases.shopping.tick")
      VStack(alignment: .leading, spacing: PurchasesMetrics.lineGap) {
        Text(verbatim: item.name)
          .appFont(PurchasesType.title(design))
          .foregroundStyle(item.done ? theme.contentSecondary : theme.contentPrimary)
          .lineLimit(1)
        if let note = item.note {
          Text(verbatim: note)
            .appFont(PurchasesType.detail(design))
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, PurchasesMetrics.rowHorizontal(design))
    .padding(.vertical, PurchasesMetrics.rowVertical(design))
    .contentShape(.rect)
    .contextMenu {
      Button(t("purchases.shopping.remove")) {
        if let dependencies { report(PurchaseActions(dependencies).deleteShopping(item.id)) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: Text(verbatim: t("purchases.shopping.remove"))) {
      if let dependencies { report(PurchaseActions(dependencies).deleteShopping(item.id)) }
    }
  }

  private var design: LayoutIdiom { LayoutIdiom.resolved(idiom) }
}
