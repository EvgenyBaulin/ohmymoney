import AppCore
import AppDatabase
import Foundation

extension TransactionsStore {
  /// Rules added together — the rules of an exchange file — as one step of ⌘Z.
  @discardableResult
  public func addRules(_ rules: [Rule], file: String = #fileID) -> Bool {
    guard !refuses("addRules", file), let spending, !isWritingInBackground else { return false }
    guard !rules.isEmpty else { return true }
    do {
      _ = try spending.save(rules)
      record(
        Landed(
          step: .spending(.rules(restore: [], remove: rules.map(\.id))),
          write: StoreWrite(planningChanged: true)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}

/// What opening an exchange file writes once the owner agrees: the categories the file brings
/// (nothing is renamed or removed), then the tags as one step of ⌘Z, then the rules as one
/// step. A category written is not a step of ⌘Z, as no category of the settings is.
@MainActor
enum RuleExchangeWriter {
  struct Outcome: Equatable {
    var categories = 0
    var tags = 0
    var rules = 0
    var failed = false
  }

  static func write(
    _ preview: RuleImportPreview, environment: AppEnvironment, store: TransactionsStore
  ) -> Outcome {
    var outcome = Outcome()
    for category in preview.categoriesToAdd {
      guard
        environment.attempt(
          "exchange.category", on: environment.references, { try $0.save(category) })
      else {
        outcome.failed = true
        return outcome
      }
      outcome.categories += 1
    }
    if outcome.categories > 0 { environment.scheduleBackup() }
    if !preview.tagsToAdd.isEmpty {
      guard let book = try? store.spending?.tagBook() else {
        outcome.failed = true
        return outcome
      }
      var after = book
      after.tags += preview.tagsToAdd.filter { added in
        !book.tags.contains { $0.id == added.id }
      }
      guard store.apply(TagEdit(before: book, after: after)) else {
        outcome.failed = true
        return outcome
      }
      outcome.tags = preview.tagsToAdd.count
    }
    if !preview.rulesToAdd.isEmpty {
      guard store.addRules(preview.rulesToAdd) else {
        outcome.failed = true
        return outcome
      }
      outcome.rules = preview.rulesToAdd.count
    }
    AppLog.info(
      "exchange.imported", .db, "an exchange file was opened",
      [
        LogPair("categories", .count(outcome.categories)), LogPair("tags", .count(outcome.tags)),
        LogPair("rules", .count(outcome.rules)),
      ])
    return outcome
  }
}

/// The directory of everything a rule can point at, as the exchange needs it, from the data.
extension ExchangeDirectory {
  init(dataset: Dataset) {
    self.init(
      categories: dataset.categories, places: dataset.places, tags: dataset.tagBook.tags,
      accounts: dataset.paymentMethods.map { NamedRecord(id: $0.id, name: $0.name) },
      cards: dataset.cards.map { NamedRecord(id: $0.id, name: $0.name) },
      people: dataset.people.map { NamedRecord(id: $0.id, name: $0.name) })
  }
}
