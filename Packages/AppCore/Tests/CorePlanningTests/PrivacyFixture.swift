import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

@testable import CorePlanning

/// A small life with names that are easy to find again: every free text carries a marker word
/// so a test can look for it in the copy.
struct PrivacyFixture {
  static let markers = [
    "Marina", "Kiosk", "Wedding", "Sber", "Vacation", "Mortgage", "Laptop", "Gift",
  ]

  let personId = UUID()
  let placeId = UUID()
  let eventId = UUID()
  let visibleId = UUID()
  let hiddenId = UUID()
  let hiddenBankId = UUID()
  let visibleBankId = UUID()
  let hiddenCardId = UUID()
  let visibleCardId = UUID()
  let foodId = UUID()
  let purchaseId = UUID()
  let purchasePartId = UUID()
  let refundId = UUID()
  let hiddenOpId = UUID()
  let outTransferId = UUID()
  let inTransferId = UUID()
  let bothTransferId = UUID()
  let debtId = UUID()
  let dataset: Dataset

  static func at(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TravelDay.moscowZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  static func day(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  init() {
    var d = Dataset()
    let food = CoreKit.Category(id: foodId, kind: .expense, name: "Food")
    d.categories = [food]
    d.people = [
      Person(
        id: personId, name: "Marina Ivanova", relation: .friend, aliases: ["Marina", "Masha"],
        birthday: Birthday(month: 3, day: 8, year: nil), giftBudgetE4: AmountE4(whole: 5000))
    ]
    d.places = [Place(id: placeId, name: "Kiosk on the corner", aliases: ["Kiosk"])]
    d.events = [
      Event(
        id: eventId, name: "Wedding of Marina", startDate: Self.day(2026, 5, 1),
        endDate: Self.day(2026, 5, 3))
    ]
    d.banks = [
      Bank(id: visibleBankId, name: "Sber"), Bank(id: hiddenBankId, name: "Secret Bank"),
    ]
    d.paymentMethods = [
      PaymentMethod(
        id: visibleId, name: "Sber Main", currency: .rub, aliases: ["Sber"], isDefault: true,
        bankId: visibleBankId),
      PaymentMethod(id: hiddenId, name: "Secret Savings", currency: .rub, bankId: hiddenBankId),
    ]
    d.accountGroups = [AccountGroup(name: "Vacation money")]
    d.cards = [
      PaymentCard(
        id: visibleCardId, accountId: visibleId, name: "Sber Visa", aliases: ["Visa-alias"],
        last4: "1234", details: "pin in the drawer"),
      PaymentCard(id: hiddenCardId, accountId: hiddenId, name: "Secret card"),
    ]
    d.goals = [Goal(name: "Vacation", targetE4: AmountE4(whole: 100_000), accountId: hiddenId)]
    d.debts = [
      Debt(
        id: debtId, direction: .iOwe, type: .loan, name: "Mortgage", note: "call Sergey")
    ]
    d.assets = [Asset(name: "Laptop fund", note: "in-the-safe-note")]
    d.ownedItems = [OwnedItem(name: "Laptop", note: "bought-for-work-note")]
    d.wishes = [
      Wish(
        name: "Gift for Marina", url: "https://shop.example/marina", note: "size-M-note",
        createdOn: Self.day(2026, 1, 1))
    ]
    d.shoppingItems = [
      ShoppingItem(name: "Gift paper", note: "red-ribbon-note", createdOn: Self.day(2026, 1, 1))
    ]
    let tag = Tag(name: "Vacation")
    d.tagBook = TagBook(tags: [tag], links: [PartTag(partId: purchasePartId, tagId: tag.id)])
    d.rules = [
      Rule(
        name: "Kiosk is food",
        conditions: [.textContains("kiosk"), .amountAbove(AmountE4(whole: 1))],
        actions: [.setCategory(foodId)])
    ]
    d.dayNotes = [DayNote(day: Self.day(2026, 5, 2), text: "Wedding day, wear the blue one")]
    d.feedback = [
      CategoryFeedback(
        text: "kiosk coffee Marina", predictedCategoryId: foodId, chosenCategoryId: foodId,
        partId: purchasePartId, confidenceBp: 9000, at: Self.at(2026, 5, 2))
    ]
    d.dismissals = [
      AnomalyDismissal(rule: .largeExpense, subject: "Kiosk coffee", at: Self.at(2026, 5, 2))
    ]
    d.planning.scheduled = [
      ScheduledPayment(
        name: "Wedding hall rent", amountE4: AmountE4(whole: 100), paymentMethodId: hiddenId,
        cancelURL: "https://x.example/cancel"),
      ScheduledPayment(
        name: "Gym Marina", amountE4: AmountE4(whole: 50), paymentMethodId: visibleId),
    ]
    d.planning.expected = [
      ExpectedIncome(
        name: "Salary of Marina", totalE4: AmountE4(whole: 10), dueDate: Self.day(2026, 5, 10),
        paymentMethodId: hiddenId)
    ]
    d.planning.debtEntries = [
      DebtEntry(
        debtId: debtId, groupName: "Mortgage Sergey", date: Self.day(2026, 5, 4),
        description: "to Sergey", amountE4: AmountE4(whole: 10), kind: .payment,
        note: "cash-from-Sergey",
        paymentMethodId: hiddenId)
    ]

    // A purchase in April and its refund in June; an operation on the hidden account.
    let purchase = TransactionEntry(
      transaction: Transaction(
        id: purchaseId, kind: .expense, occurredAt: Self.at(2026, 4, 20),
        amountE4: AmountE4(whole: 300),
        note: "coffee at Kiosk with Marina", placeId: placeId, paymentMethodId: visibleId,
        externalId: "BANK-REF-77", cardId: visibleCardId, dedupKey: "v1:abcdef",
        warrantyWhere: "drawer"),
      parts: [
        TransactionPart(
          id: purchasePartId, transactionId: purchaseId, categoryId: foodId,
          amountE4: AmountE4(whole: 300), forPersonId: personId, eventId: eventId,
          note: "latte for Marina")
      ])
    let refundPartId = UUID()
    let refund = TransactionEntry(
      transaction: Transaction(
        id: refundId, kind: .refund, occurredAt: Self.at(2026, 6, 5),
        amountE4: AmountE4(whole: 100),
        note: "refund Kiosk", paymentMethodId: visibleId, externalId: "sched:abc"),
      parts: [
        TransactionPart(
          id: refundPartId, transactionId: refundId, categoryId: foodId,
          amountE4: AmountE4(whole: 100), refundOfPartId: purchasePartId)
      ])
    let hiddenOp = TransactionEntry(
      transaction: Transaction(
        id: hiddenOpId, kind: .expense, occurredAt: Self.at(2026, 6, 6),
        amountE4: AmountE4(whole: 70),
        note: "secret-note", paymentMethodId: hiddenId),
      parts: [
        TransactionPart(
          transactionId: hiddenOpId, categoryId: foodId, amountE4: AmountE4(whole: 70))
      ])
    d.entries = [purchase, refund, hiddenOp]

    d.transfers = [
      Transfer(
        id: outTransferId, occurredAt: Self.at(2026, 6, 7), fromAccountId: visibleId,
        fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1000), toAccountId: hiddenId,
        toCurrency: .rub, toAmountE4: AmountE4(whole: 1000), note: "to Marina's fund"),
      Transfer(
        id: inTransferId, occurredAt: Self.at(2026, 6, 8), fromAccountId: hiddenId,
        fromCurrency: .rub, fromAmountE4: AmountE4(whole: 400), toAccountId: visibleId,
        toCurrency: .rub, toAmountE4: AmountE4(whole: 400)),
      Transfer(
        id: bothTransferId, occurredAt: Self.at(2026, 6, 9), fromAccountId: hiddenId,
        fromCurrency: .rub, fromAmountE4: AmountE4(whole: 5), toAccountId: hiddenId,
        toCurrency: .usd, toAmountE4: AmountE4(whole: 1)),
    ]
    self.dataset = d
  }
}
