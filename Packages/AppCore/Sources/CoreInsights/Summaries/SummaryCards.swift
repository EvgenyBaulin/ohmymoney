import CoreKit
import Foundation

/// The cards the screen «Итоги», the card of the year and the PDF are made of. They are lines
/// of keys and values; the app puts the words in.
///
/// With `hideAmounts` on («Скрыть суммы»), no line carries an amount of money: only shares,
/// per cents, names, days and counts remain. That is a promise the tests check on every card.
public enum SummaryCards {
  /// The cards of a month or of a year, in the order they are read.
  public static func cards(for summary: PeriodSummary, hideAmounts: Bool) -> [SummaryCard] {
    var cards: [SummaryCard] = []
    let periodArg: SummaryArg =
      summary.id.kind == .year ? .year(summary.period.start.year) : .month(summary.period.start.monthKey)

    // Totals
    var totals: [SummaryLine] = []
    if hideAmounts {
      if let saved = summary.savedBP {
        totals.append(SummaryLine("summaries.line.saved", [.percent(SummaryMath.percent(saved))]))
      }
    } else {
      totals.append(SummaryLine("summaries.line.income", [.money(summary.income)]))
      totals.append(SummaryLine("summaries.line.expenses", [.money(summary.expenses)]))
      totals.append(SummaryLine("summaries.line.net", [.money(summary.net)]))
    }
    if let change = summary.expensesChangeBP {
      let key = change > 0 ? "summaries.line.spendingUp" : change < 0 ? "summaries.line.spendingDown" : "summaries.line.spendingSame"
      totals.append(SummaryLine(key, [.percent(SummaryMath.percent(abs(change)))]))
    }
    if totals.isEmpty { totals.append(SummaryLine("summaries.line.amountsHidden")) }
    cards.append(SummaryCard(id: "totals", title: SummaryLine("summaries.card.totals", [periodArg]), lines: totals))

    if !summary.topCategories.isEmpty {
      let lines = summary.topCategories.map { item in
        hideAmounts
          ? SummaryLine(
            "summaries.line.category",
            [.category(item.categoryId), .percent(SummaryMath.percent(item.shareBP))])
          : SummaryLine(
            "summaries.line.categoryMoney",
            [
              .category(item.categoryId), .money(item.amount),
              .percent(SummaryMath.percent(item.shareBP)),
            ])
      }
      cards.append(SummaryCard(id: "categories", title: SummaryLine("summaries.card.categories"), lines: lines))
    }

    if let surprise = summary.surprise {
      var line: SummaryLine
      switch (surprise.moreBP, hideAmounts) {
      case (let more?, true):
        line = SummaryLine(
          "summaries.line.surpriseMore",
          [.category(surprise.categoryId), .percent(SummaryMath.percent(more))])
      case (let more?, false):
        line = SummaryLine(
          "summaries.line.surpriseMoreMoney",
          [
            .category(surprise.categoryId), .percent(SummaryMath.percent(more)),
            .money(surprise.amount), .money(surprise.usual),
          ])
      case (nil, true):
        line = SummaryLine("summaries.line.surpriseNew", [.category(surprise.categoryId)])
      case (nil, false):
        line = SummaryLine(
          "summaries.line.surpriseNewMoney", [.category(surprise.categoryId), .money(surprise.amount)])
      }
      cards.append(SummaryCard(id: "surprise", title: SummaryLine("summaries.card.surprise"), lines: [line]))
    }

    if let best = summary.bestMonth {
      var lines = [SummaryLine("summaries.line.bestMonth", [.month(best.month)])]
      if !hideAmounts { lines.append(SummaryLine("summaries.line.bestMonthNet", [.money(best.net)])) }
      cards.append(SummaryCard(id: "best", title: SummaryLine("summaries.card.best"), lines: lines))
    }

    if !hideAmounts, !summary.cashback.isZero {
      cards.append(
        SummaryCard(
          id: "cashback", title: SummaryLine("summaries.card.cashback"),
          lines: [SummaryLine("summaries.line.cashback", [.money(summary.cashback)])]))
    }

    if !summary.closedDebts.isEmpty {
      cards.append(
        SummaryCard(
          id: "debts", title: SummaryLine("summaries.card.debts", [.count(summary.closedDebts.count)]),
          lines: summary.closedDebts.map { SummaryLine("summaries.line.debtClosed", [.name($0.name)]) }))
    }

    if !summary.topPlaces.isEmpty {
      let lines = summary.topPlaces.map { item in
        hideAmounts
          ? SummaryLine(
            "summaries.line.place", [.place(item.placeId), .percent(SummaryMath.percent(item.shareBP))])
          : SummaryLine(
            "summaries.line.placeMoney",
            [.place(item.placeId), .money(item.amount), .percent(SummaryMath.percent(item.shareBP))])
      }
      cards.append(SummaryCard(id: "places", title: SummaryLine("summaries.card.places"), lines: lines))
    }

    if let mood = summary.moodTimesTen {
      var lines = [SummaryLine("summaries.line.moodAverage", [.tenths(mood), .count(summary.moods.count)])]
      if summary.id.kind == .month {
        lines += summary.moods.map {
          SummaryLine("summaries.line.moodWeek", [.day($0.week.start), .count($0.mood)])
        }
      }
      cards.append(SummaryCard(id: "mood", title: SummaryLine("summaries.card.mood"), lines: lines))
    }
    return cards
  }

