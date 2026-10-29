import CoreAccounting
import CoreKit
import Foundation

/// One fill-up of a car: the mileage on the dashboard, the litres put in and what they cost.
public struct FuelFill: Hashable, Sendable, Identifiable {
  public var transactionId: UUID
  public var day: DateOnly
  public var odometerKm: Int
  /// Litres, above zero.
  public var liters: Decimal
  public var costRubE4: AmountE4
  public var id: UUID { transactionId }

  public init(
    transactionId: UUID, day: DateOnly, odometerKm: Int, liters: Decimal, costRubE4: AmountE4
  ) {
    self.transactionId = transactionId
    self.day = day
    self.odometerKm = odometerKm
    self.liters = liters
    self.costRubE4 = costRubE4
  }
}

/// The consumption between two fill-ups.
public struct FuelSegment: Hashable, Sendable {
  public var from: FuelFill
  public var to: FuelFill
  public var distanceKm: Int
  /// Litres per 100 km, two digits: the litres of the later fill-up over the distance since the
  /// earlier one (the tank is taken full each time).
  public var litersPer100Km: Decimal
  public var costPer100KmRubE4: AmountE4
}

/// Fuel economy of a car from its fill-ups. A fill-up is an expense with the mileage
/// (`odometerKm`) and the litres in its note («45л», «45,5 л», "45 l", "45 liters"); the fill-ups of
/// one car are told apart by the tag of the car (`VehicleCost`) or by the caller's own selection.
public enum FuelEconomy {
  /// The litres named in a note: a number right before a litre word. `nil` when there is none, or
  /// it is zero or above 500.
  public static func liters(inNote note: String?) -> Decimal? {
    guard let note else { return nil }
    let words = note.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" })
    var found: Decimal?
    for (index, rawWord) in words.enumerated() {
      let word = String(rawWord)
      // "45л", "45.5l": the unit is glued to the number.
      if let split = unitSplit(word) {
        found = found ?? split
        continue
      }
      // "45 л": the number, then the unit as the next word.
      guard index + 1 < words.count, litersUnits.contains(String(words[index + 1])),
        let value = number(word)
      else { continue }
      found = found ?? value
    }
    guard let value = found, value > 0, value <= 500 else { return nil }
    return value
  }

