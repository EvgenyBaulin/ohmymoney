import CoreAnalytics
import CoreKit
import Foundation

/// The summary of a month as a Markdown file: the title, the totals, the categories, the
/// places, the cashback and the debts closed — the figures of «Итоги» (`PeriodSummary`), so a
/// file and the card of the same month never disagree.
///
/// The words come from the app (`text` with the keys below, in the interface language), and so
/// do the amounts (`money`, the way the screen writes them) and the names. With amounts hidden
/// («Скрыть суммы») no amount is written at all: the shares and the changes stay, being no sums.
public enum MonthMarkdown {
  /// The keys `text` is asked for. The app keeps them in its string catalog.
  public enum Key: String, CaseIterable, Sendable {
    case totals = "markdown.totals"
    case item = "markdown.item"
    case value = "markdown.value"
    case amount = "markdown.amount"
    case share = "markdown.share"
    case income = "markdown.income"
    case expenses = "markdown.expenses"
    case net = "markdown.net"
    case saved = "markdown.saved"
    case change = "markdown.change"
    case categories = "markdown.categories"
    case category = "markdown.category"
    case places = "markdown.places"
    case place = "markdown.place"
    case cashback = "markdown.cashback"
    case closedDebts = "markdown.closedDebts"
    case empty = "markdown.empty"
    case amountsHidden = "markdown.amountsHidden"
  }

  public struct Words: Sendable {
    public var text: @Sendable (Key) -> String
    /// «1,234 ₽» — an amount in rubles, as the screen writes it.
    public var money: @Sendable (AmountE4) -> String
    /// «12.5 %» from basis points; a change gets its sign from `signedPercent`.
    public var percent: @Sendable (Int) -> String
    public var signedPercent: @Sendable (Int) -> String
    public var categoryName: @Sendable (UUID) -> String?
    public var placeName: @Sendable (UUID) -> String?

    public init(
      text: @escaping @Sendable (Key) -> String, money: @escaping @Sendable (AmountE4) -> String,
      percent: @escaping @Sendable (Int) -> String,
      signedPercent: @escaping @Sendable (Int) -> String,
      categoryName: @escaping @Sendable (UUID) -> String?,
      placeName: @escaping @Sendable (UUID) -> String?
    ) {
      self.text = text
      self.money = money
      self.percent = percent
      self.signedPercent = signedPercent
      self.categoryName = categoryName
      self.placeName = placeName
    }
  }

  /// `title` — the name of the month in the interface language («Октябрь 2026»).
  public static func text(
    of summary: PeriodSummary, title: String, words: Words, hidesAmounts: Bool
  ) -> String {
    var out = "# \(cell(title))\n\n"
    guard summary.hasData else {
      return out + words.text(.empty) + "\n"
    }
    if hidesAmounts { out += "_\(words.text(.amountsHidden))_\n\n" }

    // The totals: what came in, what went out, what was left, the share kept, the change.
    var totals = ""
    if !hidesAmounts {
      totals += row(words.text(.income), words.money(summary.income))
      totals += row(words.text(.expenses), words.money(summary.expenses))
      totals += row(words.text(.net), words.money(summary.net))
    }
    if let saved = summary.savedBP { totals += row(words.text(.saved), words.percent(saved)) }
    if let change = summary.expensesChangeBP {
      totals += row(words.text(.change), words.signedPercent(change))
    }
    if !totals.isEmpty {
      out += "## \(words.text(.totals))\n\n"
      out += "| \(words.text(.item)) | \(words.text(.value)) |\n| --- | ---: |\n" + totals
    }

    let categories = summary.topCategories.compactMap { category -> (String, SummaryCategory)? in
      words.categoryName(category.categoryId).map { ($0, category) }
    }
    if !categories.isEmpty {
      out += "\n## \(words.text(.categories))\n\n"
      out += header(words.text(.category), words: words, hidesAmounts: hidesAmounts)
      for (name, category) in categories {
        out += line(
          name, amount: category.amount, shareBP: category.shareBP, words: words,
          hidesAmounts: hidesAmounts)
      }
    }

    let places = summary.topPlaces.compactMap { place -> (String, SummaryPlace)? in
      words.placeName(place.placeId).map { ($0, place) }
    }
    if !places.isEmpty {
      out += "\n## \(words.text(.places))\n\n"
      out += header(words.text(.place), words: words, hidesAmounts: hidesAmounts)
      for (name, place) in places {
        out += line(
          name, amount: place.amount, shareBP: place.shareBP, words: words,
          hidesAmounts: hidesAmounts)
      }
    }

    if !hidesAmounts, summary.cashback.raw > 0 {
      out += "\n\(words.text(.cashback)): \(words.money(summary.cashback))\n"
    }

    if !summary.closedDebts.isEmpty {
      out += "\n## \(words.text(.closedDebts))\n\n"
      for debt in summary.closedDebts { out += "- \(cell(debt.name))\n" }
    }
    return out
  }

  private static func row(_ name: String, _ value: String) -> String {
    "| \(cell(name)) | \(cell(value)) |\n"
  }

  private static func header(_ first: String, words: Words, hidesAmounts: Bool) -> String {
    hidesAmounts
      ? "| \(first) | \(words.text(.share)) |\n| --- | ---: |\n"
      : "| \(first) | \(words.text(.amount)) | \(words.text(.share)) |\n| --- | ---: | ---: |\n"
  }

  private static func line(
    _ name: String, amount: AmountE4, shareBP: Int, words: Words, hidesAmounts: Bool
  ) -> String {
    hidesAmounts
      ? "| \(cell(name)) | \(cell(words.percent(shareBP))) |\n"
      : "| \(cell(name)) | \(cell(words.money(amount))) | \(cell(words.percent(shareBP))) |\n"
  }

  /// Text inside a cell or a heading: a «|» would end the cell, a line break the row.
  static func cell(_ text: String) -> String {
    var out = ""
    for character in text {
      switch character {
      case "|": out += "\\|"
      case _ where character.isNewline: out += " "
      default: out.append(character)
      }
    }
    return out
  }
}
