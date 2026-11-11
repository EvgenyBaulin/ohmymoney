import AppCore
import AppDatabase
import Foundation

extension PlanningActions {
  /// The name alone changes; the archive state, price history, links and identity stay intact.
  /// The caller reads the book immediately before the explicit choice is applied.
  @discardableResult
  func renameNamesake(_ record: NamedRecord, to name: String, in book: PlanningBook) -> Bool {
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
    default: return false
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// Restoring does not consume or modify the new record, even when its name is the same.
  @discardableResult
  func restoreNamesake(_ record: NamedRecord, in book: PlanningBook) -> Bool {
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
    default: return false
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
