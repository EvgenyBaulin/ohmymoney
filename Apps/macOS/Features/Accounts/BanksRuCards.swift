import AppCore
import SwiftUI

/// The card count across all banks against the legal cap on cards per person: how many cards the
/// owner holds, how many fit, and the ones nothing was paid with for a long time.
struct CardCountCard: View {
  @Dependency(\.environment) private var environment
  let status: CardCountStatus

  var body: some View {
    ComputedBlock(
      title: BanksRuText.t("banksRu.cardCount.title", environment),
      state: .ready(status, at: environment.now()), retry: nil
    ) { status in
      VStack(alignment: .leading, spacing: 4) {
        let lines = BanksRuText.cardCountLines(status, today: environment.today, environment)
        Label {
          Text(verbatim: lines[0]).monospacedDigit()
        } icon: {
          Image(systemName: status.isNear ? "exclamationmark.triangle" : "creditcard.and.123")
        }
        ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
          Text(verbatim: line).appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(verbatim: BanksRuText.t("banksRu.cardCount.hint", environment))
          .appFont(.caption).foregroundStyle(.tertiary)
      }
    }
    .accessibilityIdentifier("bank.cardCount")
  }
}

/// The interest of the year and the tax it may bring: the free sum of the year, what was earned,
/// the forecast to the year's end, and the day the tax is due.
struct InterestTaxCard: View {
  @Dependency(\.environment) private var environment
  let year: InterestTax.Year

  var body: some View {
    ComputedBlock(
      title: BanksRuText.t("banksRu.interest.title", environment),
      state: .ready(year, at: environment.now()), retry: nil
    ) { year in
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(BanksRuText.interestLines(year, environment).enumerated()), id: \.offset) {
          _, line in
          Text(verbatim: line).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        Text(verbatim: BanksRuText.t("banksRu.interest.hint", environment))
          .appFont(.caption).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityIdentifier("bank.interestTax")
  }
}
