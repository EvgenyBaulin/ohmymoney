import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Spending rule references survive entity changes")
struct RuleReferenceLifecycleTests {
  enum Entity: CaseIterable, Sendable {
    case person, place, account, card
  }

  /// Each case has its own synthetic database, including when exchange recording is enabled.
  struct Fixture {
    let stack: DatabaseStack
    let entity: Entity
    let source = UUID()
    let target = UUID()
    let account = UUID()
    let bank = Bank(name: "Bank")

    init(_ entity: Entity, stack: DatabaseStack) throws {
      self.entity = entity
      self.stack = stack
      let references = ReferenceRepository(writer: stack.writer)
      switch entity {
      case .person:
        try references.save(Person(id: source, name: "Source"))
        try references.save(Person(id: target, name: "Target"))
      case .place:
        try references.save(Place(id: source, name: "Source"))
        try references.save(Place(id: target, name: "Target"))
      case .account:
        _ = try planning.apply(
          PlanningChange(
            upsert: PlanningRows(
              paymentMethods: [
                PaymentMethod(
                  id: source, name: "Source", kind: .card, currency: .rub, bankId: bank.id),
                PaymentMethod(
                  id: target, name: "Target", kind: .card, currency: .rub, isDefault: true,
                  bankId: bank.id),
              ], banks: [bank])))
      case .card:
        _ = try planning.apply(
          PlanningChange(
            upsert: PlanningRows(
              paymentMethods: [
                PaymentMethod(
                  id: account, name: "Account", kind: .card, currency: .rub, isDefault: true)
              ],
              cards: [
                PaymentCard(id: source, accountId: account, name: "Source"),
                PaymentCard(id: target, accountId: account, name: "Target"),
              ])))
      }
    }

    var planning: PlanningRepository { PlanningRepository(writer: stack.writer) }
    var rules: SpendingRulesRepository { SpendingRulesRepository(writer: stack.writer) }

    func conditions(_ id: UUID) -> [RuleCondition] {
      switch entity {
      case .person: [.kind(.expense)]
      case .place: [.place(id)]
      case .account: [.account(id)]
      case .card: [.card(id)]
      }
    }

    func actions(_ id: UUID) -> [RuleAction] {
      switch entity {
      case .person: [.setForPerson(id)]
      case .place: [.setPlace(id)]
      case .account, .card: [.setQuality(.good)]
      }
    }

    func change(merging: Bool) -> PlanningChange {
      switch entity {
      case .person, .place:
        let book: ReferenceBook = entity == .person ? .people : .places
        return PlanningChange(
          changingReferences: merging
            ? .merge(book: book, source: source, target: target)
            : .delete(book: book, ids: [source]))
      case .account:
        if merging {
          return PlanningChange(
            mergingAccounts: AccountMergePlan(
              sourceId: source,
              target: PaymentMethod(
                id: target, name: "Target", kind: .card, currency: .rub, isDefault: true,
                bankId: bank.id),
              at: Date(timeIntervalSince1970: 1_789_900_000)))
        }
        return PlanningChange(delete: PlanningRowIDs(paymentMethods: [source]))
      case .card:
        return PlanningChange(
          delete: PlanningRowIDs(cards: [source]), movingCards: merging ? [source: target] : [:])
      }
    }

    func append(conditions: [RuleCondition], actions: [RuleAction]) throws -> Rule {
      let at = Date(timeIntervalSince1970: 1_789_900_000)
      return try rules.append(
        Rule(
          name: "Synthetic rule", conditions: conditions, actions: actions,
          createdAt: at, updatedAt: at))
    }
  }

  @Test(arguments: Entity.allCases)
  func mergeDeduplicatesReferencesFiresOnAnOperationAndUndoRestoresTheRule(
    _ entity: Entity
  )
    throws
  {
    let fixture = try Fixture(entity, stack: TestSupport.makeStack())
    let conditions = fixture.conditions(fixture.source)
    let actions = fixture.actions(fixture.source)
    _ = try fixture.append(
      conditions: entity == .person ? conditions : conditions + fixture.conditions(fixture.target),
      actions: entity == .person || entity == .place
        ? actions + fixture.actions(fixture.target) : actions)
    let before = try fixture.rules.rules()
    let undo = try fixture.planning.apply(fixture.change(merging: true))
    let merged = try fixture.rules.rules()
    let rule = try #require(merged.first)
    #expect(rule.conditions == fixture.conditions(fixture.target))
    #expect(rule.actions == fixture.actions(fixture.target))

    var entry = try TestSupport.makeEntry()
    entry.transaction.placeId = fixture.target
    entry.transaction.paymentMethodId = fixture.target
    entry.transaction.cardId = fixture.target
    let verdict = RuleEngine.evaluate(RuleSubject(entry: entry), rules: merged)
    #expect(verdict.matchedRuleIds == [rule.id])
    switch entity {
    case .person: #expect(verdict.forWhom?.value == .person(fixture.target))
    case .place: #expect(verdict.place?.value == fixture.target)
    case .account, .card: #expect(verdict.quality?.value == .good)
    }
    try fixture.planning.revert(undo)
    #expect(try fixture.rules.rules() == before)
  }

