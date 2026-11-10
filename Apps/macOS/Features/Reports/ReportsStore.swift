import AppCore
import Foundation
import Observation

/// The table of one Reports window: the model on screen and when it arrived. A
/// table is computed off the main thread through `ComputeStore.compute(_:)`; a newer request
/// cancels an older one (`.task(id:)`), and a cancelled build never lands. Tables are small —
/// one period, one grouping — so nothing is cached: going back builds again in a few
/// milliseconds.
@MainActor
@Observable
final class ReportsStore {
  private(set) var model: ReportsModel?
  private(set) var modelAt: Date?

  func load(_ request: ReportsRequest, ledger: Ledger, compute: ComputeStore) async {
    // `ReportsBuilder.model` does not throw: the only error here is the cancellation by a newer
    // request, whose model must not land. A builder that could fail would need `try` inside
    // the closure, and a state with «Повторить» for it — not a `try?` that waits for ever.
    guard
      let built = try? await compute.compute({ ReportsBuilder.model(request, ledger: ledger) }),
      !Task.isCancelled
    else { return }
    deliver(built)
  }

  /// The tab on screen: its tables, built together.
  private(set) var sheet: ReportsSheet?
  private(set) var sheetAt: Date?

  func load(_ request: ReportsSheetRequest, ledger: Ledger, compute: ComputeStore) async {
    guard
      let built = try? await compute.compute({
        ReportsSheetBuilder.sheet(request, ledger: ledger)
      }),
      !Task.isCancelled
    else { return }
    deliver(built)
  }

  func deliver(_ sheet: ReportsSheet, at instant: Date = Date()) {
    self.sheet = sheet
    sheetAt = instant
  }

  /// What a tab shows, by the rules of `state(for:data:model:at:)`: the tab of another table or
  /// period waits in «Считается» for its own; a tab with nothing in any of its tables has «Мало
  /// данных».
  nonisolated static func state<Data: Sendable>(
    for wanted: ReportsSheetRequest, data: BlockState<Data>, sheet: ReportsSheet?, at: Date?
  ) -> BlockState<ReportsSheet> {
    if let waiting = data.waiting { return waiting.never() }
    guard let sheet, let at, sheet.request == wanted else { return .calculating }
    guard sheet.hasData else { return .notEnoughData }
    return .ready(sheet, at: at)
  }

  func deliver(_ model: ReportsModel, at instant: Date = Date()) {
    self.model = model
    modelAt = instant
  }

  /// What the table shows:
  ///
  /// * the state of the data step while it is not ready — «Считается» until the first data
  ///   and during a full run, its failure with «Повторить»;
  /// * a model only for the request it was built for — another table, period or grouping is
  ///   «Считается» until its own is there, so a table of one grouping is never shown under
  ///   the name of another. A model of older data for the same request is: a light refresh
  ///   keeps the numbers on screen until the new ones are there;
  /// * «Мало данных» for a table with no lines.
  nonisolated static func state<Data: Sendable>(
    for wanted: ReportsRequest, data: BlockState<Data>, model: ReportsModel?, at: Date?
  ) -> BlockState<ReportsModel> {
    if let waiting = data.waiting { return waiting.never() }
    guard let model, let at, model.request == wanted else { return .calculating }
    guard model.table.hasData else { return .notEnoughData }
    return .ready(model, at: at)
  }
}