  /// The five cards of a week.
  public static func cards(for week: WeekCards, hideAmounts: Bool) -> [SummaryCard] {
    var total = [SummaryLine("summaries.line.weekPurchases", [.count(week.total.purchases)])]
    if !hideAmounts {
      total.insert(SummaryLine("summaries.line.spent", [.money(week.total.expenses)]), at: 0)
      total.insert(SummaryLine("summaries.line.earned", [.money(week.total.income)]), at: 1)
    }

    let dearest: [SummaryLine]
    if let day = week.dearestDay {
      dearest =
        hideAmounts
        ? [SummaryLine("summaries.line.dearestDayOnly", [.weekday(day.day.weekday)])]
        : [SummaryLine("summaries.line.dearestDay", [.weekday(day.day.weekday), .money(day.amount)])]
    } else {
      dearest = [SummaryLine("summaries.line.noSpending")]
    }

    let category: [SummaryLine]
    if let top = week.topCategory {
      let share = SummaryArg.percent(SummaryMath.percent(top.shareBP))
      category =
        hideAmounts
        ? [SummaryLine("summaries.line.category", [.category(top.categoryId), share])]
        : [SummaryLine("summaries.line.categoryMoney", [.category(top.categoryId), .money(top.amount), share])]
    } else {
      category = [SummaryLine("summaries.line.noSpending")]
    }

    var comparison: [SummaryLine] = []
    if let change = week.comparison.changeBP {
      let key = change > 0 ? "summaries.line.weekMore" : change < 0 ? "summaries.line.weekLess" : "summaries.line.weekSame"
      comparison.append(SummaryLine(key, [.percent(SummaryMath.percent(abs(change)))]))
      if !hideAmounts {
        comparison.append(
          SummaryLine(
            "summaries.line.weekCompareMoney",
            [.money(week.comparison.expenses), .money(week.comparison.previousExpenses)]))
      }
    } else {
      comparison.append(SummaryLine("summaries.line.weekNoPrevious"))
    }

    let know = week.knowYou.map { [$0.line] } ?? [SummaryLine("summaries.line.noFact")]
    return [
      SummaryCard(id: "total", title: SummaryLine("summaries.card.weekTotal"), lines: total),
      SummaryCard(id: "dearestDay", title: SummaryLine("summaries.card.dearestDay"), lines: dearest),
      SummaryCard(id: "category", title: SummaryLine("summaries.card.weekCategory"), lines: category),
      SummaryCard(id: "comparison", title: SummaryLine("summaries.card.comparison"), lines: comparison),
      SummaryCard(id: "knowYou", title: SummaryLine("summaries.card.knowYou"), lines: know),
    ]
  }
}
