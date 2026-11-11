import AppCore
import AppDatabase
import Foundation

extension PlanningActions {
  /// The name alone changes; the archive state, price history, links and identity stay intact.
  /// The caller reads the book immediately before the explicit choice is applied.
  @discardableResult
  func renameNamesake(_ record: NamesakeRecord, to name: String, in book: PlanningBook) -> Bool {
    let name = Self.trimmed(name)
    guard !name.isEmpty else { return false }
    var rows = PlanningRows.empty
    switch record.kind {
    case .expectedIncome:
      guard var income = book.expected.first(where: { $0.id == record.id }) else { return false }
      income.name = name
      rows.expected = [income]
    case .scheduledPayment:
      guard var payment = book.scheduled.first(where: { $0.id == record.id }) else { return false }
      payment.name = name
      rows.scheduled = [payment]
    default: return renameDictionary(record, to: name)
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// Restoring does not consume or modify the new record, even when its name is the same.
  @discardableResult
  func restoreNamesake(_ record: NamesakeRecord, in book: PlanningBook) -> Bool {
    var rows = PlanningRows.empty
    switch record.kind {
    case .expectedIncome:
      guard var income = book.expected.first(where: { $0.id == record.id }), income.closed else {
        return false
      }
      income.closed = false
      rows.expected = [income]
    case .scheduledPayment:
      guard var payment = book.scheduled.first(where: { $0.id == record.id }), !payment.active
      else {
        return false
      }
      payment.active = true
      rows.scheduled = [payment]
    default: return restoreDictionary(record)
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// Read the stored value again so that dismissing two different pairs keeps both answers.
  @discardableResult
  func hideNamesake(_ pair: String, stored: String) -> Bool {
    let latest = (try? environment.settings?.string(Namesakes.hiddenPairsKey)) ?? stored
    return apply(
      PlanningChange(settings: [
        Namesakes.hiddenPairsKey: Namesakes.hiding(pair, in: latest)
      ]))
  }
}

extension PlanningActions {
  /// Goals and events go through the planning write; the plain dictionaries are saved by
  /// the repository, and the entry line learns the new spelling at once.
  fileprivate func renameDictionary(_ record: NamesakeRecord, to name: String) -> Bool {
    guard let references = environment.references else { return false }
    switch record.kind {
    case .goal:
      guard
        var goal = (try? references.goals(includeArchived: true))?.first(where: {
          $0.id == record.id
        })
      else { return false }
      goal.name = name
      return save(goal)
    case .event:
      guard
        var event = (try? references.events(includeArchived: true))?.first(where: {
          $0.id == record.id
        })
      else { return false }
      event.name = name
      return save(event)
    case .person:
      guard
        var person = (try? references.people(includeArchived: true))?.first(where: {
          $0.id == record.id
        })
      else { return false }
      person.name = name
      return written { try $0.save(person) }
    case .place:
      guard
        var place = (try? references.places(includeArchived: true))?.first(where: {
          $0.id == record.id
        })
      else { return false }
      place.name = name
      return written { try $0.save(place) }
    case .category:
      guard
        var category = (try? references.categories(includeArchived: true))?.first(where: {
          $0.id == record.id
        })
      else { return false }
      category.name = name
      return written { try $0.save(category) }
    default: return false
    }
  }

  /// Bringing a record back is never refused for its name.
  fileprivate func restoreDictionary(_ record: NamesakeRecord) -> Bool {
    switch record.kind {
    case .goal:
      return GoalsBlock.restore(record.id, with: self, references: environment.references)
    case .event: return written { try $0.restore(record.id, in: .events) }
    case .person: return written { try $0.restore(record.id, in: .people) }
    case .place: return written { try $0.restore(record.id, in: .places) }
    case .category: return written { try $0.restoreCategory(record.id) }
    default: return false
    }
  }

  private func written(_ write: (ReferenceRepository) throws -> Void) -> Bool {
    guard environment.attempt("references.namesake", on: environment.references, write) else {
      return false
    }
    environment.refreshVocabulary()
    environment.scheduleBackup()
    return true
  }
}
