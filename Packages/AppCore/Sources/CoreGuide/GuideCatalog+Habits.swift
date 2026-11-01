import Foundation

extension GuideCatalog {
  /// «Что нового»: the habits and the lessons.
  public static let whatsNew28 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 2, minor: 8)),
    cards: [
      GuideCard(
        id: "new28.missed",
        title: GuideText("Пропустили несколько дней?", "Missed a few days?"),
        body: GuideText(
          "Если несколько дней ничего не записано, в «Стоит посмотреть» появится «Восстановить по остаткам»: введите, сколько сейчас на счетах, — приложение покажет, сколько трат не записано, и поможет разложить их по дням.",
          "When nothing was written for a few days, «Worth a look» offers «Restore from balances»: type what is on the accounts now, and the app shows how much spending went unwritten and helps lay it out over the days."
        ),
        symbol: "calendar.badge.exclamationmark"),
      GuideCard(
        id: "new28.streak",
        title: GuideText("Серия и значки", "Streak and badges"),
        body: GuideText(
          "Дни с записями складываются в серию; один пропуск в неделю её не рвёт, а день без трат можно отметить вечером одной кнопкой. Значки за серии и за сверку каждый месяц — в «Итогах», без всплывающих окон и соревнований.",
          "Days with entries make a streak; one day missed a week does not break it, and a day without spending is marked with one button in the evening. Badges for streaks and for a count every month are in «Summaries», with no pop-ups and no contests."
        ),
        symbol: "flame"),
      GuideCard(
        id: "new28.why",
        title: GuideText("Зачем коплю", "Why I save"),
        body: GuideText(
          "У цели теперь есть заметка — зачем вы на неё копите. Приложение напомнит её, когда деньги цели потрачены, взнос уменьшен или цель удаляется.",
          "A goal now has a note on why you save for it. The app shows it when the goal money looks spent, the plan is lowered or the goal is deleted."
        ),
        symbol: "heart.text.square", target: GuideTarget.sidebarPlanning),
      GuideCard(
        id: "new28.lessons",
        title: GuideText("Уроки и первый месяц", "Lessons and the first month"),
        body: GuideText(
          "«Справка → Уроки»: подушка, кредиты, вклады, вычеты и кэшбэк — по пять карточек. Новым пользователям — список дел первого месяца по дням и режим новичка, в котором сложные разделы приглушены, пока им нечего показать.",
          "Help → Lessons: the cushion, loans, deposits, deductions and cashback, five cards each. New users get a checklist of the first month by days and the beginner mode, where the complex sections stay dimmed until they have something to show."
        ),
        symbol: "graduationcap"),
    ])
}
