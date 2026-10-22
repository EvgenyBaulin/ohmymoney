import AppCore
import AppDatabase
import SwiftUI

/// The strip over the window while a trip is on, and the card the morning after it ends:
/// «Поездка: Бали до 15 октября · валюта IDR · бюджет 100 000 ₽», «Сегодня потрачено … ·
/// осталось на день …», and «С возвращением! Поездка обошлась в …» with «Итог поездки»,
/// «Продлить» and «Закрыть». The mode only changes the defaults of the entry; the figures are the
/// core's (`TripSummary`, `TripAllowance`) and the strip lays them out. Nothing is shown while no
/// trip is on and none has just ended.
struct TripBanner: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appTheme) private var theme
  @State private var sheet: TravelSheet?

  /// The strip for today; `nil` while the data is not there yet.
  private var model: TripBannerModel? {
    guard let snapshot = compute.snapshot else { return nil }
    return TripBannerModel.make(
      dataset: snapshot.dataset, ledger: snapshot.ledger, rates: snapshot.planning.dayRates,
      today: environment.today)
  }

  var body: some View {
    Group {
      if let model, !model.isEmpty {
        VStack(spacing: 8) {
          if let mode = model.mode { modeStrip(mode) }
          if let welcome = model.welcome { welcomeCard(welcome) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    // The only thing the mode changes: the currency and the event a new operation starts with.
    .onChange(of: model?.mode.map(Self.entryDefaults), initial: true) { _, defaults in
      environment.tripEntryDefaults = defaults
    }
    // The day changes while the app is open as well as when it starts: a trip whose last day is
    // over turns the mode off and leaves its card for the morning.
    .task(id: environment.today) { await settleTheDay() }
    .sheet(item: $sheet) { sheet in
      sheetView(sheet).handingOver(dependencies)
    }
  }

  private static func entryDefaults(_ mode: TripBannerModel.Mode) -> TripMode.EntryDefaults {
    TripMode.EntryDefaults(currency: mode.event.tripCurrency, eventId: mode.event.id)
  }

  private func modeStrip(_ mode: TripBannerModel.Mode) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline) {
        Label {
          Text(verbatim: TravelText.modeLine(mode, environment))
        } icon: {
          Image(systemName: "airplane")
        }
        .appFont(.callout)
        .accessibilityIdentifier("travel.mode.line")
        Spacer()
        Button(TravelText.t("travel.welcome.summary", environment)) {
          sheet = .summary(mode.event.id)
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("travel.mode.summary")
        Button(TravelText.t("travel.cards.button", environment)) { sheet = .cards }
          .buttonStyle(.link)
        Button(TravelText.t("travel.mode.off", environment)) { switchOff() }
          .buttonStyle(.link)
          .accessibilityIdentifier("travel.mode.off")
      }
      if let allowance = mode.allowance {
        Text(verbatim: TravelText.dayLine(allowance, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("travel.mode.day")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(theme.accentTint, in: .rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accentTintStrong, lineWidth: 0.5)
    }
  }

  private func welcomeCard(_ welcome: TripBannerModel.Welcome) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Label {
          Text(verbatim: TravelText.t("travel.welcome.title", environment))
            .appFont(.headline)
        } icon: {
          Image(systemName: "house")
        }
        Text(
          verbatim: TravelText.format(
            "travel.welcome.body", environment, welcome.event.name,
            environment.money.rounded(welcome.totalRub))
        )
        .appFont(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(TravelText.t("travel.welcome.summary", environment)) {
        sheet = .summary(welcome.event.id)
      }
      .accessibilityIdentifier("travel.welcome.summary")
      Button(TravelText.t("travel.welcome.extend", environment)) {
        sheet = .extend(welcome.event.id)
      }
      .accessibilityIdentifier("travel.welcome.extend")
      Button(TravelText.t("travel.welcome.close", environment)) { dismissCard() }
        .buttonStyle(.link)
        .accessibilityIdentifier("travel.welcome.close")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(theme.accentTint, in: .rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accentTintStrong, lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("travel.welcome")
  }

  @ViewBuilder
  private func sheetView(_ sheet: TravelSheet) -> some View {
    switch sheet {
    case .summary(let id): TripSummaryView(eventId: id)
    case .extend(let id): TripExtendSheet(eventId: id)
    case .cards: TravelCardsSheet()
    }
  }

  // MARK: Writing

  private func settleTheDay() async {
    guard let stack = environment.stack else { return }
    let today = environment.today
    let changed = await Task.detached { () -> Bool in
      let repository = TravelRepository(writer: stack.writer)
      guard let before = try? repository.settings(),
        let after = try? repository.afterDayChange(today: today)
      else { return false }
      return before != after
    }.value
    if changed { compute.refreshLight() }
  }

  private func switchOff() {
    guard let stack = environment.stack, let settings = compute.snapshot?.dataset.tripSettings
    else { return }
    try? TravelRepository(writer: stack.writer).save(TripMode.switchingOff(settings: settings))
    compute.refreshLight()
  }

  private func dismissCard() {
    guard let stack = environment.stack, let settings = compute.snapshot?.dataset.tripSettings
    else { return }
    try? TravelRepository(writer: stack.writer).save(TripMode.dismissingCard(settings: settings))
    compute.refreshLight()
  }
}

/// What the strip opens.
enum TravelSheet: Identifiable, Hashable {
  case summary(UUID)
  case extend(UUID)
  case cards

  var id: String {
    switch self {
    case .summary(let id): "summary-\(id)"
    case .extend(let id): "extend-\(id)"
    case .cards: "cards"
    }
  }
}
