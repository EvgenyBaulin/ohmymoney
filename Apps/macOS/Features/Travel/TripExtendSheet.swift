import AppCore
import AppDatabase
import SwiftUI

/// «Продлить поездку»: the last day moves to the one chosen, the mode comes back on and the card
/// goes away — one write (`TravelRepository.extend`). A day that is not later than the present
/// last day is not offered.
struct TripExtendSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let eventId: UUID
  @State private var day: DateOnly?

  var body: some View {
    let event = compute.snapshot?.dataset.events.first { $0.id == eventId }
    let first = (event?.endDate ?? environment.today).adding(days: 1)
    let chosen = max(day ?? first, first)
    VStack(alignment: .leading) {
      Text(verbatim: TravelText.t("travel.extend.title", environment))
        .appFont(.headline)
      Form {
        DatePicker(
          TravelText.t("travel.extend.until", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(chosen) },
            set: { day = environment.calendar.day(of: $0) }),
          in: environment.calendar.startOfDay(first)...,
          displayedComponents: .date
        )
        .accessibilityIdentifier("travel.extend.date")
      }
      .formStyle(.grouped)
      FormButtons(
        title: TravelText.t("travel.extend.confirm", environment), enabled: event != nil
      ) {
        guard let stack = environment.stack else { return false }
        let extended = try? TravelRepository(writer: stack.writer).extend(
          eventId: eventId, to: chosen)
        compute.refreshLight()
        return extended != nil
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 200)
  }
}
