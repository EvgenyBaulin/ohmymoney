#if DEBUG

  import AppCore
  import AppDatabase
  import XCTest

  @testable import OhMyMoney

  /// `make demo` opens on «Просроченные платежи» with the car inspection alone — no payment of a
  /// loan, whatever the seed and the day — and its row offers «Провести» and «Пропустить»;
  /// «Пропустить все N» only where a payment owes several dues, and never on a debt.
  @MainActor
  final class DemoOverdueLaunchTests: XCTestCase {
    private let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-demo-overdue-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() async throws {
      try? FileManager.default.removeItem(at: scratch)
    }

    /// The demo as `make demo` writes it — twelve months, the showcase — read back from its
    /// database and shown as the launch shows it.
    func testTheDemoAsksAboutTheCarInspectionAlone() async throws {
      let cases: [(seed: UInt64, today: DateOnly, language: String)] = [
        (7, DateOnly(year: 2026, month: 10, day: 7), "ru"),
        (281_474_976_710_655, DateOnly(year: 2026, month: 3, day: 31), "ru"),
        (20_260_920, DateOnly(year: 2027, month: 1, day: 15), "en"),
      ]
      for (index, run) in cases.enumerated() {
        let what = "seed \(run.seed), \(run.today.iso)"
        let root = scratch.appendingPathComponent("\(index)", isDirectory: true)
        let now = CalendarContext.utc.startOfDay(run.today).addingTimeInterval(12 * 3_600)
        let stack = try DataSetGeneration.prepare(
          directory: AppPaths.directory(of: .demo, in: root), generation: .months(12),
          today: run.today, now: now, calendar: .utc, language: run.language,
          schema: BundleSchemaSource(bundle: .main), seed: run.seed, showcase: true)
        defer { try? stack.close() }
        let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
        let snapshot = DataSnapshot.build(
          dataset: dataset, calendar: .utc, today: run.today, context: SnapshotContext(),
          version: DataVersion(load: 0), now: now)

        let overdue = snapshot.planning.overdue
        XCTAssertEqual(overdue.count, 1, "\(what): \(overdue.map(\.name))")
        let due = try XCTUnwrap(overdue.first, what)
        XCTAssertEqual(due.name, run.language == "ru" ? "Техосмотр" : "Car inspection", what)
        XCTAssertFalse(due.isDebt, what)
        XCTAssertLessThan(due.due, run.today, what)
        XCTAssertEqual(due.moreOverdue, 0, what)
        XCTAssertEqual(RemindersSheet.overdueActions(for: due), [.pay, .skip], what)
        XCTAssertNotNil(
          RemindersPresentation.decide(
            daily: [], overdue: overdue, shownToday: true, askedThisLaunch: false),
          "\(what): the launch asks")
      }
    }

    /// A payment owing four dues adds «Пропустить все 4»; a debt has no skip at all;
    /// «Уже списано до сверки» comes only after a count later than the due.
    func testTheButtonsOfAnOverdueRow() {
      let rent = OverdueDue(
        subject: .scheduled(UUID()), name: "Rent", due: DateOnly(year: 2026, month: 6, day: 5),
        amount: AmountE4(whole: 30_000), currency: .rub, moreOverdue: 3, countAfter: nil, key: nil)
      XCTAssertEqual(RemindersSheet.overdueActions(for: rent), [.pay, .skip, .skipAll(count: 4)])

      let counted = Date(timeIntervalSince1970: 1_790_000_000)
      let loan = OverdueDue(
        subject: .debt(UUID()), name: "Loan", due: DateOnly(year: 2026, month: 9, day: 5),
        amount: AmountE4(whole: 8_000), currency: .rub, moreOverdue: 2, countAfter: counted,
        key: nil)
      XCTAssertEqual(
        RemindersSheet.overdueActions(for: loan), [.pay, .settled(countedAt: counted)],
        "a debt is owed whatever the owner thinks of it")

      let language = AppLanguage()
      let before = language.choice
      defer { language.choice = before }
      language.choice = .russian
      XCTAssertEqual(
        language.format("reminders.overdue.skipAll", table: "Planning", counts: 4),
        "Пропустить все 4")
      XCTAssertEqual(language("reminders.overdue.skip", table: "Planning"), "Пропустить")
      XCTAssertEqual(language("scheduled.markAsPaid", table: "Planning"), "Провести")
    }
  }

#endif
