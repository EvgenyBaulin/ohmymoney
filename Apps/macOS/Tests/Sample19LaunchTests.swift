#if DEBUG

  import AppCore
  import AppDatabase
  import XCTest

  @testable import OhMyMoney

  /// `make sample` with the credit, the allocation and self-employment of the sample: written as
  /// a data set is, read back from its database and counted as the launch counts it, it asks
  /// nothing at launch — no due date passed, no old debt to review, no offer of self-employment,
  /// not even opened as an ordinary database —, and the rules of the app read its rows the way
  /// the layers meant them.
  @MainActor
  final class Sample19LaunchTests: XCTestCase {
    private let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-sample19-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() async throws {
      try? FileManager.default.removeItem(at: scratch)
    }

    private struct Opened {
      var set: SampleDataSet
      var dataset: Dataset
      var snapshot: DataSnapshot
      var stack: DatabaseStack
    }

    /// The sample of six months ending `today`, as `make sample` writes it, read back.
    private func open(
      _ index: Int, today: DateOnly, language: String, seed: UInt64 = DataSetGeneration.fixedSeed
    ) async throws -> Opened {
      let root = scratch.appendingPathComponent("\(index)", isDirectory: true)
      let now = CalendarContext.utc.startOfDay(today).addingTimeInterval(12 * 3_600)
      let stack = try DataSetGeneration.prepare(
        directory: AppPaths.directory(of: .sample, in: root), generation: .months(6),
        today: today, now: now, calendar: .utc, language: language,
        schema: BundleSchemaSource(bundle: .main), seed: seed)
      let set = DataSetGeneration.generate(
        .months(6), today: today, now: now, calendar: .utc, language: language, seed: seed)
      let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
      let snapshot = DataSnapshot.build(
        dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
        version: DataVersion(load: 0), now: now)
      return Opened(set: set, dataset: dataset, snapshot: snapshot, stack: stack)
    }

    private static let cases: [(today: DateOnly, language: String)] = [
      (DateOnly(year: 2026, month: 10, day: 13), "ru"),
      (DateOnly(year: 2027, month: 3, day: 1), "en"),
      (DateOnly(year: 2026, month: 12, day: 6), "ru"),
    ]

    func testTheSampleAsksNothingAtLaunch() async throws {
      for (index, run) in Self.cases.enumerated() {
        let what = run.today.iso
        let opened = try await open(index, today: run.today, language: run.language)
        defer { try? opened.stack.close() }
        let planning = opened.snapshot.planning
        XCTAssertEqual(planning.overdue.map(\.name), [], what)
        XCTAssertNil(
          RemindersPresentation.decide(
            daily: [], overdue: planning.overdue, shownToday: true, askedThisLaunch: false),
          what)
        XCTAssertTrue(planning.debtReview.isEmpty, what)
        XCTAssertFalse(
          SelfEmploymentOffer.offers(
            dataset: opened.dataset, tree: opened.snapshot.ledger.tree), what)
        // Not even an ordinary database of these rows would ask.
        XCTAssertNil(
          RemindersPresentation.nextQuestion(
            debtReview: planning.debtReview,
            offersSelfEmployment: SelfEmploymentOffer.offers(
              dataset: opened.dataset, tree: opened.snapshot.ledger.tree),
            asked: [], waits: false, locked: false, dataSet: false),
          what)
        // No reminder of the new debts stands in «Стоит посмотреть» either.
        for reminder in planning.debtReminders {
          switch reminder {
          case .creditHistory: continue
          default: XCTFail("\(what): \(reminder)")
          }
        }
      }
    }

    /// The rows land: the costs of the loan, the rules, the currency and its rates, the main card.
    func testTheRowsOfTheLayersLand() async throws {
      let opened = try await open(0, today: Self.cases[0].today, language: "ru")
      defer { try? opened.stack.close() }
      let set = opened.set
      let counts = try ExportRepository(writer: opened.stack.writer).rowCounts()
      XCTAssertEqual(counts["debt_costs"], set.debtCosts.count)
      XCTAssertEqual(counts["allocation_rules"], set.allocationRules.count)
      XCTAssertEqual(counts["custom_currencies"], 1)
      XCTAssertEqual(counts["transactions"], set.entries.count)
      XCTAssertEqual(counts["transfers"], set.transfers.count)
      XCTAssertEqual(opened.dataset.debtCosts, set.debtCosts)
      XCTAssertEqual(opened.dataset.allocationRules, set.allocationRules)
      XCTAssertEqual(opened.dataset.customCurrencies, set.customCurrencies)
      let currencies = CurrencyRepository(writer: opened.stack.writer)
      XCTAssertEqual(try currencies.rates(of: SampleDataSet.milesCode).count, 3)
      XCTAssertNotNil(try currencies.rate(of: SampleDataSet.milesCode, on: Self.cases[0].today))
      XCTAssertTrue(try currencies.catalog().isCustom(SampleDataSet.milesCode))
      let main = try XCTUnwrap(opened.dataset.paymentMethods.first(where: \.isMain))
      XCTAssertEqual(main.mainCardId, CardsMigration.cardId(forAccount: main.id))
      XCTAssertTrue(opened.dataset.debts.allSatisfy(\.termsReviewed))
      let card = try XCTUnwrap(opened.dataset.paymentMethods.first(where: \.isCreditCard))
      XCTAssertEqual(card.credit, SampleDataSet.tBankTerms)
    }

    /// The credit card: its latest statement paid in full, the grace period kept; the cash
    /// taken comes with the fee the bank's terms say.
    func testTheCreditCardKeepsItsGrace() async throws {
      for (index, run) in Self.cases.enumerated() {
        let what = run.today.iso
        let opened = try await open(index, today: run.today, language: run.language)
        defer { try? opened.stack.close() }
        let card = try XCTUnwrap(opened.dataset.paymentMethods.first(where: \.isCreditCard), what)
        let terms = try XCTUnwrap(card.credit)
        let ledger = opened.snapshot.ledger
        let movements = CreditStatements.movements(
          account: card, ledger: ledger, transfers: opened.dataset.transfers)
        let statements = CreditStatements.statements(
          account: card, terms: terms, movements: movements,
          balances: opened.snapshot.planning.accounts.balances, through: run.today,
          calendar: ledger.calendar)
        let latest = try XCTUnwrap(
          statements.first { $0.closesOn == SampleDataSet.latestStatement(before: run.today) },
          what)
        XCTAssertEqual(latest.state, .paidInFull, what)
        XCTAssertGreaterThan(latest.debtE4, .zero, what)
        let now = try XCTUnwrap(opened.snapshot.planning.creditCards[card.id], what)
        XCTAssertTrue(now.graceKept, what)
        XCTAssertEqual(
          CreditInterest.cashFee(amount: SampleDataSet.cashTaken, terms: terms),
          AmountE4(whole: 435), what)
      }
    }

    /// Self-employment: the tax of the month before is paid exactly as the app works it out —
    /// no gap with the tax office —; the last income is allocated by the rules and nothing is
    /// left of it to offer; the salaries of the history wait for «Распределить».
    func testTheTaxAndTheAllocationAreTheAppsOwn() async throws {
      for (index, run) in Self.cases.enumerated() {
        let what = run.today.iso
        let opened = try await open(index, today: run.today, language: run.language)
        defer { try? opened.stack.close() }
        let planning = opened.snapshot.planning
        let npd = try XCTUnwrap(planning.npd, what)
        let month = try XCTUnwrap(
          npd.months.first { $0.month == run.today.monthKey.previous }, what)
        XCTAssertEqual(month.state, .paid, what)
        XCTAssertNil(month.fnsGapE4, what)
        XCTAssertGreaterThan(month.deductionUsedE4, .zero, what)
        XCTAssertNil(npd.nextDue, what)

        let ledger = opened.snapshot.ledger
        let contribution = try XCTUnwrap(
          opened.dataset.entries.first { $0.transaction.externalId?.hasPrefix("alloc:") == true },
          what)
        let incomeId = try XCTUnwrap(Allocation.income(ofKey: contribution.transaction.externalId))
        let income = try XCTUnwrap(ledger.entry(incomeId), what)
        let tax = try XCTUnwrap(
          NPDTax.tax(
            of: income, tree: ledger.tree, settings: opened.dataset.selfEmployment,
            dayRates: .empty, deductionLeft: npd.deductionLeftE4), what)
        let base = income.transaction.amountE4 - tax.taxE4
        for rule in opened.dataset.allocationRules {
          XCTAssertEqual(
            Allocation.amount(
              of: rule, base: base, incomeCurrency: .rub, day: run.today, dayRates: .empty),
            contribution.transaction.amountE4, what)
        }
        XCTAssertEqual(
          Allocation.distributed(
            incomeId: incomeId, ledger: ledger, transfers: opened.dataset.transfers),
          contribution.transaction.amountE4 + contribution.transaction.amountE4, what)
        let linked = Allocation.linked(
          incomeId: incomeId, ledger: ledger, transfers: opened.dataset.transfers)
        XCTAssertEqual(linked.contributions.count, 1, what)
        XCTAssertEqual(linked.transfers.count, 1, what)
        XCTAssertTrue(
          Allocation.offers(
            entry: income, tree: ledger.tree, settings: opened.dataset.allocationSettings), what)
        XCTAssertFalse(planning.allocationOffers.isEmpty, "\(what): the salaries wait")
      }
    }

    /// The instalment plan counts with its first part paid and the next one ahead; the pledge is
    /// owed to me.
    func testTheInstalmentPlanAndThePledgeCount() async throws {
      let opened = try await open(0, today: Self.cases[0].today, language: "ru")
      defer { try? opened.stack.close() }
      let debts = opened.snapshot.planning.debts
      let plan = try XCTUnwrap(debts.iOwe.first { $0.debt.name == "Пылесос" })
      XCTAssertEqual(plan.balance, AmountE4(whole: 9_000))
      XCTAssertGreaterThan(opened.snapshot.planning.instalments.count, 0)
      let pledge = try XCTUnwrap(
        debts.owedToMe.flatMap(\.debts).first { $0.debt.name == "Залог за квартиру" })
      XCTAssertEqual(pledge.balance, AmountE4(whole: 30_000))
    }
  }

#endif
