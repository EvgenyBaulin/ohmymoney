import Foundation

extension GuideCatalog {
  /// «Что нового» of the versions that came out together as 2.13.0 (2.9, 2.11, 2.13), and of the
  /// fixes of 2.13.1 with the new navigation. A version is matched by its major and minor
  /// numbers, so the fixes of 2.13.1 live in the card set of 2.13.
  public static let whatsNew29 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 2, minor: 9)),
    cards: [
      GuideCard(
        id: "new29.cashback",
        title: GuideText("Кэшбэк с лимитом и выбором", "Cashback with a cap and a choice"),
        body: GuideText(
          "У правила и у счёта можно задать месячный лимит кэшбэка и день, когда банк открывает выбор категорий. В начале месяца лист предложит категории и сопоставит категории банка с вашими; «Какая карта здесь» подскажет карту, а «Стоит посмотреть» — упущенный кэшбэк за три месяца.",
          "A rule and an account can have a monthly cashback cap and the day the bank opens the choice of categories. At the start of the month a sheet suggests the categories and maps the bank's categories to yours; «Which card here» names the card, and «Worth a look» shows cashback missed over three months."
        ),
        symbol: "percent"),
      GuideCard(
        id: "new29.history",
        title: GuideText("История изменений", "History of changes"),
        body: GuideText(
          "В операции появилась вкладка «История»: кто и когда её менял, с каким устройством. Удаление против правки решает время. Ключ обмена хранится в связке ключей, а запасной листок из 24 слов с QR-кодом можно напечатать.",
          "An operation has a «History» tab: who changed it, when and on which device. A delete against an edit is settled by time. The exchange key lives in the keychain, and a recovery sheet of 24 words with a QR code can be printed."
        ),
        symbol: "clock.arrow.circlepath"),
    ])

  public static let whatsNew211 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 2, minor: 11)),
    cards: [
      GuideCard(
        id: "new211.moveIn",
        title: GuideText("Переезд из другого приложения", "Moving in from another app"),
        body: GuideText(
          "«Файл → Перенести из другого приложения…» (на iPhone и iPad — «Настройки → Счета») читает выгрузки CoinKeeper, Zenmoney, Money Manager и любой таблицы: CSV, текст с табуляцией и Excel. Колонки угадываются, счета и категории сопоставляются с вашими, перед записью виден предпросмотр. Сначала делается копия базы, а один ⌘Z возвращает весь перенос.",
          "«File → Move In from Another App…» (Settings → Accounts on iPhone and iPad) reads exports of CoinKeeper, Zenmoney, Money Manager and any spreadsheet: CSV, tab-separated text and Excel. Columns are guessed, accounts and categories are paired with yours, and a preview shows before anything is written. A copy of the database is made first, and one ⌘Z takes the whole move back."
        ),
        symbol: "square.and.arrow.down.on.square"),
    ])

  public static let whatsNew213 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 2, minor: 13)),
    cards: [
      GuideCard(
        id: "new213.messages",
        title: GuideText("СМС и пуш банка", "Bank texts and pushes"),
        body: GuideText(
          "Передайте СМС или пуш через «Быстрые команды» — уведомление предложит записать операцию (можно сразу, без вопроса, в настройках). Повторы не предлагаются, названия магазинов, которые вы даёте, запоминаются, остаток банка сверяется со счётом, а сам текст не сохраняется.",
          "Pass a text or a push through Shortcuts and a notification offers to record the operation (straight away, without asking, if you set so). Duplicates are not offered again, the shop names you give are remembered, the bank's balance is compared with the account's, and the text itself is never stored."
        ),
        symbol: "message.badge"),
      GuideCard(
        id: "new213.quiet",
        title: GuideText("Цифры пересчитываются молча", "Figures recount quietly"),
        body: GuideText(
          "Блок держит прежнее значение, пока считается новое, и не мигает «Считается». Если цифра посчитана до последней записи, рядом серым стоит «цифры от ЧЧ:ММ».",
          "A block keeps its last value while the new one is counted and does not flash «Calculating». A figure counted before the last write says «as of HH:MM» in grey beside it."
        ),
        symbol: "arrow.triangle.2.circlepath"),
      GuideCard(
        id: "new213.statement",
        title: GuideText("Выписка учится на вашем вводе", "A statement learns from your entries"),
        body: GuideText(
          "Строка выписки, которую вы уже ввели руками, сливается с ней, а найденные пары сначала подтверждаются — ничего не записывается без вашего «Да».",
          "A statement row you have already entered by hand merges with it, and the pairs found are confirmed first: nothing is written without your Yes."
        ),
        symbol: "doc.text.magnifyingglass"),
      GuideCard(
        id: "new213.navigation",
        title: GuideText("Новая навигация", "New navigation"),
        body: GuideText(
          "На Mac и iPad разделы — в боковой панели, ⌘1…⌘9 открывают их по порядку. На iPhone внизу четыре раздела и «Ещё»: по умолчанию значки, у выбранного раздела видна подпись. На Mac «Показать, куда нажимать» в меню «Справка» проведёт по всем девяти.",
          "On the Mac and the iPad the sections are in the sidebar, and ⌘1…⌘9 open them in order. On the iPhone the bar at the bottom holds four sections and «More»: icons by default, the chosen section shows its name. On the Mac, «Show Where to Click» in the Help menu walks through all nine."
        ),
        symbol: "sidebar.left",
        target: GuideTarget.sidebarOverview),
    ])
}
