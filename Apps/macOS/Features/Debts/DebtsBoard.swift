import AppCore
import Foundation

/// The numbers of «Долги» as the design draws them: on the Mac and the iPad three columns — the
/// summary on top, the groups of cards two columns wide and the payoff ladder in the third,
/// stretched to their height; on the phone one column. Every gap and size here is the design's.
enum DebtsMetrics {
  /// The gap between the three tiles of the summary, between two cards side by side and between
  /// the groups and the ladder.
  static let columnGap: CGFloat = 16
  /// Between the title of the screen and the summary.
  static let headerGap: CGFloat = 16
  /// Between the summary and the groups, and between two groups stacked one above the other.
  static let sectionGap: CGFloat = 20
  /// Between the name of a group and its cards.
  static let groupTitleGap: CGFloat = 8

  /// A tile of the summary: 16 of margin, 6 between its lines, the icon 24 round with a 14 pt
  /// symbol, 8 from its words.
  static let summaryPadding: CGFloat = 16
  static let summaryLineGap: CGFloat = 6
  static let summaryIcon: CGFloat = 24
  static let summaryGlyph: CGFloat = 14
  static let summaryIconGap: CGFloat = 8

  /// A card of a debt: 16 of margin and 10 between its parts on the Mac and the iPad, 14 and 8 on
  /// the phone; the icon 32 round with an 18 pt symbol, 10 from the name.
  static let cardPadding: CGFloat = 16
  static let cardGap: CGFloat = 10
  static let phoneCardPadding: CGFloat = 14
  static let phoneCardGap: CGFloat = 8
  static let cardIcon: CGFloat = 32
  static let cardGlyph: CGFloat = 18
  static let cardIconGap: CGFloat = 10

  /// The bar of what is paid: 6 high, rounded 3, 6 under its line of words.
  static let trackHeight: CGFloat = 6
  static let trackRadius: CGFloat = 3
  static let progressGap: CGFloat = 6
  /// The terms under it: three columns 12 apart, 2 between the word and the figure.
  static let termsGap: CGFloat = 12
  static let termLineGap: CGFloat = 2

  /// The phone: 14 between the parts of the page, 12 between two cards of a group; the summary
  /// one card of three lines, 14 of margin and 8 between its lines.
  static let phoneStackGap: CGFloat = 14
  static let phoneCardStackGap: CGFloat = 12
  static let phoneSummaryPadding: CGFloat = 14
  static let phoneSummaryGap: CGFloat = 8

  /// The card of the ladder: 16 of margin and 12 between its parts on the Mac and the iPad, 12
  /// and 6 on the phone.
  static let ladderPadding: CGFloat = 16
  static let ladderGap: CGFloat = 12
  static let phoneLadderPadding: CGFloat = 12
  static let phoneLadderGap: CGFloat = 6
  /// A step on the Mac: the number on a white plate, 12 × 5 rounded 8, and the words beside it
  /// in the grey track, 3 round it, rounded 10; 1 between the two lines of words.
  static let macStepInset: CGFloat = 3
  static let macStepRadius: CGFloat = 10
  static let macStepHorizontal: CGFloat = 12
  static let macStepVertical: CGFloat = 5
  static let macStepPlateRadius: CGFloat = 8
  /// A step on the iPad and the phone: a row 10 × 5 rounded 8, the number in a 22 pt accent
  /// circle 10 from the words.
  static let stepHorizontal: CGFloat = 10
  static let stepVertical: CGFloat = 5
  static let stepRadius: CGFloat = 8
  static let stepNumber: CGFloat = 22
  static let stepGap: CGFloat = 10
  /// Between two lines of the result («Свободны от долгов», «Экономия на процентах»).
  static let resultGap: CGFloat = 6

  /// Below this width the page is the phone's: one column.
  static let phoneWidth: CGFloat = 600

  /// The width of one of the three columns of a page `width` wide.
  static func column(in width: CGFloat) -> CGFloat {
    max((width - 2 * columnGap) / 3, 0)
  }
}

