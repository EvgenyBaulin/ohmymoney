import Foundation

/// Every scenario of the guide. A new noticeable feature of a version brings a card to that
/// version's «Что нового» and, when there is something to do, a task of the tutorial.
public enum GuideCatalog {
  public static var scenarios: [GuideScenario] { [firstLaunch, tutorial] + whatsNew }

  /// The tasks of the tutorial for an owner who told the starter set `profile` (nil — no set):
  /// the tasks for everyone, the ones of his ways of living and answers, and none about a life
  /// the set says is not his.
  public static func tutorialTasks(for profile: GuideProfile?) -> [GuideTask] {
    tutorial.tasks.filter { $0.audience.includes(profile) }
  }

  // MARK: First launch

  public static let firstLaunch = GuideScenario(
    kind: .firstLaunch,
    cards: [
      GuideCard(
        id: "first.welcome",
        title: GuideText(
          "OhMyMoney — учёт денег на этом Mac", "OhMyMoney keeps your money on this Mac"),
        body: GuideText(
          "Записывайте траты и доходы, а OhMyMoney посчитает, куда уходят деньги и сколько можно тратить.",
          "Write down what you spend and earn; OhMyMoney works out where the money goes and how much you can spend."
        ),
        symbol: "sum"),
      GuideCard(
        id: "first.line",
        title: GuideText("Одна строка — одна запись", "One line, one record"),
        body: GuideText(
          "Наберите «кофе 300» и нажмите Return. Сумма, дата и счёт понимаются из строки; Tab открывает все поля.",
          "Type «coffee 300» and press Return. Amount, date and account are read from the line; Tab opens every field."
        ),
        symbol: "text.cursor", target: GuideTarget.entryLine),
      GuideCard(
        id: "first.categories",
        title: GuideText("Категории и оценка", "Categories and a verdict"),
        body: GuideText(
          "Каждая трата — в категории и с оценкой: хорошая, обычная или плохая. OhMyMoney учится на вашем выборе.",
          "Every expense has a category and a verdict: good, ordinary or bad. OhMyMoney learns from your choices."
        ),
        symbol: "square.grid.2x2"),
      GuideCard(
        id: "first.accounts",
        title: GuideText("Счета и сверка", "Accounts and counts"),
        body: GuideText(
          "Банк, счёт, карта. Раз в неделю сверьте остаток — разница станет видна сразу.",
          "Bank, account, card. Count the balance once a week and any difference shows at once."
        ),
        symbol: "building.columns"),
      GuideCard(
        id: "first.planning",
        title: GuideText("Сколько можно тратить", "What is free to spend"),
        body: GuideText(
          "Платежи, подписки, цели и лимиты — в «Планировании». Свободная сумма учитывает их все.",
          "Payments, subscriptions, goals and limits live in Planning. The free amount takes them all into account."
        ),
        symbol: "calendar", target: GuideTarget.sidebarPlanning),
      GuideCard(
        id: "first.privacy",
        title: GuideText("Ваши данные — только у вас", "Your data stays with you"),
        body: GuideText(
          "База лежит на этом Mac. В сеть уходят только запросы курсов ЦБ и проверка обновлений.",
          "The database stays on this Mac. Only exchange rates and update checks go to the network."
        ),
        symbol: "lock.shield"),
      GuideCard(
        id: "first.help",
        title: GuideText("Учитесь на учебных данных", "Practise on sample data"),
        body: GuideText(
          "«Справка → Учебный режим» — задания на учебной базе, ваша не трогается. «Справка → Показать, куда нажимать» — подписи на экране.",
          "Help → Tutorial gives you tasks on sample data; yours is not touched. Help → Show Where to Click labels the screen."
        ),
        symbol: "graduationcap"),
    ])

  // MARK: Tutorial

  // Every task is a few steps, one place each: the window darkens around the place, the words
  // beside it say what to press and why. A step that is typed does not move on by a click.

  /// Opens a section of the sidebar: the first step of the tasks that live there.
  private static func open(
    _ target: String, _ russian: String, _ english: String, keys: String,
    why: GuideText
  ) -> GuideHint {
    GuideHint(
      target: target, text: GuideText("Откройте «\(russian)»", "Open \(english)"), why: why,
      keys: keys, gesture: GuideText("Коснитесь «\(russian)»", "Tap \(english)"))
  }

  /// Types a line into the entry line and presses Return: the step of the tasks of a starter set.
  private static func type(_ text: GuideText, why: GuideText) -> GuideHint {
    GuideHint(
      target: GuideTarget.entryLine, text: text, why: why,
      gesture: GuideText("Коснитесь строки ввода", "Tap the entry line"), advancesOnClick: false)
  }

