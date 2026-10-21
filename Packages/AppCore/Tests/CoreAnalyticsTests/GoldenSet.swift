// The golden set without the test framework: the decoding of `golden-small.json` and the
// dataset it describes. The app's tests compile this very file too (project.yml), so the
// Analytics window is checked against the same hand-computed history as the core — the
// bytes come from each test bundle, never from a repository path.
import CoreAnalytics
import CoreCSV
import CoreKit
import Foundation

/// A readable, reproducible id: `id(7)` is always the same UUID, and `number(of:)` reads the
/// 7 back, so answers in the fixture can name things by their small numbers.
func id(_ number: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
}

func number(of id: UUID) -> Int {
  Int(id.uuidString.suffix(12)) ?? -1
}

/// An amount as the fixture and the tests write it: a plain decimal, a dot and at most four
/// places — «1250.5», «-0.25». `Decimal(string:)` alone reads the longest number it finds at
/// the start, so «1 000» came back as 1 and «1000 ₽» as 1000, and «abc» as zero, without a
/// word. Anything else is a typo: it is reported to the running test through
/// `reportAmountTypo` — each bundle that compiles this file defines it in its own framework —
/// and counts as zero.
func money(_ text: String) -> AmountE4 {
  guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,4})?/) != nil,
    let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal)
  else {
    reportAmountTypo(text)
    return .zero
  }
  return amount
}

func day(_ iso: String) -> DateOnly {
  DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
}

/// The amount as the fixture writes it: a plain decimal, trailing zeros trimmed.
func text(_ amount: AmountE4?) -> String {
  amount.map { CSVValue.string(amount: $0) } ?? ""
}

/// The key as the fixture writes it: `category:10`, `no-place`, `quality:bad`.
func fixtureKey(_ key: ReportKey) -> String {
  switch key {
  case .category(let id): "category:\(number(of: id))"
  case .person(let id): "person:\(number(of: id))"
  case .place(let id): "place:\(number(of: id))"
  case .event(let id): "event:\(number(of: id))"
  case .paymentMethod(let id): "payment-method:\(number(of: id))"
  default: key.description
  }
}

/// `Fixtures/golden-small.json`, read from a test bundle — never from a repository path.
struct Golden: Decodable {
  struct CategoryRow: Decodable {
    let id: Int
    let parent: Int?
    let name: String
    let kind: String
    let quality: String?
    let role: String?
    let archived: Bool?
  }

  struct PersonRow: Decodable {
    let id: Int
    let name: String
    let relation: String
  }

  struct NamedRow: Decodable {
    let id: Int
    let name: String
    let kind: String?
  }

  struct EventRow: Decodable {
    let id: Int
    let name: String
    let kind: String
    let start: String
    let end: String
    let series: Int?
    let yearly: Bool?
    let budget: String?
  }

  struct GoalRow: Decodable {
    let id: Int
    let name: String
    let target: String
    let monthlyPlan: String?
    let subcategory: Int?
  }

  struct DebtRow: Decodable {
    let id: Int
    let name: String
    let type: String
    let origin: String
    let paymentsAreExpenses: Bool
    let currency: String?
    let monthlyPayment: String?
    let paymentDay: Int?
    let closed: Bool?
    let loansSubcategory: Int?
  }

  struct PartRow: Decodable {
    let id: Int
    let category: Int?
    let categorySource: String?
    let amount: String
    let amountRub: String?
    let quality: String?
    let qualitySource: String?
    let forWhom: String?
    let forPerson: Int?
    let reimbursable: Bool?
    let debtor: Int?
    let status: String?
    let event: Int?
    let goal: Int?
    let note: String?
  }

  struct OperationRow: Decodable {
    let id: Int
    let kind: String
    let at: String
    let note: String?
    let place: Int?
    let method: Int?
    let debt: Int?
    let creditDebt: Int?
    let currency: String?
    let rate: String?
    let periodMonth: String?
    let deleted: Bool?
    let externalId: String?
    let parts: [PartRow]
  }

  struct LinkRow: Decodable {
    let id: Int
    let reimbursement: Int
    let part: Int
    let amount: String
  }

  struct Settings: Decodable {
    let cashbackCategory: Int?
  }

