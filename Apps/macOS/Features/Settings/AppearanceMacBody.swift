#if os(macOS)
  import AppCore
  import SwiftUI

  /// The Mac's «Оформление» as the design draws it (Figma 6:168900): blocks 18 apart, a title of
  /// 13 semibold over each, segmented tracks for the scheme, the size of the text and the style
  /// of the currency, fixed theme tiles 104 × 58, and a row of accent circles 26 wide. The
  /// tiles of Overview stay below as the form's own section.
  extension AppearanceSettingsView {
    @ViewBuilder
    func macBody(theme: AppTheme) -> some View {
      Form {
        Section { macBlocks(theme: theme) }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        OverviewTilesSection()
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .accessibilityIdentifier("settings.appearance")
      // A sheet is a host of its own: the dependencies are handed over.
      .sheet(item: $previewing) { id in
        AppearancePreviewSheet(
          draft: AppearanceThemeDraft(
            from: environment.theme, themeID: id, systemScheme: colorScheme)
        )
        .handingOver(dependencies)
      }
    }

    fileprivate func macBlocks(theme: AppTheme) -> some View {
      @Bindable var theme = theme
      return VStack(alignment: .leading, spacing: SettingsControlMetrics.blockGap) {
        labelled("settings.appearance.scheme", hint: nil) {
          SettingsSegmented(
            selection: $theme.scheme, choices: Self.schemeOrder,
            title: { Self.schemeTitle($0, environment) },
            identifier: "settings.appearance.scheme")
        }
        VStack(alignment: .leading, spacing: SettingsControlMetrics.labelGap) {
          captionRow(
            title: environment.language("appearance.themes.title", table: "Appearance"),
            hint: environment.language("appearance.themes.hint", table: "Appearance"))
          MacThemeTiles(
            chosen: theme.themeID, scheme: colorScheme,
            name: { environment.language($0.nameKey, table: "Themes") },
            chosenLabel: environment.language("appearance.theme.chosen", table: "Appearance"),
            open: { previewing = $0 })
        }
        VStack(alignment: .leading, spacing: SettingsControlMetrics.labelGap) {
          captionRow(
            title: environment.language("settings.appearance.accent", table: "Settings"),
            hint: environment.language("appearance.accent.hint", table: "Appearance"),
            symbol: "drop")
          AccentSwatches(selection: $theme.accent) { Self.accentTitle($0, environment) }
        }
        HStack(alignment: .top, spacing: SettingsControlMetrics.fontAndCurrencyGap) {
          labelled("settings.appearance.fontSize", hint: nil, symbol: "textformat.size") {
            SettingsSegmented(
              selection: $theme.fontSize, choices: Array(AppFontSize.allCases),
              title: { environment.language($0.settingsKey, table: "Settings") },
              identifier: "settings.appearance.fontSize")
          }
          labelled("settings.appearance.currencyStyle", hint: nil, symbol: "rublesign") {
            SettingsSegmented(
              selection: $theme.currencyStyle, choices: Array(CurrencyStyle.allCases),
              title: { environment.language($0.settingsKey, table: "Settings") },
              identifier: "settings.appearance.currencyStyle")
          }
        }
        Text(verbatim: environment.language("settings.appearance.textHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
        if contrast == .increased {
          Text(verbatim: environment.language("appearance.contrast.note", table: "Appearance"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, SettingsChromeMetrics.contentInset)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled<Content: View>(
      _ key: String, hint: String?, symbol: String? = nil,
      @ViewBuilder content: () -> Content
    ) -> some View {
      VStack(alignment: .leading, spacing: SettingsControlMetrics.labelGap) {
        captionRow(
          title: environment.language(key, table: "Settings"), hint: hint, symbol: symbol)
        content()
      }
    }

    private func captionRow(title: String, hint: String?, symbol: String? = nil) -> some View {
      HStack(spacing: 8) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: 13))  // font-fixed: 16 pt symbol beside a 13 pt title
            .frame(
              width: SettingsControlMetrics.labelIcon, height: SettingsControlMetrics.labelIcon
            )
            .accessibilityHidden(true)
        }
        Text(verbatim: title).appFont(AppFont.body.weight(.semibold))
        if let hint {
          Text(verbatim: hint).appFont(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The thirty themes as the design draws them: fixed tiles of 104 × 58, 10 apart, the name 11
  /// semibold over five dots of the theme's colours; the chosen tile wears a 2-point ring in its
  /// accent and a check, the others a 1-point border.
  struct MacThemeTiles: View {
    @Dependency(\.environment) private var environment
    let chosen: ThemeID
    let scheme: ColorScheme
    let name: (ThemeID) -> String
    let chosenLabel: String
    let open: (ThemeID) -> Void

    var body: some View {
      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(minimum: SettingsControlMetrics.themeTile.width),
            spacing: SettingsControlMetrics.themeGap)
        ],
        alignment: .leading, spacing: SettingsControlMetrics.themeGap
      ) {
        ForEach(ThemeCatalog.all, id: \.id) { tile($0) }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        Text(verbatim: environment.language("appearance.themes.title", table: "Appearance"))
      )
      .accessibilityIdentifier("settings.appearance.themes")
    }

    private func tile(_ theme: Theme) -> some View {
      let palette = scheme == .dark ? theme.dark : theme.light
      let isChosen = theme.id == chosen
      let outline = Color(isChosen ? palette.accentDefault : palette.borderCard)
      let size = SettingsControlMetrics.themeTile
      return Button {
        open(theme.id)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 2) {
            Text(verbatim: name(theme.id))
              .appFont(AppFont.caption.weight(.semibold))
              .foregroundStyle(Color(palette.contentPrimary))
              .lineLimit(1)
            if isChosen {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(palette.accentDefault))
            }
          }
          HStack(spacing: 4) {
            ForEach(
              Array(ThemeSwatches.colors(of: theme, scheme: scheme).enumerated()), id: \.offset
            ) { _, color in
              Circle().fill(Color(color)).frame(
                width: SettingsControlMetrics.themeDotsHeight,
                height: SettingsControlMetrics.themeDotsHeight)
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsControlMetrics.themeTilePadding.width)
        .padding(.vertical, SettingsControlMetrics.themeTilePadding.height)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(
          Color(palette.surfaceCard),
          in: .rect(cornerRadius: SettingsControlMetrics.themeTileRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: SettingsControlMetrics.themeTileRadius)
            .strokeBorder(outline, lineWidth: isChosen ? 2 : 1)
        )
        .contentShape(.rect(cornerRadius: SettingsControlMetrics.themeTileRadius))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(verbatim: name(theme.id)))
      .accessibilityValue(Text(verbatim: isChosen ? chosenLabel : ""))
      .accessibilityAddTraits(isChosen ? [.isSelected] : [])
      .accessibilityIdentifier("settings.appearance.theme.\(theme.id.rawValue)")
    }
  }
#endif
