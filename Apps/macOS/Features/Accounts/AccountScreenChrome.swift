import AppCore
import SwiftUI

/// The words of the hero card at the top of an account's screen: «Т-Банк Black · карта», the
/// balance big, and when it was counted and what the account is. Built without a view so both
/// languages are checked in a test.
struct AccountHero: Equatable {
  var caption: String
  var figure: String
  var lines: [String]

  /// The words of `AccountText` the card needs, in the language of the interface.
  struct Words {
    var kind: String
    var countedAt: (Date) -> String
    var notCounted: String
    var main: String
    var cushion: String
  }

  /// One currency holds its exact balance — it is compared with the bank —; several show what
  /// they come to in rubles with «≈»; an account never counted shows a dash and says so.
  static func make(
    line: AccountsSnapshot.AccountLine, words: Words, money: MoneyFormatter
  ) -> AccountHero {
    let counted = line.keys.filter { $0.balance != nil }
    var figure = "\u{2014}"
    var lines: [String] = []
    if counted.count == 1, let key = counted.first, let balance = key.balance {
      figure = money.exact(balance, currency: key.key.currency)
      if let at = key.anchorAt { lines.append(words.countedAt(at)) }
    } else if counted.count > 1, let total = line.totalRub {
      figure = "\u{2248}\u{00A0}\(money.rounded(total))"
    }
    if counted.isEmpty { lines.append(words.notCounted) }
    var marks: [String] = []
    if line.account.isDefault { marks.append(words.main) }
    if line.account.cushion { marks.append(words.cushion) }
    if !marks.isEmpty { lines.append(marks.joined(separator: " \u{00B7} ")) }
    return AccountHero(
      caption: "\(line.account.name) \u{00B7} \(words.kind)", figure: figure, lines: lines)
  }
}

/// Two columns of cards on a wide screen, one on a narrow one: `leading` and `trailing` side by
/// side, or `stacked` — the order a narrow screen reads them in, which is not always the two
/// columns one after the other. The break is the one Planning, Capital and a trip use.
struct AccountColumns<Leading: View, Trailing: View, Stacked: View>: View {
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var stacked: Stacked
  @State private var width: CGFloat = 0

  var body: some View {
    Group {
      if ScreenColumns.count(forWidth: width) == 2 {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 12) { leading }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          VStack(alignment: .leading, spacing: 12) { trailing }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) { stacked }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }
}

/// «Перевод…», «Сверить…», «Изменить…» as a row of equal buttons: the first stands out, the
/// others are quiet. The words carry the meaning; the prominence only says which comes first.
struct AccountActionRow: View {
  struct Action: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var run: () -> Void
  }

  let actions: [Action]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(actions.enumerated()), id: \.element.id) { position, action in
        let button = Button(action: action.run) {
          Label {
            Text(verbatim: action.title)
          } icon: {
            Image(systemName: action.symbol)
          }
          .labelStyle(.titleOnly)
          .lineLimit(1)
          .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier(action.id)
        if position == 0 {
          button.buttonStyle(.borderedProminent)
        } else {
          button.buttonStyle(.bordered)
        }
      }
    }
  }
}