  struct Node: Decodable, Equatable, CustomStringConvertible {
    let key: String
    let amount: String
    let share: Int?
    let children: [Node]?

    init(key: String, amount: String, share: Int?, children: [Node]?) {
      self.key = key
      self.amount = amount
      self.share = share
      self.children = children
    }

    init(_ node: BreakdownNode) {
      self.init(
        key: fixtureKey(node.key), amount: text(node.amount), share: node.share,
        children: node.children.isEmpty ? nil : node.children.map(Node.init))
    }

    /// Amounts compared as money, not as spelling.
    static func == (left: Node, right: Node) -> Bool {
      left.key == right.key && money(left.amount) == money(right.amount)
        && left.share == right.share
        && (left.children ?? []) == (right.children ?? [])
    }

    var description: String {
      let inner = children.map { " [" + $0.map(\.description).joined(separator: ", ") + "]" } ?? ""
      return "\(key) \(amount) \(share.map(String.init) ?? "–")\(inner)"
    }
  }

  struct Answer: Decodable {
    let why: String
    let amount: String?
    let int: Int?
    let amounts: [String]?
    let nodes: [Node]?
    let items: [[String]]?
    let ids: [Int]?
    let text: String?
  }

  let calendar: String
  let today: String
  let settings: Settings
  let rates: [String: String]
  let categories: [CategoryRow]
  let people: [PersonRow]
  let places: [NamedRow]
  let paymentMethods: [NamedRow]
  let events: [EventRow]
  let goals: [GoalRow]
  let debts: [DebtRow]
  let operations: [OperationRow]
  let links: [LinkRow]
  let expected: [String: Answer]

  /// The set from the bytes of `golden-small.json`, however they were found: the core's
  /// tests read them from their bundle, the app's tests from theirs.
  static func decode(_ data: Data) throws -> Golden {
    try JSONDecoder().decode(Golden.self, from: data)
  }

  var todayDay: DateOnly { day(today) }

  var rubPerUnit: [CurrencyCode: Decimal] {
    Dictionary(
      uniqueKeysWithValues: rates.compactMap { code, value in
        Decimal(string: value).map { (CurrencyCode(code), $0) }
      })
  }

  /// Names for the CSV, as the app's label resolver would give them in English.
  func label(_ key: ReportKey) -> String {
    switch key {
    case .category(let id): categories.first { $0.id == number(of: id) }?.name ?? "?"
    case .uncategorized: "Uncategorized"
    case .noSubcategory: "(no subcategory)"
    case .month(let month): month.iso
    case .income: "Income"
    case .expenses: "Expenses"
    default: key.description
    }
  }

  // MARK: - Building the dataset

  func dataset() -> Dataset {
    Dataset(
      entries: operations.map(entry),
      links: links.map {
        ReimbursementLink(
          id: id($0.id), reimbursementTxId: id($0.reimbursement), partId: id($0.part),
          amountE4: money($0.amount))
      },
      categories: categories.map {
        CoreKit.Category(
          id: id($0.id), parentId: $0.parent.map(id),
          kind: CategoryKind(rawValue: $0.kind) ?? .expense,
          name: $0.name, archived: $0.archived ?? false,
          quality: $0.quality.flatMap(Quality.init(rawValue:)),
          systemRole: $0.role.flatMap(SystemRole.init(rawValue:)))
      },
      people: people.map {
        Person(
          id: id($0.id), name: $0.name, relation: PersonRelation(rawValue: $0.relation) ?? .other)
      },
      places: places.map { Place(id: id($0.id), name: $0.name) },
      events: events.map {
        Event(
          id: id($0.id), name: $0.name, kind: EventKind(rawValue: $0.kind) ?? .other,
          startDate: day($0.start), endDate: day($0.end), budgetE4: $0.budget.map(money),
          recurringYearly: $0.yearly ?? false, seriesId: $0.series.map(id))
      },
      paymentMethods: paymentMethods.map {
        PaymentMethod(
          id: id($0.id), name: $0.name,
          kind: $0.kind.flatMap(PaymentMethodKind.init(rawValue:)) ?? .card)
      },
      debts: debts.map {
        Debt(
          id: id($0.id), direction: .iOwe, type: DebtType(rawValue: $0.type) ?? .loan,
          name: $0.name,
          currency: $0.currency.map { CurrencyCode($0) } ?? .rub,
          monthlyPaymentE4: $0.monthlyPayment.map(money), paymentDay: $0.paymentDay,
          paymentsAreExpenses: $0.paymentsAreExpenses,
          origin: DebtOrigin(rawValue: $0.origin) ?? .existing, closed: $0.closed ?? false,
          loansSubcategoryId: $0.loansSubcategory.map(id))
      },
      goals: goals.map {
        Goal(
          id: id($0.id), name: $0.name, targetE4: money($0.target),
          monthlyPlanE4: $0.monthlyPlan.map(money), subcategoryId: $0.subcategory.map(id))
      },
      settings: AnalyticsSettings(cashbackCategoryId: settings.cashbackCategory.map(id)))
  }

