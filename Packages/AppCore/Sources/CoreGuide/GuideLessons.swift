import Foundation

/// A short lesson of money: five cards of the guide on one topic. The lessons explain how a thing
/// works and where the app shows it; they never tell what to do with one's money. They hold no
/// figure of their own — a limit, a rate or a threshold changes, so a lesson points to the screen
/// of the app that shows the figure of the day.
public struct GuideLesson: Hashable, Sendable, Identifiable {
  public var id: String
  public var title: GuideText
  /// An SF Symbol name; other platforms map it to their own picture.
  public var symbol: String
  public var cards: [GuideCard]

  public init(id: String, title: GuideText, symbol: String, cards: [GuideCard]) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.cards = cards
  }

  /// The lesson as the cards of the guide show it.
  public var scenario: GuideScenario { GuideScenario(kind: .lesson(id), cards: cards) }
}

public enum GuideLessons {
  /// The lessons in the order of the list: the cushion, loans, deposits, tax deductions, cashback.
  public static let all: [GuideLesson] = [cushion, loans, deposits, deductions, cashback]

  public static func lesson(_ id: String) -> GuideLesson? { all.first { $0.id == id } }

  private static func card(
    _ id: String, _ symbol: String, _ title: GuideText, _ body: GuideText, target: String? = nil
  ) -> GuideCard {
    GuideCard(id: id, title: title, body: body, symbol: symbol, seconds: 15, target: target)
  }

  public static let cushion = GuideLesson(
    id: "cushion", title: GuideText("Подушка безопасности", "The safety cushion"),
    symbol: "lifepreserver",
    cards: [
      card(
        "lesson.cushion.what", "lifepreserver",
        GuideText("Что это", "What it is"),
        GuideText(
          "Подушка безопасности — запас на непредвиденное: болезнь, ремонт, паузу в работе. Это не цель «на что-то», а деньги на случай.",
          "A safety cushion is a reserve for the unexpected: an illness, a repair, a break in work. It is not a goal to buy something, but money for a rainy day."
        )),
      card(
        "lesson.cushion.size", "ruler",
        GuideText("Как её измеряют", "How it is measured"),
        GuideText(
          "Подушку считают в месяцах обязательных трат — тех, без которых не обойтись: жильё, еда, связь, платежи по кредитам. Сколько месяцев нужно, решаете вы.",
          "A cushion is counted in months of the spending you cannot do without: housing, food, phone, loan payments. How many months you want is up to you."
        )),
      card(
        "lesson.cushion.where", "building.columns",
        GuideText("Где её держат", "Where it is kept"),
        GuideText(
          "Подушка нужна быстро и без потерь, поэтому её держат там, откуда деньги можно забрать в любой день, и отдельно от денег на каждый день — так её труднее потратить случайно.",
          "A cushion has to be there quickly and whole, so it is kept where the money can be taken out any day, and apart from everyday money, where it is harder to spend by accident."
        )),
      card(
        "lesson.cushion.build", "arrow.up.right",
        GuideText("Как она растёт", "How it grows"),
        GuideText(
          "Подушку собирают понемногу: часть каждого дохода. «Распределение дохода» предложит отложить её сразу, как только доход записан.",
          "A cushion is gathered little by little: a share of every income. The allocation of income offers to put it aside as soon as the income is written down."
        )),
      card(
        "lesson.cushion.app", "chart.pie",
        GuideText("В OhMyMoney", "In OhMyMoney"),
        GuideText(
          "Отметьте счёт как подушку в его настройках — «Капитал» покажет, на сколько месяцев обязательных трат её хватит.",
          "Mark an account as the cushion in its settings, and Capital shows how many months of the spending you cannot do without it covers."
        ),
        target: GuideTarget.sidebarCapital),
    ])

