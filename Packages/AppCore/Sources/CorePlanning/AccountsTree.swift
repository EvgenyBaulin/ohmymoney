import CoreAccounting
import CoreKit
import Foundation

/// «Настройки → Счета» as one tree: group → bank → account → card, each row with its money.
///
/// * The groups come in the order of the sidebar (`AccountRules.sidebarSections`); the accounts
///   of no group stand under «Без группы» after them; the hidden accounts under «Скрытые», and
///   the archive last, folded.
/// * Inside a group the accounts stand under their bank; an account whose bank is called as the
///   account itself — «Наличные» — stands right under the group, as the lists name it alone. A
///   bank with no live account is listed under «Без группы», so it can still be found.
/// * A group shows the total of its section, a bank the total of its accounts in that group, an
///   account the balance of its main currency (`AccountsSnapshot`). Money nobody counted shows
///   nothing, never «0».
/// * The rows are given flat, each with its depth (`rows(_:collapsed:query:)`): a folded node
///   hides what is under it; a search keeps the rows whose name holds the words and the rows
///   above them, unfolded.
public enum AccountsTree {
  /// What a row stands for.
  public enum Kind: Hashable, Sendable {
    case group(AccountGroup)
    /// «Без группы»: the accounts of no group, and the banks with no live account.
    case noGroup
    /// A bank inside a group (`nil`: «Без группы»).
    case bank(Bank, group: UUID?)
    case account(PaymentMethod)
    case card(PaymentCard)
    /// «Скрытые»: the hidden accounts.
    case hidden
    /// «Архив»: the archived accounts, groups and banks.
    case archive
    case archivedGroup(AccountGroup)
    case archivedBank(Bank)
  }

  /// One node of the tree.
  public struct Node: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: Kind
    public var children: [Node]
    /// The money of the node in rubles (a group, a bank) or in `currency` (an account).
    public var amount: AmountE4?
    /// The currency of `amount` for an account; `nil`: rubles of a total.
    public var currency: CurrencyCode?
    /// The total of a group holds money of a hidden account while those are covered: the row
    /// says «часть скрыта», never how much.
    public var partHidden = false

    public init(
      id: String, kind: Kind, children: [Node] = [], amount: AmountE4? = nil,
      currency: CurrencyCode? = nil
    ) {
      self.id = id
      self.kind = kind
      self.children = children
      self.amount = amount
      self.currency = currency
    }

    /// The name the search looks in.
    public var name: String {
      switch kind {
      case .group(let group), .archivedGroup(let group): group.name
      case .bank(let bank, _), .archivedBank(let bank): bank.name
      case .account(let account): account.name
      case .card(let card): ([card.name] + card.aliases).joined(separator: " ")
      case .noGroup, .hidden, .archive: ""
      }
    }

    /// The account the node is, if it is one.
    public var account: PaymentMethod? {
      if case .account(let account) = kind { return account }
      return nil
    }