  public static let tutorial = GuideScenario(
    kind: .tutorial,
    tasks: [
      GuideTask(
        id: "task.coffee",
        title: GuideText("Запишите «кофе 300»", "Write down «coffee 300»"),
        hints: [
          GuideHint(
            target: GuideTarget.entryLine,
            text: GuideText("Щёлкните строку внизу", "Click the line below"),
            why: GuideText(
              "Сюда пишется каждая трата и каждый доход — одной строкой.",
              "Every expense and every income is written here, in one line."),
            keys: "⌘N", gesture: GuideText("Коснитесь строки ввода", "Tap the entry line")),
          type(
            GuideText(
              "Наберите в строке внизу «кофе 300» и нажмите Return",
              "Type «coffee 300» in the line below and press Return"),
            why: GuideText(
              "Сумму, дату и категорию OhMyMoney поймёт из строки сам.",
              "OhMyMoney reads the amount, the date and the category from the line itself.")),
        ],
        done: .any([
          .operation(words: "кофе", amountE4: 3_000_000),
          .operation(words: "coffee", amountE4: 3_000_000),
        ])),
      // The tasks of a starter set: each writes into a category the set adds, so the owner sees
      // where his own spending goes.
      GuideTask(
        id: "task.textbook",
        title: GuideText("Запишите покупку учебника", "Write down a textbook"),
        hints: [
          type(
            GuideText(
              "Наберите «учебник 800» и нажмите Return", "Type «textbook 800» and press Return"),
            why: GuideText(
              "Для таких трат набор добавил «Учебники» — увидите, сколько уходит на учёбу.",
              "The set added «Textbooks» for it: you will see what your studies cost."))
        ],
        done: .any([
          .operation(words: "учебник", amountE4: nil), .operation(words: "textbook", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.student))),
      GuideTask(
        id: "task.lunch",
        title: GuideText("Запишите обед", "Write down a lunch"),
        hints: [
          type(
            GuideText("Наберите «обед 450» и нажмите Return", "Type «lunch 450» and press Return"),
            why: GuideText(
              "Для этого набор добавил «Обеды» — увидите, сколько стоят обеды за месяц.",
              "The set added «Lunches» for it: you will see what lunches cost a month."))
        ],
        done: .any([
          .operation(words: "обед", amountE4: nil), .operation(words: "lunch", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.working))),
      GuideTask(
        id: "task.client",
        title: GuideText("Запишите оплату от заказчика", "Write down a payment from a client"),
        hints: [
          type(
            GuideText(
              "Наберите «+20000 заказчик» и нажмите Return", "Type «+20000 client» and press Return"
            ),
            why: GuideText(
              "«+» — это доход; он ляжет в «Заказчики» из набора.",
              "«+» means income; it goes to «Clients» of the set."))
        ],
        done: .any([.income(words: "заказ"), .income(words: "client")]),
        audience: .only(.lifestyle(.freelance))),
      GuideTask(
        id: "task.familyHelp",
        title: GuideText("Запишите помощь родным", "Write down help to your family"),
        hints: [
          type(
            GuideText(
              "Наберите «помощь маме 3000» и нажмите Return",
              "Type «help mum 3000» and press Return"),
            why: GuideText(
              "Для этого набор добавил «Помощь родным».", "The set added «Family help» for it."))
        ],
        done: .any([
          .operation(words: "помощ", amountE4: nil), .operation(words: "help", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.family))),
      GuideTask(
        id: "task.date",
        title: GuideText("Запишите свидание", "Write down a date"),
        hints: [
          type(
            GuideText(
              "Наберите «свидание 2500» и нажмите Return", "Type «date 2500» and press Return"),
            why: GuideText("Для этого набор добавил «Свидания».", "The set added «Dates» for it."))
        ],
        done: .any([
          .operation(words: "свидан", amountE4: nil), .operation(words: "date", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.partner))),
      GuideTask(
        id: "task.kids",
        title: GuideText("Запишите покупку для детей", "Write down something for the children"),
        hints: [
          type(
            GuideText(
              "Наберите «игрушки 1500» и нажмите Return", "Type «toys 1500» and press Return"),
            why: GuideText(
              "Набор добавил категорию «Дети» — траты на детей видны отдельно.",
              "The set added the category «Kids»: what the children cost shows apart."))
        ],
        done: .any([
          .operation(words: "игрушк", amountE4: nil), .operation(words: "toy", amountE4: nil),
        ]),
        audience: .only(.lifestyle(.kids))),
      GuideTask(
        id: "task.category",
        title: GuideText("Поменяйте категорию операции", "Change the category of an operation"),
        hints: [
          open(
            GuideTarget.sidebarOperations, "Операции", "Transactions", keys: "⌘4",
            why: GuideText("Здесь все операции, новые сверху.", "Every operation, newest first.")),
          GuideHint(
            target: GuideTarget.operationsList,
            text: GuideText(
              "Дважды щёлкните операцию и выберите другую категорию",
              "Click an operation twice and pick another category"),
            why: GuideText(
              "Итого запомнит ваш выбор и в следующий раз подставит его сам.",
              "OhMyMoney remembers your choice and puts it in by itself next time."),
            gesture: GuideText("Коснитесь операции", "Tap an operation"), advancesOnClick: false),
        ],
        done: .event(GuideEvent.categoryChanged)),
      GuideTask(
        id: "task.search",
        title: GuideText("Найдите трату за прошлую неделю", "Find an expense from last week"),
        hints: [
          open(
            GuideTarget.sidebarOperations, "Операции", "Transactions", keys: "⌘4",
            why: GuideText("Поиск — вверху списка.", "The search is at the top of the list.")),
          GuideHint(
            target: GuideTarget.operationsSearch,
            text: GuideText("Наберите слово в поиске", "Type a word into the search"),
            why: GuideText(
              "Поиск ищет по всей истории: слова, категорию и место.",
              "The search looks through the whole history: words, category and place."),
            keys: "⌘F", advancesOnClick: false),
        ],
        done: .event(GuideEvent.searched)),
      GuideTask(
        id: "task.subscription",
        title: GuideText("Заведите платёж по подписке", "Add a subscription payment"),
        hints: [
          open(
            GuideTarget.sidebarPlanning, "Планирование", "Planning", keys: "⌘2",
            why: GuideText(
              "Здесь платежи, подписки, лимиты и цели.",
              "Payments, subscriptions, limits and goals live here.")),
          GuideHint(
            target: GuideTarget.planningAddPayment,
            text: GuideText("Нажмите «+ Платёж»", "Press «+ Payment»"),
            why: GuideText(
              "Платёж напомнит о себе в срок и заранее вычтется из свободной суммы.",
              "A payment reminds you when it is due and is taken off the free sum in advance.")),
        ],
        done: .scheduledPaymentAdded,
        audience: .unlessNot(.subscriptions)),
      GuideTask(
        id: "task.count",
        title: GuideText("Сверьте остаток счёта", "Count the balance of an account"),
        hints: [
          GuideHint(
            target: GuideTarget.toolbarReconcile,
            text: GuideText(
              "Нажмите «Сверка» на панели инструментов вверху окна",
              "Press Count in the toolbar at the top of the window"),
            why: GuideText(
              "Впишите, сколько денег на счёте на самом деле, — разница станет видна сразу.",
              "Write what the account really holds, and any difference shows at once."))
        ],
        done: .countMade),
      GuideTask(
        id: "task.free",
        title: GuideText(
          "Посмотрите, сколько свободно до конца месяца", "See what is free to spend this month"),
        hints: [
          open(
            GuideTarget.sidebarPlanning, "Планирование", "Planning", keys: "⌘2",
            why: GuideText(
              "Свободная сумма — в начале экрана.", "The free sum is at the top of the screen.")),
          GuideHint(
            target: GuideTarget.planningFreeToSpend,
            text: GuideText("Это свободная сумма", "This is the free sum"),
            why: GuideText(
              "Столько можно тратить, не задев платежи, долги и цели.",
              "What you can spend without touching payments, debts and goals.")),
        ],
        done: .event(GuideEvent.freeToSpendSeen)),
      GuideTask(
        id: "task.transfer",
        title: GuideText("Переведите деньги строкой", "Transfer money from the line"),
        hints: [
          type(
            GuideText(
              "Наберите «перевод 1000 основной наличные» и нажмите Return",
              "Type «transfer 1000 main cash» and press Return"),
            why: GuideText(
              "Перевод между своими счетами — не трата: деньги просто переезжают.",
              "A transfer between your own accounts is not spending: the money only moves."))
        ],
        done: .any([.event(GuideEvent.transferFromLine), .transferAdded])),
      GuideTask(
        id: "task.forSomebody",
        title: GuideText("Заплатите за другого", "Pay for somebody else"),
        hints: [
          GuideHint(
            target: GuideTarget.entryDetails,
            text: GuideText("Откройте все поля операции", "Open every field of the operation"),
            why: GuideText("«За кого» — среди полей.", "«For whom» is among the fields."),
            keys: "Tab"),
          GuideHint(
            target: GuideTarget.entryForWhom,
            text: GuideText(
              "В строке «За кого» выберите «За другого» или «Пополам»",
              "In «For whom», pick «For somebody» or «Half each»"),
            why: GuideText(
              "Деньги, которые вам вернут, не станут вашей тратой.",
              "Money you will get back does not count as your spending."),
            advancesOnClick: false),
        ],
        done: .operationForSomebodyElse),
      GuideTask(
        id: "task.loan",
        title: GuideText("Заведите кредит или долг", "Add a loan or a debt"),
        hints: [
          open(
            GuideTarget.sidebarDebts, "Долги", "Debts", keys: "⌘3",
            why: GuideText(
              "Здесь «Я должен» и «Мне должны».", "«I owe» and «Owed to me» live here.")),
          GuideHint(
            target: GuideTarget.debtsAdd,
            text: GuideText("Нажмите «+ Долг»", "Press «+ Debt»"),
            why: GuideText(
              "OhMyMoney напомнит о платеже и посчитает, сколько осталось.",
              "OhMyMoney reminds you of each payment and counts what is left.")),
        ],
        done: .debtAdded,
        audience: .only(.loans)),
      GuideTask(
        id: "task.cushion",
        title: GuideText("Заведите цель «Подушка»", "Add a goal «Cushion»"),
        hints: [
          open(
            GuideTarget.sidebarPlanning, "Планирование", "Planning", keys: "⌘2",
            why: GuideText("Цели — внизу экрана.", "Goals are further down the screen.")),
          GuideHint(
            target: GuideTarget.planningAddGoal,
            text: GuideText("В блоке «Цели» нажмите «+ Цель»", "In Goals, press «+ Goal»"),
            why: GuideText(
              "Отложенное на цель не попадёт в свободную сумму.",
              "Money put aside for a goal stays out of the free sum.")),
        ],
        done: .goalAdded,
        audience: .only(.cushion)),
      GuideTask(
        id: "task.cashback",
        title: GuideText("Задайте кэшбэк счёта", "Set the cashback of an account"),
        hints: [
          GuideHint(
            target: GuideTarget.settingsAccounts,
            text: GuideText(
              "«Настройки → Счета» → счёт → «Кэшбэк…»",
              "Settings → Accounts → an account → «Cashback…»"),
            why: GuideText(
              "OhMyMoney посчитает, сколько кэшбэка ждать, и скажет, если он не пришёл.",
              "OhMyMoney works out the cashback to expect and tells you when it does not come."),
            keys: "⌘,")
        ],
        done: .cashbackRuleAdded,
        audience: .only(.cashback)),
      GuideTask(
        id: "task.spending",
        title: GuideText("Откройте список «Операции»", "Open the Transactions list"),
        hints: [
          GuideHint(
            target: GuideTarget.sidebarOperations,
            text: GuideText(
              "Пункт «Операции» в боковой панели или ↓ в пустой строке",
              "Transactions in the sidebar, or ↓ in the empty line"),
            why: GuideText(
              "Все операции одним списком, поиск — по всей истории.",
              "Every operation in one list, and a search through the whole history."),
            keys: "↓")
        ],
        done: .event(GuideEvent.operationsOpened)),
      GuideTask(
        id: "task.currencyChart",
        title: GuideText("Посмотрите график валюты", "Look at a currency chart"),
        hints: [
          GuideHint(
            target: GuideTarget.settingsOverviewTiles,
            text: GuideText(
              "«Настройки → Оформление» → плитка «График валюты»",
              "Settings → Appearance → the Currency Chart tile"),
            why: GuideText(
              "Плитка покажет курс и как он менялся за неделю, месяц или год.",
              "The tile shows the rate and how it moved over a week, a month or a year."),
            keys: "⌘,")
        ],
        done: .event(GuideEvent.currencyChartSeen)),
    ])

  // MARK: Where to click

  /// «Показать, куда нажимать»: the places of the main window one at a time, each with what it
  /// does and its keys.
  public static let whereToClick: [GuideHint] = [
    GuideHint(
      target: GuideTarget.entryLine, text: GuideText("Запись операции", "Write an operation"),
      why: GuideText(
        "Наберите «кофе 300» и Return — трата записана.",
        "Type «coffee 300» and Return, and the expense is written."),
      keys: "⌘N", advancesOnClick: false),
    GuideHint(
      target: GuideTarget.entryDetails, text: GuideText("Все поля", "Every field"),
      why: GuideText(
        "Категория, счёт, «за кого», дата — если строки мало.",
        "Category, account, «for whom», date — when the line is not enough."),
      keys: "Tab"),
    GuideHint(
      target: GuideTarget.sidebarOverview, text: GuideText("Обзор", "Overview"),
      why: GuideText("Месяц одним взглядом.", "The month at a glance."), keys: "⌘1"),
    GuideHint(
      target: GuideTarget.sidebarPlanning, text: GuideText("Планирование", "Planning"),
      why: GuideText(
        "Платежи, подписки, лимиты, цели и свободная сумма.",
        "Payments, subscriptions, limits, goals and the free sum."),
      keys: "⌘2"),
    GuideHint(
      target: GuideTarget.sidebarDebts, text: GuideText("Долги", "Debts"),
      why: GuideText("Кому должны вы и кто должен вам.", "Whom you owe and who owes you."),
      keys: "⌘3"),
    GuideHint(
      target: GuideTarget.sidebarOperations, text: GuideText("Операции", "Transactions"),
      why: GuideText(
        "Все операции списком и поиск по истории.",
        "Every operation in a list and a search through the history."),
      keys: "⌘4"),
    GuideHint(
      target: GuideTarget.sidebarCalendar, text: GuideText("Календарь", "Calendar"),
      why: GuideText(
        "Сколько стоил каждый день и какие платежи впереди.",
        "What each day cost and which payments are ahead."),
      keys: "⌘5"),
    GuideHint(
      target: GuideTarget.sidebarCapital, text: GuideText("Капитал", "Capital"),
      why: GuideText(
        "Что есть минус что должны, по месяцам.", "What you have minus what you owe, by month."),
      keys: "⌘6"),
    GuideHint(
      target: GuideTarget.toolbarTransactions,
      text: GuideText(
        "Таблица операций — на панели вверху", "The table of operations — in the toolbar"),
      why: GuideText(
        "Все операции с фильтрами и правкой нескольких сразу.",
        "Every operation with filters and editing many at once."),
      keys: "⌘⇧T"),
    GuideHint(
      target: GuideTarget.toolbarReconcile,
      text: GuideText("Сверка остатка — на панели вверху", "Count the balance — in the toolbar"),
      why: GuideText(
        "Впишите, сколько денег на самом деле, — разница видна сразу.",
        "Write what you really have, and any difference shows at once.")),
    GuideHint(
      target: GuideTarget.toolbarSettings,
      text: GuideText("Настройки — на панели вверху", "Settings — in the toolbar"),
      why: GuideText(
        "Счета, категории, валюты, оформление.", "Accounts, categories, currencies, appearance."),
      keys: "⌘,"),
  ]

  // MARK: What is new

  public static let whatsNew: [GuideScenario] = [
    whatsNew14, whatsNew15, whatsNew16, whatsNew17, whatsNew18, whatsNew19,
    whatsNew110,
    whatsNew111,
    whatsNew112,
    whatsNew113,
  ]

  public static let whatsNew14 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 4)),
    cards: [
      GuideCard(
        id: "new14.guide",
        title: GuideText("Знакомство и учебный режим", "A tour and a tutorial"),
        body: GuideText(
          "«Справка → Учебный режим»: задания на учебных данных, ваша база не трогается.",
          "Help → Tutorial: tasks on sample data, your database is not touched."),
        symbol: "graduationcap"),
      GuideCard(
        id: "new14.starter",
        title: GuideText("Стартовые наборы", "Starter sets"),
        body: GuideText(
          "«Настройки → Стартовый набор»: категории и лимиты под ваш образ жизни. Набор только добавляет.",
          "Settings → Starter Set: categories and limits for the way you live. A set only adds."),
        symbol: "shippingbox"),
      GuideCard(
        id: "new14.spending",
        title: GuideText("«Траты» в боковой панели", "Spending in the sidebar"),
        body: GuideText(
          "Все операции — отдельным списком. ↓ в пустой строке переходит к самой новой.",
          "Every operation in a list of its own. ↓ in the empty line goes to the latest."),
        symbol: "list.bullet", target: GuideTarget.sidebarOperations),
      GuideCard(
        id: "new14.approx",
        title: GuideText("Серое «≈» для чужой валюты", "A grey «≈» for other currencies"),
        body: GuideText(
          "Трата в долларах без курса показывает «≈ 1,240 ₽» по курсу ЦБ. Только показ — цифры не меняются.",
          "A dollar expense without a rate shows «≈ 1,240 ₽» at the central bank's rate. Display only."
        ),
        symbol: "approximately.equal"),
      GuideCard(
        id: "new14.currencyChart",
        title: GuideText("График валюты на Обзоре", "A currency chart on the Overview"),
        body: GuideText(
          "Плитка с парой валют, неделя, месяц или год, курс и изменение.",
          "A tile with a currency pair over a week, month or year, the rate and the change."),
        symbol: "chart.xyaxis.line"),
      GuideCard(
        id: "new14.forSomebody",
        title: GuideText("Трата за другого", "Paying for somebody"),
        body: GuideText(
          "«За кого»: себе, за другого, пополам, поровну. «Вернёт?» — долг или подарок.",
          "«For whom»: me, somebody else, half each, split evenly. «Pays back?» — a debt or a gift."
        ),
        symbol: "person.2"),
      GuideCard(
        id: "new14.transfer",
        title: GuideText("Перевод строкой", "A transfer from the line"),
        body: GuideText(
          "«перевод 5000 сбер т-банк» — перевод со счёта на счёт, а не трата.",
          "«transfer 5000 sber tbank» moves money between accounts; it is not spending."),
        symbol: "arrow.left.arrow.right"),
      GuideCard(
        id: "new14.expected",
        title: GuideText("Ожидаемые поступления", "Expected income"),
        body: GuideText(
          "Можно удалить, закрыть полностью и вернуть из архива; имена могут совпадать.",
          "Delete one, close it in full and bring it back from the archive; names may repeat."),
        symbol: "tray.and.arrow.down"),
      GuideCard(
        id: "new14.quickEntry",
        title: GuideText("Быстрый набор справа", "Quick entry at the side"),
        body: GuideText(
          "В подробной форме справа — строка, которая сначала показывает, что будет записано.",
          "The form at the side has a line that shows what will be written before it is."),
        symbol: "sidebar.right"),
    ])

  public static let whatsNew15 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 5)),
    cards: [
      GuideCard(
        id: "new15.calendar",
        title: GuideText("Календарь трат", "A spending calendar"),
        body: GuideText(
          "Месяц или неделя: сколько потрачено в каждый день, дорогие дни отмечены, впереди — платежи. ⌘5.",
          "A month or a week: what each day cost, costly days marked, payments ahead. ⌘5."),
        symbol: "calendar", target: GuideTarget.sidebarCalendar),
      GuideCard(
        id: "new15.hide",
        title: GuideText("Скрыть суммы", "Hide amounts"),
        body: GuideText(
          "Кнопка с глазом или ⌃⌘H — все суммы становятся «•••».",
          "The eye button or ⌃⌘H turns every amount into «•••»."),
        symbol: "eye.slash"),
      GuideCard(
        id: "new15.lock",
        title: GuideText("Блокировка Touch ID", "A Touch ID lock"),
        body: GuideText(
          "«Настройки → Основные»: «OhMyMoney» закрывается после простоя и при блокировке Mac.",
          "Settings → General: OhMyMoney locks after idle time and when the Mac locks."),
        symbol: "touchid"),
      GuideCard(
        id: "new15.limits",
        title: GuideText("Предложить лимиты", "Suggested limits"),
        body: GuideText(
          "«Планирование → Лимиты → Предложить лимиты…»: суммы по вашим обычным тратам.",
          "Planning → Limits → Suggest Limits…: amounts from what you usually spend."),
        symbol: "gauge.with.dots.needle.50percent"),
      GuideCard(
        id: "new15.line",
        title: GuideText("Время и кэшбэк в строке", "Time and cashback in the line"),
        body: GuideText(
          "«груша вчера в 18:09 325 кэшбек 9.76» — со временем и кэшбэком.",
          "«pear yesterday at 18:09 325 cashback 9.76» — with the time and the cashback."),
        symbol: "text.cursor"),
      GuideCard(
        id: "new15.form",
        title: GuideText("Форма справа", "The form at the side"),
        body: GuideText(
          "Сначала вид операции; выбранная в списке операция открывается в форме на правку; перевод — прямо в форме.",
          "The kind comes first; an operation chosen in a list opens in the form; a transfer is written right there."
        ),
        symbol: "sidebar.right"),
    ])

  public static let whatsNew16 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 6)),
    cards: [
      GuideCard(
        id: "new16.educationLoan",
        title: GuideText("Образовательный кредит", "An education loan"),
        body: GuideText(
          "Новый долг → «Образовательный кредит (госпрограмма)»: 3 %, льготный период с 40 % → 60 % → 100 % процентов, затем 15 лет основного долга.",
          "New debt → «Education loan (state programme)»: 3 %, a grace period paying 40 % → 60 % → 100 % of the interest, then 15 years of main debt."
        ),
        symbol: "graduationcap"),
      GuideCard(
        id: "new16.tranche",
        title: GuideText("Транши и проценты в платежах", "Tranches and the interest in payments"),
        body: GuideText(
          "«Добавить транш…» — расход в «Образовании», долг растёт. Платёж сначала гасит проценты: расходом считаются только они.",
          "«Add Tranche…» is an expense in «Education» and grows the debt. A payment pays the interest first, and only the interest is spending."
        ),
        symbol: "banknote"),
      GuideCard(
        id: "new16.deposits",
        title: GuideText("Вклады и накопительные счета", "Deposits and savings accounts"),
        body: GuideText(
          "В редакторе счёта — «На остаток начисляются проценты»: ставка, выплата, капитализация. Экран счёта покажет начисленное и спросит, если выплата не пришла.",
          "In the account editor, «The balance earns interest»: the rate, the payout, capitalisation. The account screen shows what was earned and asks when a payout does not come."
        ),
        symbol: "percent"),
      GuideCard(
        id: "new16.forecast",
        title: GuideText("Проценты в прогнозе счёта", "Interest in the account forecast"),
        body: GuideText(
          "Прогноз на конец месяца добавляет серую строку «Проценты ≈». «Записать…» — и они становятся доходом.",
          "The forecast for the end of the month adds a grey «Interest ≈» line. «Record…» makes them income."
        ),
        symbol: "chart.line.uptrend.xyaxis"),
    ])

  public static let whatsNew17 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 7)),
    cards: [
      GuideCard(
        id: "new17.capital",
        title: GuideText("Капитал", "Capital"),
        body: GuideText(
          "Что есть минус что должен: счета, вклады, имущество и долги — и график по концам месяцев. ⌘6.",
          "What you have minus what you owe: accounts, deposits, property and debts, with a chart of month ends. ⌘6."
        ),
        symbol: "building.columns", target: GuideTarget.sidebarCapital),
      GuideCard(
        id: "new17.assets",
        title: GuideText("Имущество", "Property"),
        body: GuideText(
          "Машина, брокерский счёт, квартира: «Добавить имущество…», потом «Новая оценка…» — стоимость на дату входит в капитал.",
          "A car, a brokerage account, a flat: «Add property…», then «New valuation…» — the value on a day goes into the capital."
        ),
        symbol: "car"),
      GuideCard(
        id: "new17.cushion",
        title: GuideText("Подушка безопасности", "A safety cushion"),
        body: GuideText(
          "«Счета и категории…» — отметьте счета подушки и необходимые траты, и «Капитал» скажет: «Без дохода вы проживёте 3,5 месяца».",
          "«Accounts and categories…»: mark the cushion accounts and the essential spending, and Capital says: «Without income you would last 3.5 months»."
        ),
        symbol: "lifepreserver"),
      GuideCard(
        id: "new17.cushionGoal",
        title: GuideText("Цель подушки", "A cushion goal"),
        body: GuideText(
          "«Цель…» — подушка на N месяцев и сколько откладывать в месяц. «Не считать подушку в свободной сумме» — в «Свободной сумме» и «Настройки → Планирование».",
          "«Goal…» sets a cushion of N months and what to put aside each month. «Keep the cushion out of the free sum» is in «Free sum» and Settings → Planning."
        ),
        symbol: "target"),
    ])

  public static let whatsNew18 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 8)),
    cards: [
      GuideCard(
        id: "new18.overview",
        title: GuideText("Все плитки «Обзора» — по группам", "Every Overview tile, in groups"),
        body: GuideText(
          "Плитки разложены на «Деньги», «План» и «Анализ», группу можно свернуть. «Изменить» — перетащить плитку, перенести в другую группу, скрыть; то же — в «Настройки → Оформление».",
          "Tiles sit in «Money», «Plan» and «Analysis», and a group folds away. «Edit» drags a tile, moves it to another group or hides it; the same is in Settings → Appearance."
        ),
        symbol: "square.grid.2x2", target: GuideTarget.sidebarOverview),
      GuideCard(
        id: "new18.why",
        title: GuideText("«Почему так»", "«Why so»"),
        body: GuideText(
          "Щёлкните плитку: её число по строкам, правило одной фразой и «Открыть в …» — туда, где это живёт.",
          "Click a tile: its figure line by line, the rule in one sentence, and «Open in …» where it lives."
        ),
        symbol: "questionmark.circle"),
      GuideCard(
        id: "new18.planning",
        title: GuideText("Планирование короче", "A shorter Planning"),
        body: GuideText(
          "Сверху — сколько ещё можно потратить, лента «Ближайшие 14 дней», блоки карточками, в длинных — ближайшие и «Показать все». Кнопка «+» добавляет платёж, подписку, цель…",
          "On top: what you can still spend, the «Next 14 days» ribbon, blocks as cards with the nearest first and «Show all». The «+» button adds a payment, a subscription, a goal…"
        ),
        symbol: "calendar.badge.clock", target: GuideTarget.sidebarPlanning),
      GuideCard(
        id: "new18.password",
        title: GuideText("Пароль блокировки", "A lock password"),
        body: GuideText(
          "«Блокировать OhMyMoney» открывается своим паролем или Touch ID. Забыли пароль — сбросьте паролем Mac.",
          "«Lock OhMyMoney» opens with its own password or Touch ID. Forgot it? Reset it with the Mac password."
        ),
        symbol: "lock"),
      GuideCard(
        id: "new18.windows",
        title: GuideText("Окна и подсказки", "Windows and hints"),
        body: GuideText(
          "Закрыли главное окно — приложение вышло. Аналитика, Операции и Отчёты — отдельные окна без вкладок, на полном экране — поверх. Учебный режим подсвечивает, куда нажать.",
          "Closing the main window quits the app. Analytics, Transactions and Reports are separate windows with no tabs, over a full-screen window. The tutorial lights up where to click."
        ),
        symbol: "macwindow"),
    ])

  public static let whatsNew19 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 9)),
    cards: [
      GuideCard(
        id: "new19.instalments",
        title: GuideText("Рассрочки и честная стоимость", "Instalments and the true cost"),
        body: GuideText(
          "Рассрочка частями — например, 4 платежа раз в две недели, переплата видна в каждом платеже, а плитка «Рассрочки» — сколько висит. У кредита — комиссии и страховка и настоящая ставка.",
          "An instalment plan in parts — say 4 payments every two weeks —, the markup seen in every payment, and the «Instalments» tile says how much is still owed. A loan has its fees, insurance and its real rate."
        ),
        symbol: "creditcard.and.123", target: GuideTarget.sidebarDebts),
      GuideCard(
        id: "new19.creditCard",
        title: GuideText("Кредитка как в банке", "A credit card as the bank keeps it"),
        body: GuideText(
          "Лимит, выписка и 25 дней: «Внести до … без процентов» и минимальный платёж. Не успели — проценты ≈. Снятие наличных — без льготного периода и с комиссией.",
          "A limit, a statement and 25 days: «Pay by … with no interest» and the minimum payment. Missed it — interest ≈. Cash comes with a fee and no grace period."
        ),
        symbol: "creditcard"),
      GuideCard(
        id: "new19.prepay",
        title: GuideText("Досрочка и лестница", "Early repayment and the ladder"),
        body: GuideText(
          "Платёж сверх срока спрашивает: уменьшить срок, платёж или это платёж вперёд. Плановая досрочка напомнит подать заявление. «Лестница погашения» — лавиной или снежным комом.",
          "A payment above the due asks: a shorter term, a smaller payment, or a payment ahead. A planned early repayment reminds you to file the application. «Payoff ladder» — avalanche or snowball."
        ),
        symbol: "arrow.down.right.circle"),
      GuideCard(
        id: "new19.allocation",
        title: GuideText("Распределение зарплаты", "Allocating the salary"),
        body: GuideText(
          "Правила вроде «10 % в цель» — и после зарплаты «Распределить…»: взносы и переводы одним шагом, «Нераспределено» видно. «До 25-го» — на половину месяца, остаток месяца — в подушку.",
          "Rules like «10 % to a goal», and after the salary «Allocate…»: contributions and transfers in one step, «Unallocated» in sight. «Until the 25th» for half a month, and the rest of the month into the cushion."
        ),
        symbol: "chart.pie"),
      GuideCard(
        id: "new19.selfEmployed",
        title: GuideText("Самозанятость", "Self-employment"),
        body: GuideText(
          "«Я самозанятый» — в «Настройки → Планирование». Налог считается сам: «≈ не ваши деньги», заплатить до 28-го, остаток вычета и лимит года.",
          "«I am self-employed» is in Settings → Planning. The tax counts itself: «≈ not your money», pay by the 28th, the deduction left and the limit of the year."
        ),
        symbol: "person.text.rectangle"),
      GuideCard(
        id: "new19.easier",
        title: GuideText("Удобнее", "Easier"),
        body: GuideText(
          "«Операции» вместо «Трат». Настройки с поиском, размер шрифта и вид валюты — код, значок или название. Свои валюты с курсом, основная карта счёта, свёрнутые группы «Капитала».",
          "«Transactions» instead of «Spending». Settings with a search, the text size and how a currency looks — a code, a symbol or a name. Your own currencies with a rate, the main card of an account, folded groups in Capital."
        ),
        symbol: "slider.horizontal.3", target: GuideTarget.sidebarOperations),
    ])

  public static let whatsNew110 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 10)),
    cards: [
      GuideCard(
        id: "new110.name",
        title: GuideText("Теперь — OhMyMoney", "Now it is OhMyMoney"),
        body: GuideText(
          "Приложение называется OhMyMoney на обоих языках; сайт — OhMyMoney.ru. Данные, копии и обновления прежние, ничего делать не нужно.",
          "The app is called OhMyMoney in both languages; the site is OhMyMoney.ru. Your data, copies and updates are the same, nothing to do."
        ),
        symbol: "sparkles"),
      GuideCard(
        id: "new110.byDay",
        title: GuideText("Операции по дням", "Transactions by day"),
        body: GuideText(
          "«Операции» делятся только по дням: доходы, расходы, возвраты и переводы — одним списком по времени, итог дня в заголовке. ⌃⌘F — полный экран.",
          "«Transactions» is split by day only: incomes, expenses, refunds and transfers in one list by time, the day's total in the header. ⌃⌘F is full screen."
        ),
        symbol: "calendar", target: GuideTarget.sidebarOperations),
      GuideCard(
        id: "new110.forOthers",
        title: GuideText("За другого", "Paying for others"),
        body: GuideText(
          "Выбрали другого человека — приложение спросит, вернёт ли он деньги. Присланное сверх частей — доход в «Для оплаты чего-либо». Вещь, возвращённую из рассрочки, можно списать с долга вместе с переплатой за оставшиеся части.",
          "Pick another person and the app asks whether they will pay it back. What they send beyond the parts is income in «Paid for others». A thing returned from an instalment can take off the debt the overpayment of the parts still to pay."
        ),
        symbol: "person.2"),
      GuideCard(
        id: "new110.fixes",
        title: GuideText("Исправления", "Fixes"),
        body: GuideText(
          "«Настройки → Счета» больше не открывается пустым окном, у списка разделов нет лишней кнопки, у напоминания о кредитной истории нет ссылки, число в календаре Обзора в одну строку.",
          "Settings → Accounts no longer opens an empty window, the list of sections has no stray button, the credit-history reminder has no link, and the day number in the Overview calendar stays on one line."
        ),
        symbol: "wrench.and.screwdriver"),
    ])

  public static let whatsNew111 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 11)),
    cards: [
      GuideCard(
        id: "new111.whatIf",
        title: GuideText("Что если…", "What if…"),
        body: GuideText(
          "Окно «Что если…» (меню «Окно» и кнопка в «Планировании»): впишите покупку, кредит, досрочку, откладывание или потерю дохода — и увидите по месяцам, сколько останется свободных денег и когда их не хватит. Ничего не записывается.",
          "The «What if…» window (the Window menu and a button in Planning): type a purchase, a loan, an early repayment, a sum put aside or a loss of income — and see month by month how much free money is left and when it runs short. Nothing is written."
        ),
        symbol: "questionmark.circle", target: GuideTarget.sidebarPlanning),
      GuideCard(
        id: "new111.scenarios",
        title: GuideText("Сценарии", "Scenarios"),
        body: GuideText(
          "Сценарий можно назвать и сохранить, открыть из меню «Сохранённые» и удалить; сохранение — один шаг ⌘Z. Сценарий хранит только изменения и каждый раз считается от сегодняшних цифр.",
          "A scenario can be named and saved, opened from the «Saved» menu and deleted; saving is one step of ⌘Z. A scenario keeps only the changes and is worked out from today's numbers every time."
        ),
        symbol: "tray.full"),
      GuideCard(
        id: "new111.goalOrder",
        title: GuideText("Порядок целей", "The order of the goals"),
        body: GuideText(
          "Цели в «Планировании» переставляются перетаскиванием. Пока вы ничего не двигали, ближайшая по сроку первой; после первого перетаскивания порядок ваш.",
          "The goals in Planning are dragged into any order. Until you move one, the nearest by its day comes first; after the first drag the order is yours."
        ),
        symbol: "arrow.up.arrow.down", target: GuideTarget.planningAddGoal),
    ])

  public static let whatsNew112 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 12)),
    cards: [
      GuideCard(
        id: "new112.names",
        title: GuideText("Копии, которые понятны", "Backups you can read"),
        body: GuideText(
          "Имя копии говорит, что это: «2026-10-06 23.32 · 1.12.0 · после правки». В «Настройки → Бэкапы» у каждой копии видно, сколько в ней операций и когда была последняя; «Сравнить с текущей» показывает, что добавилось, пропало и изменилось.",
          "A backup's name says what it is: «2026-10-06 23.32 · 1.12.0 · after a change». In Settings → Backups every copy shows how many operations it holds and when the last one was; «Compare with the current» shows what was added, what vanished and what changed."
        ),
        symbol: "externaldrive"),
      GuideCard(
        id: "new112.readable",
        title: GuideText(
          "Копия дня и читаемая версия", "The copy of the day and a readable version"),
        body: GuideText(
          "Раз в день делается отдельная копия, и рядом с ней и с копией «перед обновлением» лежит папка с CSV и README: данные можно посмотреть без приложения. Папка остаётся на этом Mac; в iCloud уходит только база.",
          "Once a day a copy of its own is made, and beside it and beside the copy before an update lies a folder of CSV files and a README: your data can be read without the app. The folder stays on this Mac; only the database goes to iCloud."
        ),
        symbol: "doc.text.magnifyingglass"),
      GuideCard(
        id: "new112.thinning",
        title: GuideText("Старые копии редеют сами", "Old copies thin out by themselves"),
        body: GuideText(
          "Сегодня хранится каждая копия, неделю — по одной в день, год — по одной в неделю, дальше — по одной в месяц. Копии «перед обновлением» не удаляются никогда. Мало места — «Освободить место…» покажет список и удалит его только после вашего «Да».",
          "Today every copy is kept, for a week one a day, for a year one a week, then one a month. Copies made before an update are never deleted. Short of room, «Free up space…» shows the list and deletes it only after your Yes."
        ),
        symbol: "calendar.badge.clock"),
      GuideCard(
        id: "new112.check",
        title: GuideText("Проверка базы", "A check of the database"),
        body: GuideText(
          "Раз в неделю база проверяется сама, тихо; о проблеме скажет строка в «Стоит посмотреть». «Проверить сейчас» — по кнопке, «Исправить» сначала делает копию. Архив переноса тоже можно сравнить с текущей базой.",
          "Once a week the database checks itself, quietly; a problem is told in «Worth a look». «Check now» is a button, and «Repair» makes a copy first. A transfer archive can also be compared with the current database."
        ),
        symbol: "stethoscope"),
    ])

  public static let whatsNew113 = GuideScenario(
    kind: .whatsNew(version: GuideVersion(major: 1, minor: 13)),
    cards: [
      GuideCard(
        id: "new113.trip",
        title: GuideText("Путешествия", "Trips"),
        body: GuideText(
          "Пока поездка идёт, над окном — её строка: куда, до какого дня, валюта и бюджет, а под ней «Сегодня потрачено / осталось на день». Новые траты берут валюту и событие поездки. Наутро после последнего дня — «С возвращением!» с итогом и кнопкой «Продлить».",
          "While a trip is on, a strip over the window tells where, until which day, the currency and the budget, and under it «Spent today / left for the day». New spending takes the currency and the event of the trip. The morning after the last day there is «Welcome back!» with the summary and an «Extend» button."
        ),
        symbol: "airplane"),
      GuideCard(
        id: "new113.summary",
        title: GuideText("Итог поездки", "The trip summary"),
        body: GuideText(
          "Сколько поездка обошлась — по всем её операциям, и билетам, купленным за три месяца: по дням, по категориям, по валютам и против бюджета. Ниже — расчёт с компанией: что вам ещё должен каждый человек. День траты остаётся днём, в котором она записана, даже когда Mac вернулся в Москву.",
          "What the trip cost over all of its operations, tickets bought three months ago included: by day, by category, by currency and against the budget. Below, settling up with the company: what each person still owes you. The day of a purchase stays the day it was recorded on, even after the Mac is back in Moscow."
        ),
        symbol: "list.bullet.rectangle"),
      GuideCard(
        id: "new113.rate",
        title: GuideText("Карты и курс", "Cards and the rate"),
        body: GuideText(
          "«Карты за границей…»: впишите комиссию конвертации и банкомата из тарифа — приложение покажет, какая карта теряет меньше. «Капитал» теперь называет курсовую разницу за месяц и за год: сколько рублей принёс курс валюты на ваших счетах. Это не доход и не расход.",
          "«Cards abroad…»: type the conversion and ATM fees from the tariff and the app shows which card loses least. «Capital» now names the exchange-rate difference for the month and the year: how many rubles the rate brought on your accounts. It is neither income nor expense."
        ),
        symbol: "creditcard", target: GuideTarget.sidebarCapital),
    ])
}
