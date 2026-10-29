import AppCore
import SwiftUI

/// The sheets of the screens of the purchases.
enum PurchasesSheet: Identifiable, Hashable {
  case newWish
  case editWish(Wish)
  case price(Wish)
  case bought(Wish)
  case newThing
  case editThing(OwnedItem)
  case sell(OwnedLine)
  case postpone(WaitingRefund)

  var id: String {
    switch self {
    case .newWish: "wish.new"
    case .editWish(let wish): "wish.edit.\(wish.id)"
    case .price(let wish): "wish.price.\(wish.id)"
    case .bought(let wish): "wish.bought.\(wish.id)"
    case .newThing: "thing.new"
    case .editThing(let item): "thing.edit.\(item.id)"
    case .sell(let line): "thing.sell.\(line.id)"
    case .postpone(let refund): "waiting.postpone.\(refund.id)"
    }
  }
}

/// Which page of the purchases is on view. A line of «Стоит посмотреть» sets `page` and then asks
/// for the section (`.selectSection` with `MainWindow.Section.purchases.shortcutIndex`), so the
/// screen opens on the page the line is about even when it was not built yet.
@MainActor
@Observable
final class PurchasesNavigation {
  static let shared = PurchasesNavigation()

  var page: PurchasesText.Page = .wishes
}

/// «Покупки»: what the owner wants to buy and what the price of it does, the shopping list, the
/// things kept and what they cost to keep, the refunds still waited for, and what the discounts
/// saved. One screen, five pages behind a switch; the figures are the core's (`PurchasesPage`,
/// built off the main thread from the snapshot), the writes are `PurchaseActions`.
struct PurchasesScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.themeSurfaces) private var surfaces
  @State private var page: PurchasesPage?
  @State private var selected: PurchasesText.Page
  @State private var sheet: PurchasesSheet?
  /// Why the last action did not land, in words.
  @State private var refusal: String?

  init() {
    _selected = State(initialValue: PurchasesNavigation.shared.page)
  }

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitleBlock(
          title: t("purchases.title"), subtitle: t("purchases.subtitle"),
          identifier: "purchases.title")
        Picker(selection: $selected) {
          ForEach(PurchasesText.Page.allCases) { page in
            Text(verbatim: t(page.titleKey)).tag(page)
          }
        } label: {
          Text(verbatim: t("purchases.title"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("purchases.pages")
        if let refusal {
          Label {
            Text(verbatim: refusal).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .appFont(.callout)
          .contentCard()
          .accessibilityIdentifier("purchases.refusal")
        }
        content
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(surfaces.background)
    .task(id: compute.generation) { await load() }
    .onChange(of: PurchasesNavigation.shared.page) { _, page in selected = page }
    .onChange(of: selected) { _, page in PurchasesNavigation.shared.page = page }
    .sheet(item: $sheet) { sheet in
      sheetView(sheet).handingOver(dependencies)
    }
    .accessibilityIdentifier("purchases.screen")
  }

  @ViewBuilder
  private var content: some View {
    if let page, let snapshot = compute.snapshot {
      switch selected {
      case .wishes:
        WishesPage(page: page, open: { sheet = $0 }, report: report)
      case .shopping:
        ShoppingPage(page: page, report: report)
      case .things:
        ThingsPage(page: page, open: { sheet = $0 }, report: report)
      case .waiting:
        WaitingPage(page: page, today: snapshot.today, open: { sheet = $0 }, report: report)
      case .savings:
        SavingsPage(page: page)
      }
    } else {
      ComputedBlock(
        waiting: compute.states.data.flatMap { _, _ -> BlockState<Never> in .calculating },
        retry: { compute.retry(ComputeStep.data) })
    }
  }

  /// Tells the owner why an action wrote nothing; a good outcome clears the word.
  private func report(_ outcome: PurchaseOutcome) {
    switch outcome {
    case .done: refusal = nil
    case .refused(let why): refusal = PurchasesText.refusal(why, environment)
    case .failed: refusal = t("purchases.refusal.failed")
    }
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    let canSave = compute.states.forecast.value.map {
      snapshot.planning.canSave(remainder: $0)
    }
    let calendar = environment.calendar
    let built = await Task.detached(priority: .userInitiated) {
      PurchasesPage.build(
        dataset: snapshot.dataset, canSave: canSave, rubPerUnit: snapshot.context.rubPerUnit,
        today: snapshot.today, calendar: calendar, waiting: snapshot.planning.waitingRefunds)
    }.value
    guard !Task.isCancelled else { return }
    page = built
  }

  @ViewBuilder
  private func sheetView(_ sheet: PurchasesSheet) -> some View {
    switch sheet {
    case .newWish: WishEditor(original: nil)
    case .editWish(let wish): WishEditor(original: wish)
    case .price(let wish): WishPriceSheet(wish: wish)
    case .bought(let wish): WishBoughtSheet(wish: wish)
    case .newThing: ThingEditor(original: nil)
    case .editThing(let item): ThingEditor(original: item)
    case .sell(let line): ThingSaleSheet(line: line)
    case .postpone(let refund): WaitingPostponeSheet(refund: refund)
    }
  }
}