    /// Accounts under it, itself included, at any depth.
    public var accounts: [PaymentMethod] {
      (account.map { [$0] } ?? []) + children.flatMap(\.accounts)
    }
  }

  /// A row as the list draws it.
  public struct Row: Identifiable, Hashable, Sendable {
    public var node: Node
    public var depth: Int
    /// The node has rows under it.
    public var isFolder: Bool
    /// It is folded: the rows under it are not shown.
    public var isFolded: Bool
    /// The group the row is in: `nil` for «Без группы» and what is outside the groups.
    public var groupId: UUID?
    /// The row is inside a group or «Без группы» — a place an account can be dragged to.
    public var takesAccounts: Bool

    public var id: String { node.id }
  }

  // MARK: Building

  /// The tree of `accounts`, `groups`, `banks` and `cards`, with the money of `snapshot`. While
  /// the hidden accounts are covered `snapshot` is the covered one — no balance of a hidden
  /// account — and `partHidden` names the groups (`nil`: no group) whose total holds their money.
  public static func build(
    accounts: [PaymentMethod], groups: [AccountGroup], banks: [Bank], cards: [PaymentCard],
    snapshot: AccountsSnapshot?, partHidden: Set<UUID?> = [], locale: Locale
  ) -> [Node] {
    let live = accounts.filter { !$0.archived }
    let shown = live.filter { !$0.hidden }
    let sections = AccountRules.sidebarSections(accounts: shown, groups: groups, locale: locale)
    let lines = Dictionary(
      (snapshot?.sections.flatMap(\.accounts) ?? []).map { ($0.account.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let totals = Dictionary(
      (snapshot?.sections ?? []).compactMap { section in
        section.group.map { ($0.id, section.totalRub) }
      }, uniquingKeysWith: { first, _ in first })
    let banksById = Dictionary(banks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    func accountNode(_ account: PaymentMethod) -> Node {
      let line = lines[account.id]
      let main = line?.keys.first { $0.key.currency == account.mainCurrency }
      return Node(
        id: "a:\(account.id.uuidString)", kind: .account(account),
        children: CardRules.ordered(cards, of: account.id, locale: locale).map {
          Node(id: "c:\($0.id.uuidString)", kind: .card($0))
        },
        amount: main?.balance, currency: account.mainCurrency)
    }

    /// The accounts of one section, under their banks.
    func underBanks(_ members: [PaymentMethod], group: UUID?) -> [Node] {
      var nodes: [Node] = []
      var seen: [UUID: Int] = [:]
      for account in members {
        guard let bankId = account.bankId, let bank = banksById[bankId],
          !Self.isNamedAsItsBank(account, bank)
        else {
          nodes.append(accountNode(account))
          continue
        }
        if let index = seen[bankId] {
          nodes[index].children.append(accountNode(account))
        } else {
          seen[bankId] = nodes.count
          nodes.append(
            Node(
              id: "b:\(group?.uuidString ?? "none"):\(bankId.uuidString)",
              kind: .bank(bank, group: group), children: [accountNode(account)]))
        }
      }
      for index in seen.values {
        let amounts = nodes[index].children.compactMap { child in
          child.account.flatMap { lines[$0.id]?.totalRub }
        }
        nodes[index].amount = amounts.isEmpty ? nil : amounts.reduce(.zero, +)
      }
      return nodes
    }

    var nodes: [Node] = []
    var loose: [PaymentMethod] = []
    for section in sections {
      guard let group = section.group else {
        loose = section.accounts
        continue
      }
      var node = Node(
        id: "g:\(group.id.uuidString)", kind: .group(group),
        children: underBanks(section.accounts, group: group.id),
        amount: totals[group.id] ?? nil)
      node.partHidden = partHidden.contains(group.id)
      nodes.append(node)
    }
    // Live groups with no shown account are listed too: an empty group is still the owner's.
    let listed = Set(sections.compactMap(\.group?.id))
    for group in groups.filter({ !$0.archived && !listed.contains($0.id) })
      .sorted(by: { AccountRules.groupPrecedes($0, $1, locale: locale) })
    {
      nodes.append(Node(id: "g:\(group.id.uuidString)", kind: .group(group)))
    }
    let banksInUse = Set(live.compactMap(\.bankId))
    let idleBanks = BankRules.ordered(banks, locale: locale).filter { !banksInUse.contains($0.id) }
    if !loose.isEmpty || !idleBanks.isEmpty {
      var children = underBanks(loose, group: nil)
      children += idleBanks.map {
        Node(id: "b:none:\($0.id.uuidString)", kind: .bank($0, group: nil))
      }
      let amounts = loose.compactMap { lines[$0.id]?.totalRub }
      nodes.append(
        Node(
          id: "g:none", kind: .noGroup, children: children,
          amount: amounts.isEmpty ? nil : amounts.reduce(.zero, +)))
    }
    let hidden = AccountRules.ordered(live.filter(\.hidden), locale: locale)
    if !hidden.isEmpty {
      nodes.append(Node(id: "hidden", kind: .hidden, children: hidden.map(accountNode)))
    }
    let archivedAccounts = AccountRules.ordered(
      accounts.filter(\.archived), locale: locale, includeArchived: true)
    let archivedGroups = groups.filter(\.archived)
      .sorted { AccountRules.groupPrecedes($0, $1, locale: locale) }
    let archivedBanks = banks.filter(\.archived)
      .sorted { BankRules.precedes($0, $1, locale: locale) }
    if !archivedAccounts.isEmpty || !archivedGroups.isEmpty || !archivedBanks.isEmpty {
      nodes.append(
        Node(
          id: "archive", kind: .archive,
          children: archivedGroups.map {
            Node(id: "ag:\($0.id.uuidString)", kind: .archivedGroup($0))
          }
            + archivedBanks.map { Node(id: "ab:\($0.id.uuidString)", kind: .archivedBank($0)) }
            + archivedAccounts.map {
              Node(id: "a:\($0.id.uuidString)", kind: .account($0), currency: $0.mainCurrency)
            }))
    }
    return nodes
  }

  /// An account is named as its own bank — «Наличные», a bank of one account made with it — and
  /// the tree shows it alone, as the lists do.
  public static func isNamedAsItsBank(_ account: PaymentMethod, _ bank: Bank) -> Bool {
    fold(account.name) == fold(bank.name)
  }

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The nodes folded when the settings open: the hidden accounts and the archive.
  public static let foldedAtFirst: Set<String> = ["hidden", "archive"]

  // MARK: Rows

  /// The rows on screen: `collapsed` nodes hide their children; `query` keeps the rows whose
  /// name holds every word of it, the rows above them and, under a match, everything — unfolded.
  public static func rows(_ nodes: [Node], collapsed: Set<String>, query: String = "") -> [Row] {
    let words = fold(query).split(separator: " ").map(String.init)
    var rows: [Row] = []
    func matches(_ node: Node) -> Bool {
      let name = fold(node.name)
      return !words.isEmpty && words.allSatisfy { name.contains($0) }
    }
    func keeps(_ node: Node) -> Bool {
      words.isEmpty || matches(node) || node.children.contains(where: keeps)
    }
    func walk(_ node: Node, depth: Int, group: UUID?, inGroups: Bool, all: Bool) {
      guard all || keeps(node) else { return }
      var groupId = group
      var takes = inGroups
      switch node.kind {
      case .group(let found):
        groupId = found.id
        takes = true
      case .noGroup:
        groupId = nil
        takes = true
      case .hidden, .archive:
        takes = false
      default: break
      }
      let folded = words.isEmpty && collapsed.contains(node.id) && !node.children.isEmpty
      rows.append(
        Row(
          node: node, depth: depth, isFolder: !node.children.isEmpty, isFolded: folded,
          groupId: groupId, takesAccounts: takes))
      guard !folded else { return }
      let showsAll = all || matches(node)
      for child in node.children {
        walk(child, depth: depth + 1, group: groupId, inGroups: takes, all: showsAll)
      }
    }
    for node in nodes { walk(node, depth: 0, group: nil, inGroups: false, all: words.isEmpty) }
    return rows
  }

  /// Every node that has rows under it: «Свернуть всё» folds them, «Развернуть всё» empties it.
  public static func folders(_ nodes: [Node]) -> Set<String> {
    var found: Set<String> = []
    func walk(_ node: Node) {
      guard !node.children.isEmpty else { return }
      found.insert(node.id)
      node.children.forEach(walk)
    }
    nodes.forEach(walk)
    return found
  }

  // MARK: Dragging

  /// Where an account dropped among `rows` goes: the group of the row above the gap — the row
  /// below it when dropped at the very top — and its place among the live accounts in the
  /// order of the rows. `nil`: not a place for an account (the hidden ones, the archive), or
  /// not an account.
  public struct Drop: Hashable, Sendable {
    public var accountId: UUID
    /// The group it goes to; `nil`: no group.
    public var groupId: UUID?
    /// Every live account shown in the groups, in the order after the drop.
    public var order: [UUID]
  }

  /// `source` and `destination` in the terms of `onMove` over `rows`.
  public static func drop(_ rows: [Row], from source: Int, to destination: Int) -> Drop? {
    guard rows.indices.contains(source), let account = rows[source].node.account,
      !account.archived, rows[source].takesAccounts
    else { return nil }
    // The row the gap follows, the dragged row left out of the count.
    let others = rows.enumerated().filter { $0.offset != source }.map(\.element)
    let gap = destination > source ? destination - 1 : destination
    let anchor = gap > 0 ? others[min(gap, others.count) - 1] : others.first
    guard let anchor, anchor.takesAccounts else { return nil }
    let groupId = anchor.groupId
    var order = others.compactMap { row -> UUID? in
      guard row.takesAccounts, let found = row.node.account, !found.archived else { return nil }
      return found.id
    }
    // The dragged account goes after the last account at or above the gap.
    let above = others.prefix(gap).compactMap { row -> UUID? in
      guard row.takesAccounts, let found = row.node.account, !found.archived else { return nil }
      return found.id
    }
    let place = above.last.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    order.insert(account.id, at: place)
    return Drop(accountId: account.id, groupId: groupId, order: order)
  }
}