/// What «Долги» shows when no debt is open: the summary, the groups of cards and the ladder —
/// all of it worked out of the data on screen, without a view, so a test reads it as the screen
/// does. Balances live here and in «Капитал» only: nothing of it reaches Overview.
struct DebtsBoard: Equatable {
  struct Summary: Equatable {
    var iOwe: AmountE4
    /// The open debts I owe.
    var iOweCount: Int
    var monthly: AmountE4
    /// The nearest due of a debt I owe.
    var nextPayment: DateOnly?
    var owedToMe: AmountE4
    /// The people who owe me (the parts that name nobody count as one).
    var peopleCount: Int
  }

  enum GroupKind: String, Equatable, CaseIterable {
    case iOwe, owedToMe, instalments, closed
  }

  /// A card of the board: a debt, a person who owes me, or a closed debt.
  struct Card: Identifiable, Equatable {
    enum Kind: Equatable {
      case debt(DebtCardModel.Badge)
      case person
    }

    let selection: DebtsSelection
    let kind: Kind
    let name: String
    let amount: AmountE4
    let currency: CurrencyCode
    /// Paid back (a debt I owe) or returned (owed to me): the share in whole percent and the two
    /// figures, in `progressCurrency`.
    let percent: Int?
    let paid: AmountE4?
    let total: AmountE4?
    let progressCurrency: CurrencyCode
    let rate: Decimal?
    let payment: AmountE4?
    let nextDue: DateOnly?
    /// The debt «Удалить…» of the context menu deletes; a person has none.
    let debtId: UUID?

    var id: DebtsSelection { selection }

    /// The symbol of the kind: never alone, the label beside it says it in words.
    var symbol: String {
      switch kind {
      case .person: "person.2"
      case .debt(.instalment): "calendar"
      case .debt(.purchase): "creditcard"
      case .debt(.existing): "house"
      case .debt(.closed): "checkmark.circle"
      }
    }

    /// The key of the words of the label at the right of the name.
    var labelKey: String {
      switch kind {
      case .person: "debts.badge.owedToMe"
      case .debt(let badge): badge.key
      }
    }

    /// «Выплачено» for a debt I owe, «Возвращено» for money owed to me.
    var progressKey: String {
      kind == .person ? "debts.card.returnedShare" : "debts.card.paidShare"
    }
  }

  struct Group: Identifiable, Equatable {
    let kind: GroupKind
    let cards: [Card]
    var id: GroupKind { kind }
  }

  /// One row of the groups: a group across the whole width, or two groups of one card each side
  /// by side («Мне должны · 1» beside «Рассрочки · 1»).
  struct Row: Identifiable, Equatable {
    let groups: [Group]
    var id: [GroupKind] { groups.map(\.kind) }
  }

  var summary: Summary
  var groups: [Group]

  init(overview: DebtsOverview, people: [Person]) {
    let open = overview.iOwe
    summary = Summary(
      iOwe: overview.totalIOweRub, iOweCount: open.count, monthly: overview.monthlyPaymentsRub,
      nextPayment: open.compactMap(\.nextPayment).min(), owedToMe: overview.totalOwedToMeRub,
      peopleCount: overview.owedToMe.count)
    let debts = open.filter { !$0.debt.isInstalmentPlan }.map(Self.card(of:))
    let plans = open.filter(\.debt.isInstalmentPlan).map(Self.card(of:))
    let persons = overview.owedToMe.map { Self.card(of: $0, people: people) }
    let closed = overview.closed.map(Self.card(of:))
    groups = [
      Group(kind: .iOwe, cards: debts), Group(kind: .owedToMe, cards: persons),
      Group(kind: .instalments, cards: plans), Group(kind: .closed, cards: closed),
    ].filter { !$0.cards.isEmpty }
  }

  /// The groups in rows for a page whose groups are `columns` cards wide: two groups of a single
  /// card that follow each other share a row, as the design pairs «Мне должны» and «Рассрочки»;
  /// any other group has a row of its own.
  func rows(columns: Int) -> [Row] {
    var rows: [Row] = []
    var index = 0
    while index < groups.count {
      let group = groups[index]
      if columns >= 2, group.cards.count == 1, index + 1 < groups.count,
        groups[index + 1].cards.count == 1, group.kind != .closed,
        groups[index + 1].kind != .closed
      {
        rows.append(Row(groups: [group, groups[index + 1]]))
        index += 2
      } else {
        rows.append(Row(groups: [group]))
        index += 1
      }
    }
    return rows
  }

