import AppCore
import AppDatabase
import Foundation
import SwiftUI

/// «При первом запуске сверить список с ежедневными курсами ЦБ и сообщить, если какой-то
/// валюты нет».
///
/// Once per database: the rate service is asked for today's table the way the entry line asks
/// for a day — the cache first, the bank only when the day is not there — and the enabled list
/// is compared with the latest table of the bank in the cache. What it lacks is raised on the
/// environment for the main window to say (`CurrencyNotice`). A check that reached no table of
/// the last two weeks knows nothing: it says nothing and is left to the next launch, so a first
/// launch without the network is not taken for a list that is fine.
@MainActor
enum CurrencyCheck {
  /// The day the list was checked, in the settings of the database.
  static let doneKey = "currencies.checkedAtBank"
  /// How old the latest table of the bank may be and still stand for its daily one: the New
  /// Year holidays leave the longest gap between two publications, about ten days.
  static let freshnessInDays = 14

  /// A second window starting beside the first finds the check under way and leaves it.
  private static var isRunning = false

  static func runOnce(
    _ environment: AppEnvironment, service: RateService? = nil,
    today: DateOnly = CalendarContext.moscow.day(of: Date())
  ) async {
    guard !isRunning, let settings = environment.settings,
      let service = service ?? environment.rateService
    else { return }
    // An unreadable setting is not an unchecked list: nothing is asked on a guess.
    guard case .success(nil) = Result(catching: { try settings.string(doneKey) }) else { return }
    isRunning = true
    defer { isRunning = false }

    let enabled = (try? settings.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    let foreign = enabled.filter { $0 != .rub }
    if let probe = foreign.first {
      // Asks the bank only when the cache has no table for today, and stores all it gives.
      _ = await service.rate(for: probe, on: today)
    }
    // The quit may have closed the environment meanwhile: nothing more is read or written.
    guard let rates = environment.rates, let settings = environment.settings else { return }

    var missing: [CurrencyCode] = []
    if !foreign.isEmpty {
      let oldest = CalendarContext.moscow.adding(days: -freshnessInDays, to: today)
      guard let table = latestTable(in: (try? rates.allRates()) ?? [], notAfter: today),
        table.day >= oldest
      else {
        AppLog.info(
          "currencies.checkDeferred", .rates,
          "no daily table of the bank at hand: the enabled currencies wait for the next launch",
          [LogPair("enabled", .count(foreign.count))])
        return
      }
      missing = foreign.filter { !table.currencies.contains($0) }
    }
    _ = environment.attempt("currencies.checked", on: settings) {
      try $0.set(doneKey, to: today.iso)
    }
    AppLog.info(
      "currencies.checked", .rates, "the enabled currencies were checked against the bank",
      [LogPair("enabled", .count(foreign.count)), LogPair("missing", .count(missing.count))])
    if !missing.isEmpty { environment.currenciesMissingAtBank = missing }
  }

  /// Which of `currencies` the latest table of the bank in the cache lacks — the mark of
  /// Settings → Currencies. Empty while the cache holds no table of the bank: nothing is
  /// known then, and nothing is marked.
  nonisolated static func notPublished(
    _ currencies: [CurrencyCode], in rates: [Rate]
  ) -> [CurrencyCode] {
    guard let table = latestTable(in: rates, notAfter: nil) else { return [] }
    return currencies.filter { $0 != .rub && !table.currencies.contains($0) }
  }

  /// The latest day the bank (or its mirror) published, with every currency the cache holds
  /// for it. A rate typed by hand or imported for that day counts too: it is why the bank's
  /// own rate was not stored, not a sign the bank lacks the currency.
  nonisolated static func latestTable(
    in rates: [Rate], notAfter today: DateOnly?
  ) -> (day: DateOnly, currencies: Set<CurrencyCode>)? {
    let published = rates.filter { rate in
      !rate.source.isProtected && today.map { rate.date <= $0 } ?? true
    }
    guard let day = published.map(\.date).max() else { return nil }
    return (day, Set(rates.filter { $0.date == day }.map(\.currency)))
  }
}

/// The main window says once which enabled currencies the bank's daily table lacks. It waits
/// for the offer of a report and for any other question of the window: one question at a time.
/// «OK» spends it; the mark in Settings → Currencies stays.
struct CurrencyNotice: ViewModifier {
  let deps: AppDependencies
  /// Another question of the window is on screen.
  let waits: Bool

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  func body(content: Content) -> some View {
    content
      .alert(
        t("currencies.missing.title"),
        isPresented: Binding(
          get: {
            environment.lock.lets(
              !environment.currenciesMissingAtBank.isEmpty && !environment.offersProblemReport
                && !waits)
          },
          set: { _ in })
      ) {
        Button(environment.language("action.ok")) {
          environment.currenciesMissingAtBank = []
        }
      } message: {
        Text(
          verbatim: environment.language.format(
            "currencies.missing.message", table: "Settings",
            environment.currenciesMissingAtBank.map(\.code).joined(separator: ", ")))
      }
  }
}
