import AppCore
import SwiftUI

/// Which half of the debts overview is shown.
enum DebtsTab: Hashable { case iOwe, owedToMe }

/// The debts overview when no debt is chosen: «Я должен · N» / «Мне должны · N» tabs over cards.
/// «Мне должны» shows a card per person (the total, how many debts) — a click opens the person.
struct DebtOverviewPane: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let overview: DebtsOverview
  let people: [Person]
  @Binding var tab: DebtsTab
  /// The credit cards in debt: shown under the debts I owe, in no total.
  var cardDebts: [CreditCardDebtLine] = []
  let ladderAvailable: Bool
  let select: (DebtsSelection) -> Void
  let delete: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Picker("", selection: $tab) {
            Text(verbatim: "\(t("debts.iOwe")) · \(overview.iOwe.count + cardDebts.count)")
              .tag(DebtsTab.iOwe)
            Text(verbatim: "\(t("debts.owedToMe")) · \(overview.owedToMe.count)")
              .tag(DebtsTab.owedToMe)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 360)
          .accessibilityIdentifier("debts.tabs")
          Spacer()
          if ladderAvailable {
            Button(t("ladder.title")) { select(.ladder) }
              .accessibilityIdentifier("debts.ladder")
          }
        }
        switch tab {
        case .iOwe:
          DebtCardGrid(
            lines: overview.iOwe.map(DebtCardModel.init),
            closed: overview.closed.map(DebtCardModel.init),
            open: { select(.debt($0)) }, delete: delete)
          CreditCardDebtCards(lines: cardDebts, open: { select(.card($0)) })
        case .owedToMe:
          if overview.owedToMe.isEmpty {
            Text(verbatim: t("debts.nobodyOwes")).foregroundStyle(.secondary)
          }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 14)],
            alignment: .leading, spacing: 14
          ) {
            ForEach(overview.owedToMe, id: \.personId) { personCard($0) }
          }
        }
      }
      .padding(20)
    }
  }

  private func personCard(_ group: OwedToMeGroup) -> some View {
    let name = people.first { $0.id == group.personId }?.name ?? t("debts.noPerson")
    return Button {
      select(.person(group.personId))
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Label(name, systemImage: "person.crop.circle")
          .appFont(.headline).lineLimit(1)
        Text(verbatim: environment.money.rounded(group.totalRub))
          .appFont(.title2.monospacedDigit().weight(.semibold))
        if let oldest = group.oldest {
          Text(verbatim: environment.dates.dayAndMonth(oldest))
            .appFont(.caption).foregroundStyle(surfaces.secondary)
        }
      }
      .contentShape(Rectangle())
      .contentCard()
    }
    .buttonStyle(.plain)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