  /// The fill-ups among `entries`: live expenses that carry a mileage and litres. With `tagId`,
  /// only those with a part under that tag.
  public static func fills(
    entries: [TransactionEntry], tagBook: TagBook? = nil, tagId: UUID? = nil,
    calendar: CalendarContext
  ) -> [FuelFill] {
    let tagged: Set<UUID>? = tagId.flatMap { id in tagBook.map { $0.partIds(of: id) } }
    var found: [FuelFill] = []
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        let km = transaction.odometerKm, km > 0,
        let liters = liters(inNote: transaction.note ?? entry.parts.compactMap(\.note).first)
      else { continue }
      if let tagged, !entry.parts.contains(where: { tagged.contains($0.id) }) { continue }
      found.append(
        FuelFill(
          transactionId: transaction.id,
          day: calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId),
          odometerKm: km, liters: liters, costRubE4: transaction.amountRubE4))
    }
    return found.sorted { ($0.odometerKm, $0.day) < ($1.odometerKm, $1.day) }
  }

  /// The segments between neighbouring fill-ups by mileage; a pair whose mileage did not grow is
  /// left out.
  public static func segments(_ fills: [FuelFill]) -> [FuelSegment] {
    let ordered = fills.sorted { ($0.odometerKm, $0.day) < ($1.odometerKm, $1.day) }
    var result: [FuelSegment] = []
    for (previous, next) in zip(ordered, ordered.dropFirst()) {
      let distance = next.odometerKm - previous.odometerKm
      guard distance > 0 else { continue }
      let per100 = DecimalMath.round(next.liters * 100 / Decimal(distance), scale: 2)
      let cost = PurchaseMath.scaled(
        next.costRubE4, by: AmountE4(whole: 100), over: AmountE4(whole: Int64(distance)))
      result.append(
        FuelSegment(
          from: previous, to: next, distanceKm: distance, litersPer100Km: per100,
          costPer100KmRubE4: cost))
    }
    return result
  }

  /// The average over all segments: the litres burned over the kilometres driven, not the mean of
  /// the means. `nil` without a segment.
  public static func average(_ segments: [FuelSegment]) -> Decimal? {
    let km = segments.reduce(0) { $0 + $1.distanceKm }
    guard km > 0 else { return nil }
    let liters = segments.reduce(Decimal(0)) { $0 + $1.to.liters }
    return DecimalMath.round(liters * 100 / Decimal(km), scale: 2)
  }

  /// The question after a fill-up: «Сколько проехали с прошлой заправки?» — asked when the setting
  /// is on and the fill-up has litres but no mileage yet.
  public static func shouldAskMileage(
    _ transaction: Transaction, settings: PurchaseSettings
  ) -> Bool {
    settings.fuelAskMileage && transaction.kind == .expense && transaction.odometerKm == nil
      && liters(inNote: transaction.note) != nil
  }

  /// The mileage now, from «проехали N км» since the fill-up before.
  public static func odometer(afterDriving km: Int, since previous: FuelFill?) -> Int? {
    guard km > 0, let previous else { return nil }
    return previous.odometerKm + km
  }

  private static let litersUnits: Set<String> = [
    "л", "л.", "l", "l.", "лит", "литр", "литра", "литров", "liter", "liters", "litre", "litres",
    "ltr",
  ]

  private static func number(_ word: String) -> Decimal? {
    let text = word.replacingOccurrences(of: ",", with: ".")
    guard text.first?.isNumber == true, text.allSatisfy({ $0.isNumber || $0 == "." }),
      text.filter({ $0 == "." }).count <= 1
    else { return nil }
    return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
  }

  /// "45л" → 45: a number and a litre word in one word.
  private static func unitSplit(_ word: String) -> Decimal? {
    let digits = word.prefix { $0.isNumber || $0 == "." || $0 == "," }
    guard !digits.isEmpty else { return nil }
    let unit = String(word.dropFirst(digits.count))
    guard litersUnits.contains(unit) else { return nil }
    return number(String(digits))
  }
}

/// What a car costs to own and to drive: the cost of ownership of its tag, and the fuel and the
/// kilometres on top of it.
public struct VehicleCost: Hashable, Sendable {
  public var ownership: OwnershipCost
  /// Fuel spent among the running costs: the fill-ups that carry a mileage.
  public var fuelRubE4: AmountE4
  /// Kilometres between the first and the last mileage noted under the tag.
  public var distanceKm: Int
  /// The total cost of ownership per kilometre driven; `nil` below 1 km.
  public var perKmRubE4: AmountE4?
  public var fuelAverageLitersPer100Km: Decimal?

  public static func compute(
    _ subject: OwnershipSubject, entries: [TransactionEntry], tagBook: TagBook, today: DateOnly,
    calendar: CalendarContext
  ) -> VehicleCost {
    let ownership = OwnershipCost.compute(
      subject, entries: entries, tagBook: tagBook, today: today, calendar: calendar)
    let fills = FuelEconomy.fills(
      entries: entries, tagBook: tagBook, tagId: subject.tagId, calendar: calendar)
    let tagged: Set<UUID> = subject.tagId.map { tagBook.partIds(of: $0) } ?? []
    var fuel = AmountE4.zero
    var kilometres: [Int] = []
    for entry in entries where !entry.transaction.isDeleted {
      guard entry.parts.contains(where: { tagged.contains($0.id) }) else { continue }
      if let km = entry.transaction.odometerKm, km > 0 { kilometres.append(km) }
    }
    for fill in fills { fuel += fill.costRubE4 }
    let distance = (kilometres.max() ?? 0) - (kilometres.min() ?? 0)
    var perKm: AmountE4?
    if distance >= 1 {
      perKm = PurchaseMath.scaled(
        ownership.totalRubE4, by: AmountE4(whole: 1), over: AmountE4(whole: Int64(distance)))
    }
    return VehicleCost(
      ownership: ownership, fuelRubE4: fuel, distanceKm: max(0, distance), perKmRubE4: perKm,
      fuelAverageLitersPer100Km: FuelEconomy.average(FuelEconomy.segments(fills)))
  }
}
