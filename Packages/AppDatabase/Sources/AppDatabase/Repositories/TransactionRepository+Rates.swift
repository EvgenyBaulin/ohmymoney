import AppCore
import CoreKit
import Foundation
import GRDB

/// The storage half of refining provisional rates. The rule — which operations a table can
/// now settle — is `RateTable.refinement` in the core; the pipeline's rate step reads the
/// usages here, asks the bank, runs the rule and writes the answer back
/// here.
extension TransactionRepository {
  /// Operations still carrying a provisional rate that the rule may refine: live, not in
  /// rubles, their rate neither entered by hand nor brought by an import. Oldest first.
  ///
  /// A refund taken back from a purchase is not among them: it keeps the rate of its purchase,
  /// and follows that purchase when it is refined, never the rate of its own day.
  ///
  /// `day` of each usage is the day of the operation in `calendar` — the calendar the entry
  /// panel resolved the rate with.
  public func provisionalUsages(calendar: CalendarContext) throws -> [RateTable.RateUsage] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, currency, occurred_at, rate_source, rate_date FROM transactions
          WHERE deleted_at IS NULL AND rate_provisional = 1 AND currency <> ?
            AND (rate_source IS NULL OR rate_source NOT IN (\(Self.protectedMarks)))
            AND id NOT IN (
              SELECT transaction_id FROM transaction_parts WHERE refund_of_part_id IS NOT NULL)
          ORDER BY occurred_at
          """,
        arguments: [CurrencyCode.rub.code] + StatementArguments(Self.protectedSources)
      ).compactMap { row -> RateTable.RateUsage? in
        guard let id = RowMapping.optionalUUID(row, "id"),
          let moment = RowMapping.readableInstant(row, "occurred_at")
        else { return nil }
        return RateTable.RateUsage(
          id: id,
          currency: CurrencyCode(row["currency"] ?? CurrencyCode.rub.code),
          day: calendar.day(of: moment),
          source: (row["rate_source"] as String?).flatMap(RateSource.init(rawValue:)),
          isProvisional: true,
          appliedRateDate: RowMapping.day(row, "rate_date"))
      }
    }
  }

  /// Writes refined rates in one transaction and returns how many operations took one.
  ///
  /// Compare and set: an operation takes its refinement only while it still carries what
  /// its usage was read with — provisional, the same currency, the same rate date, a rate
  /// not entered by hand and not imported, the same day. The rate step talks to the
  /// network between the read and this write; an operation edited in the meantime, given
  /// a rate by hand, or already refined by another run is left as it is.
  ///
  /// The rubles are worked out again from the row as it is inside the write: the
  /// operation's from its amount and the new rate, its parts' in proportion, the last one
  /// taking the rest (`AmountE4.allocated`). `rate_provisional` becomes the refinement's
  /// flag — what the table says of the day. A rate still published before the day of the
  /// operation keeps the flag, and a later run refines it again or settles it. Settling a
  /// day the bank never publishes writes the rate the operation already carries: only the
  /// flag and `updated_at` change.
  ///
  /// The money that came back for a refined part is balanced again in the same write
  /// (`settle(partIds:…)`, `MoneyBackSettlement`): a part the money now covers closes and what
  /// came back above it is income in «Доплаты» — `surplusNote` is that income's note, in the
  /// interface language —; one missing its rubles by no more than the drift of the rate closes
  /// with nothing written; a closed part's links and surplus follow its new rubles.
  ///
  /// What a ruble account was charged is the operation's rubles, so a charge in rubles follows
  /// the refined rubles; a rate typed from the statement is a manual one, never refined. A
  /// charge in another currency is never refined. The refunds taken back from a refined
  /// purchase take its rate too, and their stored rubles are worked out again from its parts,
  /// oldest refund first (`RefundRules.following`): they are for display, the figures follow
  /// the purchase anyway.
  ///
  /// A charge in rubles that follows the refined rate moves money on its account: the counts
  /// whose windows hold a refined operation, or one of its refunds, follow the books in the same
  /// write (`LiveCounts`). The write is the pipeline's, so it is no step of ⌘Z.
  ///
  /// `settled` is told, after the write, how much the money back of the refined parts moved.
  @discardableResult
  public func applyRefinements(
    _ refinements: [RateTable.RateRefinement],
    of usages: [RateTable.RateUsage],
    calendar: CalendarContext,
    at instant: Date = Date(),
    surplusNote: String? = nil,
    settled: (SettlementCounts) -> Void = { _ in }
  ) throws -> Int {
    let usageById = Dictionary(usages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var counts = SettlementCounts()
    let context = liveCounts
    let applied = try writer.write { db in
      counts = SettlementCounts()
      var applied = 0
      // What the refinements moved, as it was and as it is, for the counts.
      var moved: [(before: TransactionEntry?, after: TransactionEntry?)] = []
      for refinement in refinements {
        guard let usage = usageById[refinement.usageId],
          refinement.rate.currency == usage.currency,
          let fresh = try Self.entry(id: usage.id, db: db),
          calendar.day(of: fresh.transaction.occurredAt) == usage.day,
          let rubles = try? refinement.rate.toRubles(fresh.transaction.amountE4)
        else { continue }

        try db.execute(
          sql: """
            UPDATE transactions
            SET rate = ?, rate_date = ?, rate_source = ?, rate_provisional = ?,
                amount_rub_e4 = ?, updated_at = ?,
                account_amount_e4 = CASE WHEN account_currency = ? THEN ?
                                         ELSE account_amount_e4 END
            WHERE id = ? AND rate_provisional = 1 AND currency = ? AND rate_date IS ?
              AND (rate_source IS NULL OR rate_source NOT IN (\(Self.protectedMarks)))
            """,
          arguments: [
            RowMapping.string(refinement.rate.perUnit), refinement.rate.date.iso,
            refinement.rate.source.rawValue, refinement.isProvisional, rubles.raw,
            StoredInstant.databaseValue(instant),
            CurrencyCode.rub.code, rubles.raw,
            usage.id.uuidString, usage.currency.code, usage.appliedRateDate?.iso,
          ] + StatementArguments(Self.protectedSources))
        guard db.changesCount == 1 else { continue }

        let shares = rubles.allocated(
          proportionallyTo: fresh.parts.map(\.amountE4), outOf: fresh.transaction.amountE4)
        for (part, share) in zip(fresh.parts, shares) where part.amountRubE4 != share {
          try db.execute(
            sql: "UPDATE transaction_parts SET amount_rub_e4 = ? WHERE id = ?",
            arguments: [share.raw, part.id.uuidString])
        }
        let settlement = try Self.settle(
          partIds: fresh.parts.filter(\.reimbursable).map(\.id),
          rublesBefore: Dictionary(
            fresh.parts.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first }),
          setting: SettlementSetting(surplusNote: surplusNote), at: instant, db: db)
        counts = counts + settlement.counts
        let refined = try Self.entry(id: fresh.id, db: db)
        moved.append((fresh, refined))
        moved +=
          settlement.operationsBefore.map { ($0, nil) } + settlement.written.map { (nil, $0) }
        if fresh.transaction.kind == .expense, let refined {
          let refunds = try Self.followingRefunds(of: refined, at: instant, db: db)
          moved += refunds.map { ($0, nil) }
          moved += try Self.entries(ids: refunds.map(\.id), db: db).map { (nil, $0) }
        }
        applied += 1
      }
      let touch = try LiveCountsWriter.touch(
        entries: moved, calendar: context.calendar, lookups: WriteLookups(), db: db)
      _ = try LiveCountsWriter.settle(touch, context: context, now: instant, db: db)
      return applied
    }
    settled(counts)
    return applied
  }

  /// The live refunds taken back from `purchase` written again as they follow it
  /// (`RefundRules.following`): its rate, and rubles worked out again from its parts, oldest
  /// refund first. Returns them as they were, for undo; only the ones that changed.
  static func followingRefunds(
    of purchase: TransactionEntry, at instant: Date, db: Database
  ) throws -> [TransactionEntry] {
    let partIds = purchase.parts.map(\.id.uuidString)
    guard !partIds.isEmpty else { return [] }
    let marks = databaseQuestionMarks(count: partIds.count)
    let ids = try String.fetchAll(
      db,
      sql: """
        SELECT t.id FROM transactions t
        WHERE t.deleted_at IS NULL AND t.kind = ?
          AND t.id IN (
            SELECT transaction_id FROM transaction_parts WHERE refund_of_part_id IN (\(marks)))
        ORDER BY t.occurred_at, t.rowid
        """,
      arguments: [TransactionKind.refund.rawValue] + StatementArguments(partIds)
    ).compactMap(UUID.init(uuidString:))
    let refunds = try ids.compactMap { try entry(id: $0, db: db) }
    let followed = RefundRules.following(purchase: purchase, refunds: refunds)
    let before = Dictionary(refunds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var previous: [TransactionEntry] = []
    for refund in followed {
      guard let old = before[refund.id] else { continue }
      var next = refund
      next.transaction.updatedAt = instant
      try write(next, over: old, db: db)
      previous.append(old)
    }
    return previous
  }

  /// Sources whose rates are never overwritten automatically — a rate entered by hand or
  /// brought by an import — straight from `RateSource.isProtected`.
  private static let protectedSources = RateSource.allCases.filter(\.isProtected).map(\.rawValue)
  private static let protectedMarks = databaseQuestionMarks(count: protectedSources.count)
}