  static func card(of line: DebtLine) -> Card {
    let model = DebtCardModel(line)
    return Card(
      selection: .debt(line.id), kind: .debt(model.badge), name: model.name,
      amount: model.balance, currency: model.currency,
      percent: model.borrowed.flatMap { borrowed in
        model.paid.map { percent($0, of: borrowed) }
      },
      paid: model.paid, total: model.borrowed, progressCurrency: line.debt.currency,
      rate: model.rate, payment: model.payment, nextDue: model.nextPayment, debtId: line.id)
  }

  /// A person who owes me: everything they owe, what of it came back — their debts in rubles and
  /// the parts I paid for them —, the payments their debts ask a month and the nearest of them.
  static func card(of group: OwedToMeGroup, people: [Person]) -> Card {
    let rubles = group.debts.filter { $0.debt.currency == .rub }
    var lent = AmountE4.zero
    var back = AmountE4.zero
    for line in rubles {
      guard let borrowed = DebtCardModel.borrowed(of: line) else { continue }
      lent += borrowed
      back += DebtCardModel.paid(of: line, borrowed: borrowed)
    }
    for part in group.parts {
      lent += part.amountRub + part.returnedRub
      back += part.returnedRub
    }
    let payments = rubles.compactMap(\.debt.monthlyPaymentE4).filter { $0.raw > 0 }
    let rates = group.debts.compactMap(\.debt.interestRate)
    return Card(
      selection: .person(group.personId), kind: .person,
      name: people.first { $0.id == group.personId }?.name ?? "",
      amount: group.totalRub, currency: .rub,
      percent: lent.raw > 0 ? percent(back, of: lent) : nil,
      paid: lent.raw > 0 ? back : nil, total: lent.raw > 0 ? lent : nil, progressCurrency: .rub,
      rate: rates.count == group.debts.count && Set(rates).count == 1 ? rates.first : nil,
      payment: payments.isEmpty ? nil : AmountE4.sum(payments),
      nextDue: group.debts.compactMap(\.nextPayment).min(), debtId: nil)
  }

  /// `part` of `whole` in whole percent, half away from zero, within 0…100.
  static func percent(_ part: AmountE4, of whole: AmountE4) -> Int {
    guard whole.raw > 0 else { return 0 }
    var share = Decimal(part.raw) * 100 / Decimal(whole.raw)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &share, 0, .plain)
    return min(max(NSDecimalNumber(decimal: rounded).intValue, 0), 100)
  }
}

/// The card of the payoff ladder on the board: the order of the method chosen, and when the debts
/// are paid off with the money above the payments against without it, and the interest that
/// saves. Worked out with the ladder's own rules (`DebtLadder`), nothing of its own.
struct DebtsLadderCard: Equatable {
  struct Step: Identifiable, Equatable {
    let id: UUID
    let name: String
    let ratePercent: Decimal
    let balance: AmountE4
  }

  let method: LadderMethod
  let steps: [Step]
  /// The month the last debt is paid off, with the money above the payments.
  let freeFrom: MonthKey?
  /// The same with the minimum payments only, when the money above brings it nearer.
  let freeWithout: MonthKey?
  /// The interest the money above saves, when it saves any.
  let interestSaved: AmountE4?

  init?(candidates: [LadderDebt], extra: AmountE4, method: LadderMethod, start: MonthKey) {
    guard !candidates.isEmpty else { return nil }
    self.method = method
    let chosen = DebtLadder.plan(candidates, extraRub: extra, method: method, start: start)
    let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    steps = chosen.order.compactMap { id in
      byId[id].map {
        Step(id: id, name: $0.name, ratePercent: $0.ratePercent, balance: $0.balanceRub)
      }
    }
    freeFrom = chosen.freeFrom
    guard extra.raw > 0 else {
      freeWithout = nil
      interestSaved = nil
      return
    }
    let bare = DebtLadder.plan(candidates, extraRub: .zero, method: method, start: start)
    if let free = chosen.freeFrom, let without = bare.freeFrom, without > free {
      freeWithout = without
    } else {
      freeWithout = nil
    }
    let saved = bare.interestRub - chosen.interestRub
    interestSaved = bare.freeFrom != nil && saved.raw > 0 ? saved : nil
  }
}