  public static let loans = GuideLesson(
    id: "loans", title: GuideText("Кредиты", "Loans"), symbol: "creditcard",
    cards: [
      card(
        "lesson.loans.cost", "percent",
        GuideText("Сколько стоит кредит", "What a loan costs"),
        GuideText(
          "Ставка — цена денег банка за год. Кредит может стоить и страховки, и комиссии; всё вместе в договоре называется полной стоимостью кредита (ПСК).",
          "The rate is the bank's price of money for a year. A loan may also cost insurance and fees; all of it together is called the full cost of the loan in the contract."
        )),
      card(
        "lesson.loans.schedule", "calendar",
        GuideText("Аннуитет и дифференцированный", "Annuity and differentiated"),
        GuideText(
          "При аннуитетном платеже сумма каждый месяц одна и та же, и в начале в ней больше процентов. При дифференцированном долг гасится равными частями, и платёж со временем уменьшается.",
          "With an annuity payment the sum is the same every month, and early on more of it is interest. With a differentiated one the debt is paid in equal parts, and the payment falls over time."
        )),
      card(
        "lesson.loans.early", "forward",
        GuideText("Досрочное погашение", "Paying early"),
        GuideText(
          "Досрочный платёж уменьшает либо платёж, либо срок. Меньший срок обычно значит меньше процентов, меньший платёж — свободнее месяц. «Долги» покажут обе цифры до того, как вы решите.",
          "An early payment lowers either the payment or the term. A shorter term usually means less interest, a smaller payment an easier month. Debts shows both figures before you decide."
        ),
        target: GuideTarget.sidebarDebts),
      card(
        "lesson.loans.card", "creditcard.and.123",
        GuideText("Кредитная карта", "A credit card"),
        GuideText(
          "У кредитки есть льготный период: если вернуть всю задолженность до даты из выписки, проценты не начисляются. Снятие наличных и переводы с кредитки часто стоят комиссии.",
          "A credit card has a grace period: pay back the whole debt by the date of the statement and no interest is charged. Cash and transfers from a credit card often cost a fee."
        )),
      card(
        "lesson.loans.load", "gauge.with.dots.needle.33percent",
        GuideText("Долговая нагрузка", "Debt load"),
        GuideText(
          "Долговая нагрузка — доля дохода, которая уходит на платежи по долгам. «Планирование» показывает её и как она менялась; какая доля для вас удобна, решаете вы.",
          "Debt load is the share of income that goes to the payments of debts. Planning shows it and how it changed; what share feels right is your call."
        ),
        target: GuideTarget.sidebarPlanning),
    ])

  public static let deposits = GuideLesson(
    id: "deposits", title: GuideText("Вклады", "Deposits"), symbol: "building.columns",
    cards: [
      card(
        "lesson.deposits.kinds", "building.columns",
        GuideText("Вклад и накопительный счёт", "A deposit and a savings account"),
        GuideText(
          "Вклад — деньги в банке на срок под ставку. Накопительный счёт — без срока: деньги можно забрать в любой день, но ставка может меняться.",
          "A deposit is money in a bank for a term at a rate. A savings account has no term: the money can be taken out any day, but the rate may change."
        )),
      card(
        "lesson.deposits.capitalization", "arrow.triangle.2.circlepath",
        GuideText("Капитализация", "Capitalisation"),
        GuideText(
          "Капитализация — когда проценты прибавляются к вкладу и дальше начисляются уже на бо́льшую сумму. При той же ставке итог тем больше, чем чаще это происходит.",
          "Capitalisation is when interest is added to the deposit and earns interest itself from then on. At the same rate, the more often it happens, the more the deposit brings."
        )),
      card(
        "lesson.deposits.early", "clock.arrow.circlepath",
        GuideText("Если забрать раньше", "Taking it out early"),
        GuideText(
          "Если закрыть вклад раньше срока, проценты часто пересчитывают по низкой ставке. Условия досрочного закрытия написаны в договоре вклада.",
          "Close a deposit before its term and the interest is often worked out again at a low rate. The terms of closing early are in the contract of the deposit."
        )),
      card(
        "lesson.deposits.insurance", "checkmark.shield",
        GuideText("Страхование вкладов", "Deposit insurance"),
        GuideText(
          "Вклады людей в банках России застрахованы Агентством по страхованию вкладов до установленного лимита на один банк. Действующий лимит и сколько у вас в каждом банке, показывает экран банка.",
          "People's deposits in Russian banks are insured by the Deposit Insurance Agency up to a set limit per bank. The limit in force and how much you have in each bank are on the screen of the bank."
        )),
      card(
        "lesson.deposits.tax", "doc.text",
        GuideText("Налог с процентов", "Tax on interest"),
        GuideText(
          "Проценты по вкладам — доход, и сверх необлагаемой суммы с них платится налог. Банки сообщают о процентах в налоговую сами; действующие правила — на сайте ФНС.",
          "Interest on deposits is income, and above a tax-free amount it is taxed. Banks report the interest to the tax service themselves; the rules in force are on the tax service's site."
        )),
    ])

