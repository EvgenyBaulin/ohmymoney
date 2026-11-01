import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Operations dragged out of «Операции» into Numbers or Mail, or copied with ⌘C: a table with a
/// header row (`OperationsPasteTable`) — tab-separated text for Numbers and any text field, an
/// HTML table for Mail. The amounts go with it even while «Скрыть суммы» hides them on the screen:
/// a drag is a deliberate hand-over. Only operations go: a transfer between the owner's accounts
/// is neither income nor spending and has no row in such a table.
@MainActor
enum OperationsPasteboard {
  /// The words of the table in the interface language.
  static func labels(_ environment: AppEnvironment) -> OperationsPasteTable.Labels {
    func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }
    let kinds = Dictionary(
      uniqueKeysWithValues: TransactionKind.allCases.map {
        ($0, t("mac.table.kind.\($0.rawValue)"))
      })
    return OperationsPasteTable.Labels(
      day: t("mac.table.day"), kind: t("mac.table.kind"), description: t("mac.table.description"),
      category: t("mac.table.category"), account: t("mac.table.account"),
      amount: t("mac.table.amount"), currency: t("mac.table.currency"),
      rubles: t("mac.table.rubles"), kinds: { kinds[$0] ?? $0.rawValue })
  }

  /// The table of the operations `ids` names, newest first, as the list has them.
  static func table(
    _ entries: [TransactionEntry], deps: AppDependencies, hidesAmounts: Bool
  ) -> PasteTable {
    let environment = deps.environment
    let dataset = deps.compute.wholeSnapshot?.dataset
    let categories = Dictionary(
      (dataset?.categories ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let accounts = Dictionary(
      (dataset?.paymentMethods ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let calendar = environment.calendar
    return OperationsPasteTable.make(
      entries, labels: labels(environment), hidesAmounts: hidesAmounts,
      day: { calendar.day(of: $0.occurredAt) }, categoryName: { categories[$0] },
      accountName: { accounts[$0] })
  }

  static func table(ids: Set<UUID>, deps: AppDependencies) -> PasteTable? {
    let entries = deps.store.entries(ids: ids)
    guard !entries.isEmpty else { return nil }
    // With amounts even while «Скрыть суммы» is on: a table dragged out on purpose is for the
    // spreadsheet it goes to (owner's answer).
    return table(entries, deps: deps, hidesAmounts: false)
  }

  /// One item that is the whole table, in the three forms another app may ask for.
  nonisolated static func provider(for table: PasteTable) -> NSItemProvider {
    let provider = NSItemProvider()
    let tabbed = Data(table.tabSeparated.utf8)
    let html = Data(table.html.utf8)
    for type in [UTType.utf8TabSeparatedText, .utf8PlainText] {
      provider.registerDataRepresentation(for: type, visibility: .all) { done in
        done(tabbed, nil)
        return nil
      }
    }
    provider.registerDataRepresentation(for: .html, visibility: .all) { done in
      done(html, nil)
      return nil
    }
    return provider
  }

  /// What a row of the table hands to a drag. A selected row hands the whole selection — once:
  /// only the first selected row of the list carries it, so Numbers gets one table, not one per
  /// row. A row outside the selection hands itself.
  static func dragItem(
    for operation: UUID, selection: Set<UUID>, listedOrder: [UUID], deps: AppDependencies
  ) -> NSItemProvider? {
    guard selection.contains(operation) else {
      return table(ids: [operation], deps: deps).map(provider(for:))
    }
    guard listedOrder.first(where: selection.contains) == operation else { return nil }
    return table(ids: selection, deps: deps).map(provider(for:))
  }

  /// ⌘C: the selection on the general pasteboard, as the drag would hand it.
  static func copy(_ selection: Set<UUID>, deps: AppDependencies) -> Bool {
    guard let table = table(ids: selection, deps: deps) else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(table.tabSeparated, forType: .tabularText)
    pasteboard.setString(table.tabSeparated, forType: .string)
    pasteboard.setString(table.html, forType: .html)
    AppLog.info(
      "operations.copied", .ui, "operations were copied as a table",
      [LogPair("count", .count(table.rows.count))])
    return true
  }
}