  @Test(arguments: Entity.allCases)
  func deletionReleasesReferencesLikeCategoriesAndUndoRestoresTheRule(_ entity: Entity) throws {
    let fixture = try Fixture(entity, stack: TestSupport.makeStack())
    let original = try fixture.append(
      conditions: fixture.conditions(fixture.source), actions: fixture.actions(fixture.source))
    let undo = try fixture.planning.apply(fixture.change(merging: false))
    let deleted = try #require(try fixture.rules.rules().first)
    #expect(!deleted.enabled)
    #expect(deleted.conditions.flatMap(\.references).allSatisfy { $0.id != fixture.source })
    #expect(deleted.actions.flatMap(\.references).allSatisfy { $0.id != fixture.source })
    try fixture.planning.revert(undo)
    #expect(try fixture.rules.rules() == [original])
  }

  @Test(arguments: Entity.allCases, [true, false])
  func mergeAndDeletionUseUpdatesRecordedByExchange(_ entity: Entity, _ merging: Bool) throws {
    let device = try TestDevice("rules")
    let fixture = try Fixture(entity, stack: device.stack)
    let original = try fixture.append(
      conditions: fixture.conditions(fixture.source), actions: fixture.actions(fixture.source))
    let folder = InMemoryFolder()
    try device.exchange.flush(to: folder)
    // Replacing or reinserting a rule is forbidden: its ordinary UPDATE must reach exchange.
    try device.sql(
      """
      CREATE TRIGGER refuse_rule_insert BEFORE INSERT ON rules BEGIN
        SELECT RAISE(ABORT, 'Expected a rule UPDATE'); END;
      CREATE TRIGGER refuse_rule_delete BEFORE DELETE ON rules BEGIN
        SELECT RAISE(ABORT, 'Expected a rule UPDATE'); END;
      """)
    let undo = try fixture.planning.apply(fixture.change(merging: merging))
    try device.exchange.flush(to: folder)
    let journal = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: device.id, sequence: 1)))
    let update = try #require(journal.entries.first { $0.table == "rules" })
    #expect(update.op == .updated)
    #expect(update.base != nil)
    try fixture.planning.revert(undo)
    try device.exchange.flush(to: folder)
    let reverted = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: device.id, sequence: 2)))
    #expect(reverted.entries.first { $0.table == "rules" }?.op == .updated)
    #expect(try fixture.rules.rules() == [original])
  }

  @Test func deletingAnAccountAndItsCardRestoresBothReferencesInOneRule() throws {
    let fixture = try Fixture(.account, stack: TestSupport.makeStack())
    let card = PaymentCard(accountId: fixture.source, name: "Card")
    _ = try fixture.planning.apply(PlanningChange(upsert: PlanningRows(cards: [card])))
    let original = try fixture.append(
      conditions: [.account(fixture.source), .card(card.id), .kind(.expense)],
      actions: [.setQuality(.good)])
    let undo = try fixture.planning.apply(fixture.change(merging: false))
    #expect(try fixture.rules.rules().first?.conditions == [.kind(.expense)])
    try fixture.planning.revert(undo)
    #expect(try fixture.rules.rules() == [original])
  }

  @Test(arguments: Entity.allCases, [true, false])
  func aFailedRuleUpdateRollsBackTheEntityChange(_ entity: Entity, _ merging: Bool) throws {
    let fixture = try Fixture(entity, stack: TestSupport.makeStack())
    _ = try fixture.append(
      conditions: fixture.conditions(fixture.source), actions: fixture.actions(fixture.source))
    try fixture.stack.writer.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER refuse_rule_update AFTER UPDATE ON rules BEGIN
            SELECT RAISE(ABORT, 'Synthetic rule write failure'); END;
          """)
    }
    let before = try fixture.stack.writer.read { try TestSupport.contents($0) }
    #expect(throws: GRDB.DatabaseError.self) {
      try fixture.planning.apply(fixture.change(merging: merging))
    }
    #expect(try fixture.stack.writer.read { try TestSupport.contents($0) } == before)
  }

  @Test func undoReversesAMergeAndDeletionThatBothRewroteTheSameRule() throws {
    let fixture = try Fixture(.card, stack: TestSupport.makeStack())
    let references = ReferenceRepository(writer: fixture.stack.writer)
    let source = Place(name: "Source place")
    let target = Place(name: "Target place")
    try references.save(source)
    try references.save(target)
    let original = try fixture.append(
      conditions: [.card(fixture.source), .place(source.id)], actions: [.setQuality(.good)])
    var change = fixture.change(merging: false)
    change.changingReferences = .merge(book: .places, source: source.id, target: target.id)
    let undo = try fixture.planning.apply(change)
    #expect(try fixture.rules.rules().first?.conditions == [.place(target.id)])
    try fixture.planning.revert(undo)
    #expect(try fixture.rules.rules() == [original])
  }

  @Test(arguments: [Entity.person, .place, .account])
  func directDeletionAlsoReleasesRules(_ entity: Entity) throws {
    let fixture = try Fixture(entity, stack: TestSupport.makeStack())
    _ = try fixture.append(
      conditions: fixture.conditions(fixture.source), actions: fixture.actions(fixture.source))
    switch entity {
    case .person, .place:
      let result = try ReferenceRepository(writer: fixture.stack.writer).delete(
        [fixture.source], from: entity == .person ? .people : .places)
      #expect(result.deleted == [fixture.source])
    case .account:
      try AccountRepository(writer: fixture.stack.writer).delete(fixture.source)
    case .card: Issue.record("Cards are deleted through planning")
    }
    #expect(try fixture.rules.rules().first?.enabled == false)
  }
}
