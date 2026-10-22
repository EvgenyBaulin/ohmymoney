import AppCore
import SwiftUI

/// The table of a report as a phone shows it: a card with a header line, the lines of the model
/// as plain rows (a parent folds with a tap, its children stand a step in), the average and the
/// total on a darker band. A SwiftUI `Table` shows one column on a phone, so this is the same
/// lines in the same order, drawn by hand. No glass: content.
struct ReportCardTable: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let model: ReportsModel
  @Binding var collapsed: Set<String>

  /// A line to draw: the model's line and how deep it stands.
  struct Row: Identifiable {
    var line: ReportLine
    var depth: Int
    var id: String { line.id }
  }

  /// The lines on screen: a folded parent hides its children.
  static func visibleRows(_ lines: [ReportLine], collapsed: Set<String>) -> [Row] {
    func walk(_ line: ReportLine, depth: Int) -> [Row] {
      var rows = [Row(line: line, depth: depth)]
      if !collapsed.contains(line.id) {
        rows += line.children.flatMap { walk($0, depth: depth + 1) }
      }
      return rows
    }
    return lines.flatMap { walk($0, depth: 0) }
  }

  private var measureCount: Int { model.table.measures.count }
  private var valueWidth: CGFloat { measureCount > 1 ? 78 : 88 }
  private var shareWidth: CGFloat { 66 }

  var body: some View {
    let rows = Self.visibleRows(model.lines, collapsed: collapsed)
    let content = VStack(spacing: 0) {
      headerRow
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        lineRow(row, banded: index % 2 == 1)
      }
    }
    .frame(minWidth: minimumWidth)
    ViewThatFits(in: .horizontal) {
      content
      ScrollView(.horizontal, showsIndicators: false) { content }
    }
    .background(surfaces.card)
    .accessibilityIdentifier("reports.cardTable")
  }

  private var minimumWidth: CGFloat {
    120 + CGFloat(measureCount) * valueWidth + (model.table.hasShares ? shareWidth : 0)
  }

  private var headerRow: some View {
    HStack(spacing: 8) {
      Text(verbatim: ReportsText.nameColumn(model.table.kind, environment))
        .frame(maxWidth: .infinity, alignment: .leading)
      ForEach(Array(model.table.measures.enumerated()), id: \.offset) { _, measure in
        Text(verbatim: ReportsText.column(measure, environment))
          .frame(width: valueWidth, alignment: .trailing)
      }
      if model.table.hasShares {
        Text(verbatim: ReportsText.t("reports.column.share", environment))
          .frame(width: shareWidth, alignment: .trailing)
      }
    }
    .appFont(.caption.weight(.semibold))
    .foregroundStyle(surfaces.secondary)
    .lineLimit(1)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(surfaces.background)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func lineRow(_ row: Row, banded: Bool) -> some View {
    let line = row.line
    let folds = !line.children.isEmpty
    return HStack(spacing: 8) {
      HStack(spacing: 4) {
        if folds {
          Image(systemName: collapsed.contains(line.id) ? "chevron.right" : "chevron.down")
            .appFont(.caption2).foregroundStyle(surfaces.secondary).frame(width: 12)
        } else if row.depth > 0 {
          Color.clear.frame(width: 12)
        }
        Text(verbatim: ReportsText.name(of: line, in: model, environment))
          .fontWeight(line.isSummary || folds ? .semibold : nil)
          .lineLimit(1)
        if let mark = ReportsText.mark(of: line, in: model, environment) {
          Image(systemName: mark.symbol).appFont(.caption2).foregroundStyle(surfaces.secondary)
            .accessibilityLabel(Text(verbatim: mark.text))
        }
      }
      .padding(.leading, CGFloat(row.depth) * 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      ForEach(Array(line.values.indices), id: \.self) { index in
        Text(verbatim: ReportsText.value(of: line, at: index, environment))
          .monospacedDigit()
          .fontWeight(line.isSummary && !line.lacksData ? .semibold : nil)
          .foregroundStyle(line.values[index] == nil ? surfaces.secondary : surfaces.primary)
          .lineLimit(1).minimumScaleFactor(0.8)
          .frame(width: valueWidth, alignment: .trailing)
      }
      if model.table.hasShares {
        Text(verbatim: ReportsText.share(line.share, environment))
          .monospacedDigit()
          .fontWeight(line.isSummary ? .semibold : nil)
          .lineLimit(1)
          .frame(width: shareWidth, alignment: .trailing)
      }
    }
    .appFont(.callout)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(
      line.isSummary
        ? surfaces.secondary.mix(with: surfaces.background, by: 0.84) : (banded ? surfaces.background.mix(with: surfaces.card, by: 0.4) : .clear)
    )
    .contentShape(.rect)
    .onTapGesture {
      guard folds else { return }
      if collapsed.contains(line.id) {
        collapsed.remove(line.id)
      } else {
        collapsed.insert(line.id)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(folds ? .isButton : [])
  }
}
