import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Random lines of every kind, typed on random account screens, with random choices made in the
/// panel afterwards: whatever the mix, what Enter would save keeps the rules of the kind and of
/// the accounts — a live account always; «Списано со счёта» exactly when the account does not
/// hold the currency, in the account's main currency; the currency typed, else the chosen
/// account's, else the default one; income and money back without the fields they do not have,
/// the words that named them kept in the note.
@MainActor
final class EntryLinePropertyTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let kzt = CurrencyCode("KZT")
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private lazy var kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
  private let freedom = PaymentMethod(name: "Freedom", currency: .eur, otherCurrencies: [.usd])
  private let anya = Person(name: "Аня")
  private let shop = Place(name: "Спортмастер")
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for account in [card, kaspi, freedom] { try references.save(account) }
    try references.save(anya)
    try references.save(shop)
  }

  private var accounts: [PaymentMethod] { [card, kaspi, freedom] }

  private var rates: RateTable {
    RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 90),
      Rate(date: today, currency: .eur, rubPerUnit: 100),
      Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
  }

  private var parser: InputLineParser {
    InputLineParser(
      vocabulary: ParserVocabulary(
        people: [.init(id: anya.id, name: anya.name)],
        places: [.init(id: shop.id, name: shop.name)],
        paymentMethods: [
          .init(id: freedom.id, name: freedom.name), .init(id: kaspi.id, name: kaspi.name),
        ]),
      calendar: .utc)
  }

  /// SplitMix64: the same seed gives the same lines, so a failure names a seed that repeats it.
  private struct Dice {
    var state: UInt64
    mutating func below(_ bound: Int) -> Int {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((mixed ^ (mixed >> 31)) % UInt64(bound))
    }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
  }

  func testWhatEnterWouldSaveKeepsTheRulesOfKindsAndAccounts() throws {
    let currencies: [(word: String, code: CurrencyCode?)] = [
      ("", nil), (" usd", .usd), (" eur", .eur), (" kzt", kzt), (" rub", .rub),
    ]
    for seed in UInt64(1)...250 {
      var dice = Dice(state: seed)
      let kind = dice.pick(["", "+", "возврат денег "])
      let typed = dice.pick(currencies)
      let named = dice.pick([nil, freedom, kaspi])
      let place = dice.pick(["", " в Спортмастер"])
      let person = kind == "возврат денег " ? " от Ани" : dice.pick(["", " для Ани"])
      let screen = dice.pick([nil, kaspi.id, freedom.id])
      let line =
        "\(kind)\(dice.below(900) + 100)\(typed.word) кофе\(named.map { " \($0.name)" } ?? "")"
        + "\(place)\(person)"

      let model = EntryDraftModel(
        references: references, transactions: transactions, calendar: .utc)
      model.openAccountScreen = { screen }
      let table = rates
      model.rateTable = { table }
      model.reload()
      let parsed = parser.parse(line, today: today)
      let amount = try AmountE4(decimal: try XCTUnwrap(parsed.amount, line))
      model.apply(parsed, amount: amount, today: today)
      model.takeTheMomentOfSaving(now: CalendarContext.utc.startOfDay(today) + 12 * 3600)
      model.applyDefaults(today: today)

      // Some lines get an account picked in the panel afterwards.
      let picked = dice.below(4) == 0 ? dice.pick(accounts) : nil
      if let picked { model.setPaymentMethod(picked.id) }

      let saved = model.draftForSaving
      let context =
        "seed \(seed): «\(line)» screen "
        + "\(screen.map { $0 == kaspi.id ? "Kaspi" : "Freedom" } ?? "—")"
        + " picked \(picked?.name ?? "—")"

      // A live account, always.
      let account = try XCTUnwrap(accounts.first { $0.id == saved.paymentMethodId }, context)

      // The currency: typed, else the chosen account's main one, else the default one.
      let chosen = picked ?? named ?? screen.flatMap { id in accounts.first { $0.id == id } }
      let expected = typed.code ?? chosen?.mainCurrency ?? .rub
      XCTAssertEqual(saved.currency, expected, context)

      // «Списано со счёта» exactly when the account does not hold the currency.
      if account.holds(saved.currency) {
        XCTAssertNil(saved.accountCurrency, context)
        XCTAssertFalse(model.needsCharge, context)
      } else {
        XCTAssertTrue(model.needsCharge, context)
        XCTAssertEqual(saved.accountCurrency, account.mainCurrency, context)
        XCTAssertGreaterThan(saved.accountAmount?.raw ?? 0, 0, context)
      }

      // The fields of the kind.
      switch saved.kind {
      case .income:
        XCTAssertNil(saved.placeId, context)
        if !place.isEmpty {
          XCTAssertTrue(saved.note?.contains("в Спортмастер") == true, context)
        }
        for part in saved.parts {
          XCTAssertNil(part.forPersonId, context)
          XCTAssertNil(part.eventId, context)
          XCTAssertFalse(part.reimbursable, context)
        }
      case .reimbursement:
        XCTAssertNil(saved.placeId, context)
        if !place.isEmpty {
          XCTAssertTrue(saved.note?.contains("в Спортмастер") == true, context)
        }
        XCTAssertEqual(saved.parts.first?.forPersonId, anya.id, context)
      default:
        if !place.isEmpty { XCTAssertEqual(saved.placeId, shop.id, context) }
      }
    }
  }

  // MARK: With history at the place, and refunds

  /// Sneakers bought at the shop on Kaspi, 35,000 ₸ at 20 ₽ for 100 ₸: the place's last
  /// account is Kaspi from now on.
  private func sneakersOnKaspi() throws -> TransactionEntry {
    let clothes = CoreKit.Category(kind: .expense, name: "Одежда", quality: .neutral)
    try references.save(clothes)
    var draft = TransactionDraft(
      kind: .expense,
      occurredAt: CalendarContext.utc.startOfDay(today) - 5 * 86_400 + 12 * 3600,
      currency: kzt, amount: AmountE4(whole: 35_000), rate: Decimal(string: "0.2"),
      rateDate: today, rateSource: .cbr, note: "кроссовки", placeId: shop.id,
      paymentMethodId: kaspi.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = clothes.id
    return try transactions.save(try draft.materialize())
  }

  /// The same lines with history behind them — the shop's last account is the tenge one — and
  /// with refunds: a refund takes the purchase picked for it whole or in part, or goes «Без
  /// покупки», or waits for the picker. Whatever the mix:
  /// * the place's last account takes the operation when nothing chose another, and never its
  ///   currency: «кофе 500 в Спортмастер» is 500 ₽ charged to Kaspi in tenge;
  /// * a refund of a purchase is in the purchase's currency at its rate, on the purchase's
  ///   account unless the line named one or the panel picked one;
  /// * income never has «для кого»: «для Ани» stays in its note, as the place's words do.
  func testWithHistoryAndRefundsTheRulesStillHold() throws {
    let sneakers = try sneakersOnKaspi()
    let currencies: [(word: String, code: CurrencyCode?)] = [
      ("", nil), (" usd", .usd), (" kzt", kzt), (" rub", .rub),
    ]
    // How often each case came up: a property that never meets its case proves nothing.
    var purchasesRefunded = 0
    var placesAccountTaken = 0
    var incomeForAnya = 0
    for seed in UInt64(1)...250 {
      var dice = Dice(state: seed &* 7919)
      let kind = dice.pick(["", "+", "возврат "])
      let typed = dice.pick(currencies)
      let named = dice.pick([nil, nil, freedom, kaspi])
      let place = dice.pick(["", " в Спортмастер"])
      let person = dice.pick(["", " для Ани"])
      let screen = dice.pick([nil, nil, kaspi.id, freedom.id])
      let line =
        "\(kind)\(dice.below(900) + 100)\(typed.word) кофе"
        + "\(named.map { " \($0.name)" } ?? "")\(place)\(person)"

      let model = EntryDraftModel(
        references: references, transactions: transactions, calendar: .utc)
      model.openAccountScreen = { screen }
      let table = rates
      model.rateTable = { table }
      model.reload()
      let parsed = parser.parse(line, today: today)
      let amount = try AmountE4(decimal: try XCTUnwrap(parsed.amount, line))
      model.apply(parsed, amount: amount, today: today)
      model.takeTheMomentOfSaving(now: CalendarContext.utc.startOfDay(today) + 12 * 3600)
      model.applyDefaults(today: today)

      // A refund: the purchase whole, a part of it, «Без покупки», or nothing picked yet.
      var refunded: AmountE4?
      if model.draft.kind == .refund {
        switch dice.below(4) {
        case 0: refunded = AmountE4(whole: 35_000)
        case 1: refunded = AmountE4(whole: 10_000)
        case 2: model.refundWithoutPurchase = true
        default: break
        }
        if let refunded {
          let candidate = RefundCandidate(
            purchase: sneakers, part: sneakers.parts[0], remaining: AmountE4(whole: 35_000),
            refunded: .zero)
          model.chooseRefund(of: candidate, amount: refunded)
        }
      }
      let picked = dice.below(4) == 0 ? dice.pick(accounts) : nil
      if let picked { model.setPaymentMethod(picked.id) }

      let saved = model.draftForSaving
      let context =
        "seed \(seed): «\(line)» screen "
        + "\(screen.map { $0 == kaspi.id ? "Kaspi" : "Freedom" } ?? "—")"
        + " picked \(picked?.name ?? "—") refunded \(refunded.map(FieldNumber.text) ?? "—")"

      let account = try XCTUnwrap(accounts.first { $0.id == saved.paymentMethodId }, context)
      if let refunded {
        XCTAssertEqual(saved.kind, .refund, context)
        XCTAssertEqual(saved.parts.first?.refundOfPartId, sneakers.parts[0].id, context)
        XCTAssertEqual(saved.currency, kzt, context)
        XCTAssertEqual(saved.amount, refunded, context)
        XCTAssertEqual(saved.rate, Decimal(string: "0.2"), context)
        XCTAssertEqual(account.id, (picked ?? named ?? kaspi).id, context)
        purchasesRefunded += 1
      } else {
        let chosen = picked ?? named ?? screen.flatMap { id in accounts.first { $0.id == id } }
        XCTAssertEqual(saved.currency, typed.code ?? chosen?.mainCurrency ?? .rub, context)
        // Nothing chose the account: the place's last one, where the kind has a place.
        if chosen == nil {
          let atThePlace = !place.isEmpty && saved.kind != .income
          XCTAssertEqual(account.id, atThePlace ? kaspi.id : card.id, context)
          if atThePlace { placesAccountTaken += 1 }
        }
      }

      if account.holds(saved.currency) {
        XCTAssertNil(saved.accountCurrency, context)
        XCTAssertFalse(model.needsCharge, context)
      } else {
        XCTAssertTrue(model.needsCharge, context)
        XCTAssertEqual(saved.accountCurrency, account.mainCurrency, context)
        XCTAssertGreaterThan(saved.accountAmount?.raw ?? 0, 0, context)
      }

      if saved.kind == .income {
        XCTAssertNil(saved.placeId, context)
        for part in saved.parts {
          XCTAssertNil(part.forPersonId, context)
          XCTAssertEqual(part.forWhom, .me, context)
        }
        if !person.isEmpty {
          XCTAssertTrue(saved.note?.contains("для Ани") == true, context)
          incomeForAnya += 1
        }
        if !place.isEmpty {
          XCTAssertTrue(saved.note?.contains("в Спортмастер") == true, context)
        }
      }
    }
    XCTAssertGreaterThan(purchasesRefunded, 10)
    XCTAssertGreaterThan(placesAccountTaken, 5)
    XCTAssertGreaterThan(incomeForAnya, 10)
  }
}