  func ledger() -> Ledger {
    Ledger(dataset: dataset(), calendar: .utc)
  }

  private func entry(_ row: OperationRow) -> TransactionEntry {
    let parts = row.parts.map { part in
      TransactionPart(
        id: id(part.id),
        transactionId: id(row.id),
        categoryId: part.category.map(id),
        categorySource: part.categorySource.flatMap(CategorySource.init(rawValue:)) ?? .manual,
        quality: part.quality.flatMap(Quality.init(rawValue:)),
        qualitySource: part.qualitySource.flatMap(QualitySource.init(rawValue:)),
        amountE4: money(part.amount),
        amountRubE4: money(part.amountRub ?? part.amount),
        forWhom: part.forWhom.flatMap(ForWhom.init(rawValue:)) ?? .me,
        forPersonId: part.forPerson.map(id),
        reimbursable: part.reimbursable ?? false,
        debtorPersonId: part.debtor.map(id),
        reimbursementStatus: part.status.flatMap(ReimbursementStatus.init(rawValue:)),
        eventId: part.event.map(id),
        goalId: part.goal.map(id),
        note: part.note)
    }
    let when = moment(row.at)
    let currency = row.currency.map { CurrencyCode($0) } ?? .rub
    return TransactionEntry(
      transaction: Transaction(
        id: id(row.id),
        kind: TransactionKind(rawValue: row.kind) ?? .expense,
        occurredAt: when,
        currency: currency,
        amountE4: AmountE4.sum(parts.map(\.amountE4)),
        rate: row.rate.flatMap { Decimal(string: $0) },
        rateDate: row.rate == nil ? nil : CalendarContext.utc.day(of: when),
        rateSource: row.rate == nil ? nil : .manual,
        amountRubE4: AmountE4.sum(parts.map(\.amountRubE4)),
        note: row.note,
        placeId: row.place.map(id),
        paymentMethodId: row.method.map(id),
        periodMonth: row.periodMonth.flatMap(MonthKey.init(iso:)),
        debtId: row.debt.map(id),
        creditDebtId: row.creditDebt.map(id),
        externalId: row.externalId.map(Self.writtenAsTheAppWrites),
        createdAt: when,
        updatedAt: when,
        deletedAt: row.deleted == true ? when : nil),
      parts: parts)
  }

  /// A key the app wrote into `external_id`, with the small numbers the fixture names things by
  /// turned into the ids the app writes: `reimb:129:shortfall:1151` names the part whose id is
  /// `id(1151)`, and the ledger finds a shortfall by that id.
  static func writtenAsTheAppWrites(_ key: String) -> String {
    key.split(separator: ":", omittingEmptySubsequences: false).map { field in
      guard !field.isEmpty, field.allSatisfy(\.isNumber), let number = Int(field) else {
        return String(field)
      }
      return id(number).uuidString.lowercased()
    }.joined(separator: ":")
  }

  /// `2026-07-01T10:00` in UTC.
  private func moment(_ text: String) -> Date {
    let pieces = text.split(separator: "T")
    let start = CalendarContext.utc.startOfDay(day(String(pieces[0])))
    guard pieces.count > 1 else { return start }
    let clock = pieces[1].split(separator: ":").compactMap { Int($0) }
    let seconds = (clock.first ?? 0) * 3600 + (clock.dropFirst().first ?? 0) * 60
    return start.addingTimeInterval(TimeInterval(seconds))
  }
}
