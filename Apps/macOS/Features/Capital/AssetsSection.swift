import AppCore
import SwiftUI

/// «Имущество»: the things valued by hand, each with its last valuation and its day, and the
/// ones sold or written off under «Проданное». Every row has a menu — «Новая оценка…», «История
/// оценок», «Изменить…», «Продано / списано…», «Удалить…» —; the sheets themselves hang on the
/// screen (`CapitalSheet`).
struct AssetsSection: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let assets: [Asset]
  let valuations: [AssetValuation]
  @Binding var sheet: CapitalSheet?
  @Binding var deleting: Asset?
  @State private var refusal: String?

  var body: some View {
    let today = environment.today
    let ordered = AssetActions.ordered(assets, today: today, locale: environment.language.locale)
    let live = ordered.filter { !$0.isDisposed(on: today) }
    let gone = ordered.filter { $0.isDisposed(on: today) }
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: CapitalText.t("capital.assets.title", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button(CapitalText.t("capital.assets.add", environment)) { sheet = .newAsset }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("capital.assets.add")
      }
      if assets.isEmpty {
        Text(verbatim: CapitalText.t("capital.assets.empty", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(live) { asset in row(asset) }
      if !gone.isEmpty {
        Text(verbatim: CapitalText.t("capital.assets.disposed", environment))
          .appFont(.subheadline.weight(.semibold))
          .padding(.top, 4)
        ForEach(gone) { asset in row(asset) }
      }
      if let refusal {
        Text(verbatim: CapitalText.t(refusal, environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentCard()
  }

  private func row(_ asset: Asset) -> some View {
    let latest = AssetActions.latest(of: asset.id, among: valuations)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: CapitalText.kindSymbol(asset.kind))
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          Text(verbatim: CapitalText.t(CapitalText.kindKey(asset.kind), environment)))
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: asset.name)
        Text(verbatim: subtitle(asset, latest))
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if let note = asset.note {
          Text(verbatim: note)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if let latest {
        Text(verbatim: environment.money.rounded(latest.valueE4, currency: asset.currency))
          .monospacedDigit()
          .foregroundStyle(asset.isDisposed(on: environment.today) ? .secondary : .primary)
      }
      Menu {
        menu(asset)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(
        Text(verbatim: CapitalText.format("capital.assets.menu", environment, asset.name))
      )
      .accessibilityIdentifier("capital.asset.menu.\(asset.id)")
    }
    .padding(.vertical, 2)
    .contextMenu { menu(asset) }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func menu(_ asset: Asset) -> some View {
    Button(CapitalText.t("capital.assets.newValuation", environment)) { sheet = .value(asset) }
    Button(CapitalText.t("capital.assets.history", environment)) { sheet = .history(asset) }
    Button(CapitalText.t("capital.assets.edit", environment)) { sheet = .edit(asset) }
    if asset.disposedOn == nil {
      Button(CapitalText.t("capital.assets.dispose", environment)) { sheet = .dispose(asset) }
    } else {
      Button(CapitalText.t("capital.assets.undispose", environment)) {
        guard let dependencies else { return }
        refusal = CapitalText.refusalKey(AssetActions(dependencies).dispose(asset, on: nil))
      }
    }
    Divider()
    Button(CapitalText.t("capital.assets.delete", environment), role: .destructive) {
      deleting = asset
    }
  }

  /// «1,500,000 ₽ на 1 октября 2026», «Ещё нет оценки», and for one sold «Продано или списано
  /// 3 октября 2026».
  private func subtitle(_ asset: Asset, _ latest: AssetValuation?) -> String {
    var parts: [String] = []
    if let latest {
      parts.append(
        CapitalText.format(
          "capital.assets.valuedOn", environment, environment.dates.longDay(latest.day)))
    } else {
      parts.append(CapitalText.t("capital.assets.unvalued", environment))
    }
    if let disposed = asset.disposedOn {
      parts.append(
        CapitalText.format(
          "capital.assets.disposedOn", environment, environment.dates.longDay(disposed)))
    }
    return parts.joined(separator: " · ")
  }
}
