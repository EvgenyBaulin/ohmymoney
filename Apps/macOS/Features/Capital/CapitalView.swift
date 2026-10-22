import AppCore
import SwiftUI

/// «Капитал»: what the owner has less what they owe, how it moved, what it is made of, the
/// assets valued by hand, and the safety cushion. Every figure is the core's (`NetWorth`,
/// `CushionRules`), built in the data step's snapshot; the view only lays it out.
struct CapitalView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// A row of an account clicked in the breakdown: the window opens the account's screen. Without
  /// it the click is posted as `.capitalOpensAccount`.
  var openAccount: ((UUID) -> Void)?
  @State private var sheet: CapitalSheet?
  /// The asset «Удалить…» asks about.
  @State private var deleting: Asset?
  /// Why the last action on an asset did not land, as a key of the Capital table.
  @State private var refusal: String?

  init(openAccount: ((UUID) -> Void)? = nil) {
    self.openAccount = openAccount
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          titleLine
          if let snapshot = compute.snapshot {
            let model = CapitalViewModel(
              capital: snapshot.planning.capital, accountGroups: snapshot.dataset.accountGroups,
              debts: snapshot.dataset.debts)
            columns(
              count: ScreenColumns.count(forWidth: proxy.size.width - 40),
              left: [
                AnyView(header),
                AnyView(CurrencyGainSection(snapshot: snapshot)),
                AnyView(CapitalBreakdownSection(model: model, open: open)),
                AnyView(
                  AssetsSection(
                    assets: snapshot.dataset.assets, valuations: snapshot.dataset.assetValuations,
                    sheet: $sheet, deleting: $deleting)),
              ],
              right: [
                AnyView(CapitalChartSection(model: model)),
                AnyView(CushionSection(status: snapshot.planning.cushion)),
              ])
          } else {
            ComputedBlock(
              waiting: compute.states.data.flatMap { _, _ -> BlockState<Never> in .calculating },
              retry: { compute.retry(ComputeStep.data) })
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityIdentifier("capital.screen")
    .sheet(item: $sheet) { sheet in
      sheetView(sheet).handingOver(dependencies)
    }
    .confirmationDialog(
      CapitalText.format("capital.assets.delete.title", environment, deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting, let dependencies {
          refusal = CapitalText.refusalKey(AssetActions(dependencies).delete(deleting))
        }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: CapitalText.t("capital.assets.delete.message", environment))
    }
    .alert(
      refusal.map { CapitalText.t($0, environment) } ?? "",
      isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    ) {
      Button(environment.language("action.ok")) { refusal = nil }
    }
  }

  /// The page title and its one-line subtitle.
  private var titleLine: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: CapitalText.t("capital.title", environment))
        .appFont(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      Text(verbatim: CapitalText.t("capital.subtitle", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Two columns on a wide window — the figure and what it is made of on the left, how it moved
  /// and the cushion on the right — and one column, in that order, on a narrow one.
  @ViewBuilder
  private func columns(count: Int, left: [AnyView], right: [AnyView]) -> some View {
    if count == 2 {
      HStack(alignment: .top, spacing: 16) {
        column(left)
        column(right)
      }
    } else {
      column(left + right)
    }
  }

  private func column(_ cards: [AnyView]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(cards.enumerated()), id: \.offset) { _, card in card }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  /// The hero card: «Капитал 2 184 300 ₽» and how it moved since the end of last month — an
  /// arrow and a sign, never the colour of good or bad: more debt can be a flat bought — and
  /// what is had and what is owed.
  private var header: some View {
    ScreenHero(
      caption: CapitalText.t("capital.title", environment),
      figure: compute.snapshot.map { environment.money.rounded($0.planning.capital.now.netRub) }
        ?? "—",
      lines: heroLines, figureIdentifier: "capital.net")
  }

  private var heroLines: [String] {
    guard let capital = compute.snapshot?.planning.capital else { return [] }
    let model = CapitalViewModel(capital: capital)
    var lines: [String] = []
    if let change = model.change, let since = model.sinceMonth {
      lines.append(
        (change.isNegative ? "↓ " : "↑ ") + environment.money.signedRounded(change) + " "
          + CapitalText.since(since, environment))
    }
    lines.append(
      CapitalText.format(
        "capital.hero.haveOwe", environment, environment.money.rounded(capital.now.haveRub),
        environment.money.rounded(capital.now.iOweRub)))
    return lines
  }

  @ViewBuilder
  private func sheetView(_ sheet: CapitalSheet) -> some View {
    switch sheet {
    case .newAsset: AssetEditor(original: nil)
    case .edit(let asset): AssetEditor(original: asset)
    case .value(let asset): AssetValuationSheet(asset: asset)
    case .history(let asset): AssetHistorySheet(asset: asset)
    case .dispose(let asset): AssetDisposalSheet(asset: asset)
    }
  }

  /// A row of the breakdown clicked: an account opens its screen, a debt the section «Долги»
  /// with it chosen, an asset its editor.
  private func open(_ source: CapitalLine.Source) {
    switch source {
    case .account(let id):
      if let openAccount {
        openAccount(id)
      } else {
        NotificationCenter.default.post(name: .capitalOpensAccount, object: id)
      }
    case .debt(let id):
      // «Долги» is built only after the switch, so it reads the debt when it appears.
      DebtsView.debtToOpen = id
      NotificationCenter.default.post(
        name: .selectSection, object: MainWindow.Section.debts.shortcutIndex)
      NotificationCenter.default.post(name: .capitalOpensDebt, object: id)
    case .asset(let id):
      if let asset = compute.snapshot?.dataset.assets.first(where: { $0.id == id }) {
        sheet = .edit(asset)
      }
    }
  }
}

extension Notification.Name {
  /// A row of an account clicked on «Капитал»; the object is the account's id.
  static let capitalOpensAccount = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.capitalOpensAccount")
  /// A row of a debt clicked on «Капитал»; the object is the debt's id.
  static let capitalOpensDebt = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.capitalOpensDebt")
}

/// The sheets of «Капитал», one at a time on the root of the screen: the rows are redrawn with
/// every change of the data, and a sheet hung on one would go with it.
enum CapitalSheet: Identifiable, Hashable {
  case newAsset
  case edit(Asset)
  case value(Asset)
  case history(Asset)
  case dispose(Asset)

  var id: String {
    switch self {
    case .newAsset: "new"
    case .edit(let asset): "edit.\(asset.id)"
    case .value(let asset): "value.\(asset.id)"
    case .history(let asset): "history.\(asset.id)"
    case .dispose(let asset): "dispose.\(asset.id)"
    }
  }
}

// MARK: - The model of the screen

/// What «Капитал» lays out, worked out from the snapshot of the core without a word of text:
/// the figures of the header, the groups of the two columns with each row's share of its
/// column, and the warnings.
struct CapitalViewModel: Hashable {
  /// One row of the breakdown and its share of its column, in basis points; `nil` while it adds
  /// nothing or is below zero.
  struct Row: Hashable, Identifiable {
    var line: CapitalLine
    var shareBp: Int?

    var id: String {
      switch line.source {
      case .account(let id): "account.\(id).\(line.currency.code)"
      case .asset(let id): "asset.\(id)"
      case .debt(let id): "debt.\(id)"
      }
    }
  }

  /// A block of a column: «Счета в сводке», one group left out of the summary, one kind of
  /// property, «Мне должны», the debts.
  struct Group: Hashable, Identifiable {
    var kind: CapitalLine.Group
    /// The group left out of the summary, for `.outOfSummary`.
    var accountGroupId: UUID?
    /// Its name, when the group is still there.
    var accountGroupName: String?
    /// The kind of property, for `.assets`.
    var assetKind: AssetKind?
    var rows: [Row]
    /// What the rows add up to, in rubles.
    var totalRub: AmountE4
    /// The block's share of its column: the shares of its rows added up, so the folded row and
    /// its rows never disagree; `nil` while no row of it has a share.
    var shareBp: Int?

    var id: String {
      [kind.rawValue, accountGroupId?.uuidString, assetKind?.rawValue]
        .compactMap { $0 }.joined(separator: ".")
    }
  }

  /// The names of the rows that add nothing for one reason.
  struct Warning: Hashable {
    var issue: CapitalLine.Issue
    var names: [String]
  }

  var net: AmountE4
  var have: AmountE4
  var owe: AmountE4
  /// Net worth now less at the end of last month.
  var change: AmountE4?
  /// The month whose end `change` is counted from.
  var sinceMonth: MonthKey?
  var haveGroups: [Group]
  var oweGroups: [Group]
  var warnings: [Warning]
  /// Debts I owe named like an account below zero: the same credit card kept twice, once as an
  /// account and once as a debt, and its money taken off twice.
  var countedTwice: [String]
  /// The points of the chart, oldest first, «now» last.
  var points: [CapitalPoint]

  /// Nothing counted at all: no account, no asset, no debt.
  var isEmpty: Bool { haveGroups.isEmpty && oweGroups.isEmpty }

  /// The order of the blocks of «Что есть».
  static let haveOrder: [CapitalLine.Group] = [
    .accounts, .deposits, .outOfSummary, .assets, .owedToMe,
  ]

  init(capital: CapitalSnapshot, accountGroups: [AccountGroup] = [], debts: [Debt] = []) {
    let now = capital.now
    net = now.netRub
    have = now.haveRub
    owe = now.iOweRub
    change = capital.changeThisMonth
    points = capital.points
    let ends = capital.points.filter { !$0.isNow }
    sinceMonth = capital.changeThisMonth == nil ? nil : ends.last?.day.monthKey
    let names = Dictionary(
      accountGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    haveGroups = Self.groups(
      capital.breakdown.have, order: Self.haveOrder, groupNames: names)
    oweGroups = Self.groups(capital.breakdown.owe, order: [.iOwe], groupNames: names)
    let lines = capital.breakdown.have + capital.breakdown.owe
    warnings = [CapitalLine.Issue.unanchored, .withoutRate, .unvalued].compactMap { issue in
      let named = lines.filter { $0.issue == issue }.map(\.name)
      return named.isEmpty ? nil : Warning(issue: issue, names: Self.unique(named))
    }
    countedTwice = Self.countedTwice(capital.breakdown, debts: debts)
  }

  /// The lines of one column in blocks, in `order`; inside a block they keep the core's order.
  /// The shares are of the whole column, so the rows of «Что есть» add up to 100 %.
  static func groups(
    _ lines: [CapitalLine], order: [CapitalLine.Group], groupNames: [UUID: String]
  ) -> [Group] {
    let shares = Shares.basisPoints(lines.map { $0.amountRub ?? .zero })
    let rows = zip(lines, shares).map { line, share in
      Row(line: line, shareBp: line.amountRub == nil ? nil : share)
    }
    var result: [Group] = []
    for kind in order {
      let ofKind = rows.filter { $0.line.group == kind }
      switch kind {
      case .outOfSummary:
        for id in unique(ofKind.map(\.line.accountGroupId)) {
          let inGroup = ofKind.filter { $0.line.accountGroupId == id }
          result.append(
            group(kind, inGroup, accountGroupId: id, name: id.flatMap { groupNames[$0] }))
        }
      case .assets:
        for assetKind in AssetKind.allCases {
          let inKind = ofKind.filter { $0.line.assetKind == assetKind }
          guard !inKind.isEmpty else { continue }
          result.append(group(kind, inKind, assetKind: assetKind))
        }
        let unknown = ofKind.filter { $0.line.assetKind == nil }
        if !unknown.isEmpty { result.append(group(kind, unknown, assetKind: .other)) }
      default:
        if !ofKind.isEmpty { result.append(group(kind, ofKind)) }
      }
    }
    return result
  }

  private static func group(
    _ kind: CapitalLine.Group, _ rows: [Row], accountGroupId: UUID? = nil, name: String? = nil,
    assetKind: AssetKind? = nil
  ) -> Group {
    Group(
      kind: kind, accountGroupId: accountGroupId, accountGroupName: name, assetKind: assetKind,
      rows: rows, totalRub: rows.reduce(.zero) { $0 + ($1.line.amountRub ?? .zero) },
      shareBp: rows.contains { $0.shareBp != nil }
        ? rows.reduce(0) { $0 + ($1.shareBp ?? 0) } : nil)
  }

  /// The debts I owe of a credit card named like an account below zero, by the folded name.
  static func countedTwice(_ breakdown: CapitalBreakdown, debts: [Debt]) -> [String] {
    let cards = Set(debts.filter { $0.type == .creditCard }.map(\.id))
    let belowZero = Set(
      breakdown.have.compactMap { line -> String? in
        guard case .account = line.source, let amount = line.amount, amount.isNegative else {
          return nil
        }
        return NameKey.fold(line.name)
      })
    return unique(
      breakdown.owe.compactMap { line in
        guard case .debt(let id) = line.source, cards.contains(id),
          belowZero.contains(NameKey.fold(line.name))
        else { return nil }
        return line.name
      })
  }

  /// The elements in the order they first come, each once.
  static func unique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
  }
}

// MARK: - Words

/// The words of «Капитал», shared by its sections, its sheets and its tile.
@MainActor
enum CapitalText {
  static let table = "Capital"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// «с конца сентября»: the month a change is counted from, in the case the language needs.
  static func since(_ month: MonthKey, _ environment: AppEnvironment) -> String {
    environment.language("capital.since.\(month.month)", table: table)
  }

  /// The arrow of a change by the sign of its whole rubles: up, down or level.
  static func arrow(of change: AmountE4) -> String {
    let whole = change.wholeRubles
    return whole > 0 ? "arrow.up.right" : whole < 0 ? "arrow.down.right" : "arrow.right"
  }

  /// The words of a kind of property.
  static func kindKey(_ kind: AssetKind) -> String { "capital.assetKind.\(kind.rawValue)" }

  /// A symbol for a kind of property, beside its name — never the only thing that tells it.
  static func kindSymbol(_ kind: AssetKind) -> String {
    switch kind {
    case .vehicle: "car"
    case .realty: "house"
    case .equipment: "desktopcomputer"
    case .investment: "chart.line.uptrend.xyaxis"
    case .other: "shippingbox"
    }
  }

  /// Why an action on the assets did not land, as a key of the table; `nil` when it did.
  static func refusalKey(_ outcome: AssetActionOutcome) -> String? {
    switch outcome {
    case .done: nil
    case .refused(.emptyName): "capital.refusal.emptyName"
    case .refused(.negativeValue): "capital.refusal.negativeValue"
    case .refused(.notFound): "capital.refusal.notFound"
    case .failed: "capital.refusal.failed"
    }
  }
}