  public static let deductions = GuideLesson(
    id: "deductions", title: GuideText("Налоговые вычеты", "Tax deductions"),
    symbol: "arrow.uturn.backward.circle",
    cards: [
      card(
        "lesson.deductions.what", "arrow.uturn.backward.circle",
        GuideText("Что такое вычет", "What a deduction is"),
        GuideText(
          "Налоговый вычет возвращает часть уплаченного налога на доходы (НДФЛ) за некоторые расходы — или уменьшает этот налог заранее.",
          "A tax deduction gives back part of the income tax paid for some expenses, or lowers that tax in advance."
        )),
      card(
        "lesson.deductions.kinds", "list.bullet",
        GuideText("Какие бывают", "Which there are"),
        GuideText(
          "Самые известные: имущественный — покупка жилья и проценты по ипотеке; социальные — лечение, обучение, спорт; инвестиционный — для индивидуального инвестиционного счёта.",
          "The best known: the property one, for buying a home and mortgage interest; the social ones, for medical care, education and sport; the investment one, for an individual investment account."
        )),
      card(
        "lesson.deductions.who", "person.text.rectangle",
        GuideText("Кто может получить", "Who can get one"),
        GuideText(
          "Вычет получает тот, кто платит НДФЛ: с зарплаты, аренды и других доходов. Доход самозанятого облагается другим налогом, и такие вычеты по нему не дают.",
          "A deduction goes to whoever pays income tax: on a salary, on rent and on other income. The income of the self-employed is taxed differently, and these deductions do not apply to it."
        )),
      card(
        "lesson.deductions.how", "doc.badge.plus",
        GuideText("Как оформить", "How to claim"),
        GuideText(
          "Через личный кабинет налоговой или у работодателя. Понадобятся документы о расходах: договор, чеки, справки об оплате.",
          "Through your account at the tax service or with your employer. You need the papers of the expenses: the contract, the receipts, the certificates of payment."
        )),
      card(
        "lesson.deductions.app", "paperclip",
        GuideText("В OhMyMoney", "In OhMyMoney"),
        GuideText(
          "Прикрепляйте чеки и договоры к операциям — когда придёт время вычета, документы будут в одном месте, рядом с суммами.",
          "Attach receipts and contracts to the operations: when the time of the deduction comes, the papers are in one place, next to the amounts."
        )),
    ])

  public static let cashback = GuideLesson(
    id: "cashback", title: GuideText("Кэшбэк", "Cashback"), symbol: "arrow.uturn.left.circle",
    cards: [
      card(
        "lesson.cashback.what", "arrow.uturn.left.circle",
        GuideText("Что это", "What it is"),
        GuideText(
          "Кэшбэк — часть потраченного, которую банк возвращает рублями, баллами или милями.",
          "Cashback is a part of what you spent that the bank pays back in rubles, points or miles."
        )),
      card(
        "lesson.cashback.categories", "square.grid.2x2",
        GuideText("Категории", "Categories"),
        GuideText(
          "Повышенный кэшбэк часто дают в нескольких категориях, выбранных на месяц. Выгода есть, когда категория совпадает с тратами, которые были бы и без неё.",
          "A higher cashback is often given in a few categories chosen for the month. It pays when the category matches spending that would happen anyway."
        )),
      card(
        "lesson.cashback.cap", "gauge.with.dots.needle.100percent",
        GuideText("Потолок", "The cap"),
        GuideText(
          "У кэшбэка бывает потолок в месяц: сверх него банк не платит. Зная потолок, проще понять, сколько вернётся на самом деле.",
          "Cashback often has a monthly cap: above it the bank pays nothing. Knowing the cap makes it easier to see how much really comes back."
        )),
      card(
        "lesson.cashback.points", "star.circle",
        GuideText("Баллы", "Points"),
        GuideText(
          "Баллы не всегда равны рублям: важно, на что и по какому курсу их можно потратить и не сгорают ли они.",
          "Points are not always worth rubles: what matters is what they can be spent on, at what rate, and whether they expire."
        )),
      card(
        "lesson.cashback.app", "creditcard",
        GuideText("В OhMyMoney", "In OhMyMoney"),
        GuideText(
          "Правила кэшбэка задаются у счёта, отличия — у карты. Ожидаемый кэшбэк — ещё не доход: доходом он станет, когда придёт.",
          "Cashback rules belong to the account, a card keeps only its differences. Expected cashback is not income yet: it becomes income when it arrives."
        )),
    ])
}
