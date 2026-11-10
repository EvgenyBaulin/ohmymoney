import AppCore
import SwiftUI

/// «Итоги» on a phone (68:18578, 264:91420): a page of «Ещё» with its large title and
/// «Поделиться» in the accent, then the switch and the cards one under another. The Mac and a
/// tablet show the same board on the tab «По периодам» of Reports.
struct SummariesPage: View {
  @Environment(\.appTheme) private var theme
  let deps: AppDependencies
  @State private var store: PeriodsBoardStore

  init(deps: AppDependencies) {
    self.deps = deps
    _store = State(
      initialValue: PeriodsBoardStore(model: SummariesModel(environment: deps.environment)))
  }

  private var environment: AppEnvironment { deps.environment }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: SummariesPageMetrics.titleToContent) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: environment.language("summaries.title", table: "Summaries"))
            .appFont(AppFont.system(size: 34, weight: .bold))
            .foregroundStyle(theme.contentPrimary)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          SummaryShareMenu(store: store, plain: true)
        }
        .padding(.top, SummariesPageMetrics.titleTop)
        PeriodsBoardView(store: store)
      }
      .padding(.horizontal, SummariesPageMetrics.side)
      .padding(.bottom, StyleMetrics.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .themedWindowBackground()
    .accessibilityIdentifier("summaries.page")
  }
}

/// The page of a phone: 16 at the sides, the title 12 under the bar and 8 over the switch.
enum SummariesPageMetrics {
  static let side: CGFloat = 16
  static let titleTop: CGFloat = 12
  static let titleToContent: CGFloat = 8
}
