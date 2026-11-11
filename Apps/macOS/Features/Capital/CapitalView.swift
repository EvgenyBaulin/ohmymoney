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

  @Environment(\.layoutIdiom) private var idiom
  @State private var width: CGFloat = 0

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    SectionPage {
      VStack(alignment: .leading, spacing: SectionMetrics.headerToContent) {
        SectionHeader(
          title: CapitalText.t("capital.title", environment),
          subtitle: design == .phone ? CapitalText.t("capital.subtitle", environment) : nil,
          identifier: "capital.title",
          primary: (
            environment.language("operations.new", table: "Transactions"), "capital.newOperation",
            { NotificationCenter.default.post(name: .focusEntryLine, object: nil) }
          ))
        if let snapshot = compute.snapshot {
          page(snapshot, design: design)
        } else {
          ComputedBlock(
            waiting: compute.states.data.flatMap { _, _ -> BlockState<Never> in .calculating },
            retry: { compute.retry(ComputeStep.data) })
        }
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
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

  /// The cards of the frames: on the Mac and a tablet the figure, what it is made of and the
  /// property on the left, the months and the cushion on the right; on a phone one column — the
  /// figure, the months, what it is made of, the cushion, the property. What the frames do not
  /// draw follows them: the currency gain, the insurance of deposits, and the list of everything
  /// had and owed with its clicks.
  @ViewBuilder
  private func page(_ snapshot: DataSnapshot, design: LayoutIdiom) -> some View {
    let model = CapitalViewModel(
      capital: snapshot.planning.capital, accountGroups: snapshot.dataset.accountGroups,
      debts: snapshot.dataset.debts, hiding: snapshot.hiding)
    let hero = AnyView(CapitalHeroCard(model: model))
    let shares = AnyView(CapitalSharesCard(model: model))
    let assets = AnyView(
      CapitalAssetsCard(
        assets: snapshot.dataset.assets, valuations: snapshot.dataset.assetValuations,
        sheet: $sheet, deleting: $deleting))
    let months = AnyView(CapitalMonthsCard(model: model))
    let cushion = AnyView(CapitalCushionCard(status: snapshot.planning.cushion))
    let extras: [AnyView] = [
      AnyView(CurrencyGainSection(snapshot: snapshot)),
      AnyView(
        CapitalInsuranceSection(
          banks: CapitalInsuranceSection.shown(
            snapshot.planning.banks.insurance,
            accounts: snapshot.ledger.dataset.paymentMethods, hiding: snapshot.hiding))),
      AnyView(
        CapitalBreakdownSection(
          model: model, open: open, title: CapitalText.t("capital.details.title", environment))),
    ]
    if CapitalLayout.columns(forContent: width, idiom: design) == 2 {
      let widths = CapitalLayout.columnWidths(forContent: width, idiom: design)
      HStack(alignment: .top, spacing: SectionMetrics.columnGap(design)) {
        column([hero, shares, assets] + extras)
          .frame(width: width > 0 ? widths.0 : nil)
        column([months, cushion])
          .frame(width: width > 0 ? widths.1 : nil)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      column([hero, months, shares, cushion, assets] + extras)
    }
  }

  private func column(_ cards: [AnyView]) -> some View {
    VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
      ForEach(Array(cards.enumerated()), id: \.offset) { _, card in card }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func sheetView(_ sheet: CapitalSheet) -> some View {
    switch sheet {
    case .newAsset: AssetEditor(original: nil)
    case .edit(let asset): AssetEditor(original: asset)
    case .value(let asset): AssetValuationSheet(asset: asset)
    case .history(let asset): AssetHistorySheet(asset: asset)
    case .dispose(let asset): AssetDisposalSheet(asset: asset)
    case .payout(let asset):
      ExpectedIncomeForm(
        original: nil, start: PayoutRules.draft(for: asset, today: environment.today))
    case .showcase: DepositShowcaseSheet()
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
  case payout(Asset)
  case showcase

  var id: String {
    switch self {
    case .payout(let asset): "payout.\(asset.id)"
    case .showcase: "showcase"
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
    /// Rows of covered hidden accounts are not among `rows`; `totalRub` and `shareBp` still
    /// count them, and the block says «часть скрыта».
    var partHidden = false

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
  /// Some line of a covered hidden account is counted and not listed: the figures say «часть
  /// скрыта».
  var partHidden = false

  /// Nothing counted at all: no account, no asset, no debt.
  var isEmpty: Bool { haveGroups.isEmpty && oweGroups.isEmpty }

  /// The order of the blocks of «Что есть».
  static let haveOrder: [CapitalLine.Group] = [
    .accounts, .deposits, .outOfSummary, .assets, .owedToMe,
  ]

  /// `hiding` are the hidden accounts the screen is drawn without while they are covered: their
  /// lines are counted in every figure and listed nowhere, not even by name in a warning.
  init(
    capital: CapitalSnapshot, accountGroups: [AccountGroup] = [], debts: [Debt] = [],
    hiding: HiddenAccounts = HiddenAccounts(ids: [UUID]())
  ) {
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
    let (have, haveCut) = Self.covering(
      Self.groups(capital.breakdown.have, order: Self.haveOrder, groupNames: names),
      hiding: hiding)
    let (owe, oweCut) = Self.covering(
      Self.groups(capital.breakdown.owe, order: [.iOwe], groupNames: names), hiding: hiding)
    haveGroups = have
    oweGroups = owe
    partHidden = haveCut || oweCut
    let shown = CapitalBreakdown(
      have: capital.breakdown.have.filter { !Self.isHidden($0, hiding) },
      owe: capital.breakdown.owe.filter { !Self.isHidden($0, hiding) })
    let lines = shown.have + shown.owe
    warnings = [CapitalLine.Issue.unanchored, .withoutRate, .unvalued].compactMap { issue in
      let named = lines.filter { $0.issue == issue }.map(\.name)
      return named.isEmpty ? nil : Warning(issue: issue, names: Self.unique(named))
    }
    countedTwice = Self.countedTwice(shown, debts: debts)
  }

  /// A line of a hidden account.
  static func isHidden(_ line: CapitalLine, _ hiding: HiddenAccounts) -> Bool {
    if case .account(let id) = line.source { return hiding.isHidden(id) }
    return false
  }

  /// Some line of `capital` is of a hidden account: a figure of it holds hidden money.
  static func touchesHidden(_ capital: CapitalSnapshot, hiding: HiddenAccounts) -> Bool {
    guard !hiding.isEmpty else { return false }
    return (capital.breakdown.have + capital.breakdown.owe).contains { isHidden($0, hiding) }
  }

  /// The blocks without the rows of hidden accounts. A block keeps its total and share, made
  /// before, and says «часть скрыта»; a block left with no row is dropped — its total alone would
  /// give the hidden amount away — except «Счета в сводке», whose money the summary shows anyway.
  static func covering(
    _ groups: [Group], hiding: HiddenAccounts
  ) -> (groups: [Group], removed: Bool) {
    guard !hiding.isEmpty else { return (groups, false) }
    var removed = false
    let kept = groups.compactMap { group -> Group? in
      let rows = group.rows.filter { !isHidden($0.line, hiding) }
      guard rows.count != group.rows.count else { return group }
      removed = true
      guard !rows.isEmpty || group.kind == .accounts else { return nil }
      var covered = group
      covered.rows = rows
      covered.partHidden = true
      return covered
    }
    return (kept, removed)
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
