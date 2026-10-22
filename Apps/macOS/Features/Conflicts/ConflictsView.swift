import AppCore
import AppDatabase
import SwiftUI

/// The banner over a screen while records wait for the owner: «Конфликты: 2 записи ждут решения»
/// and «Разобрать». Nothing is drawn when none waits.
struct ConflictsBanner: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator
  let open: () -> Void

  var body: some View {
    if !coordinator.conflicts.isEmpty {
      HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle")
          .accessibilityHidden(true)
        Text(
          verbatim: ConflictText.count(
            "sync.conflicts.banner", coordinator.conflicts.count, environment)
        )
        .appFont(.callout)
        Spacer()
        Button(ConflictText.t("sync.conflicts.review", environment), action: open)
          .accessibilityIdentifier("sync.conflicts.review")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.background.secondary)
      .accessibilityIdentifier("sync.conflicts.banner")
    }
  }
}

/// «Конфликты»: the records another device changed apart from this one. Each row opens the
/// comparison; until the owner chooses, the other version is in no sum.
struct ConflictsList: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator
  @State private var selected: SyncConflict.ID?

  var body: some View {
    List(selection: $selected) {
      if coordinator.conflicts.isEmpty {
        Text(verbatim: ConflictText.t("sync.conflicts.empty", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("sync.conflicts.empty")
      }
      ForEach(coordinator.conflicts) { conflict in
        let comparison = ConflictComparison.make(conflict)
        NavigationLink(value: conflict.id) {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: comparison.title ?? ConflictText.t(comparison.tableKey, environment))
              .appFont(.headline)
            Text(
              verbatim:
                "\(ConflictText.t(comparison.tableKey, environment)) · \(ConflictText.t("sync.conflicts.waiting", environment))"
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("sync.conflicts.row")
      }
    }
    .navigationTitle(ConflictText.t("sync.conflicts.title", environment))
    .navigationDestination(for: SyncConflict.ID.self) { id in
      if let conflict = coordinator.conflicts.first(where: { $0.id == id }) {
        ConflictDetailView(coordinator: coordinator, conflict: conflict)
      } else {
        // Settled meanwhile (here or by the other device): the row is gone.
        Text(verbatim: ConflictText.t("sync.conflicts.empty", environment))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// The comparison and the choice: mine on the left, the other device's on the right, the fields
/// that differ marked with a symbol and a border, never by colour alone.
struct ConflictDetailView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let coordinator: SyncCoordinator
  let conflict: SyncConflict

  private var comparison: ConflictComparison { ConflictComparison.make(conflict) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: comparison.title ?? ConflictText.t(comparison.tableKey, environment))
            .appFont(.headline)
          Text(verbatim: ConflictText.t("sync.conflict.changedOnTwo", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        Text(verbatim: ConflictText.t("sync.conflicts.explain", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        header
        ForEach(comparison.rows) { row in rowView(row) }
        if comparison.mineDeleted || comparison.theirsDeleted { deletedLine }
        HStack(spacing: 12) {
          Button {
            Task {
              await coordinator.keepMine(conflict)
              dismiss()
            }
          } label: {
            Text(verbatim: ConflictText.t("sync.conflicts.keepMine", environment))
              .frame(maxWidth: .infinity)
          }
          .accessibilityIdentifier("sync.conflicts.keepMine")
          Button {
            Task {
              await coordinator.takeTheirs(conflict)
              dismiss()
            }
          } label: {
            Text(verbatim: ConflictText.t("sync.conflicts.takeTheirs", environment))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("sync.conflicts.takeTheirs")
        }
        .controlSize(.large)
        Text(verbatim: ConflictText.t("sync.conflicts.footnote", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)
    }
    .navigationTitle(comparison.title ?? ConflictText.t(comparison.tableKey, environment))
  }

  private var header: some View {
    HStack {
      Text(verbatim: ConflictText.t("sync.conflicts.mine", environment))
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(verbatim: ConflictText.t("sync.conflicts.theirs", environment))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  private func rowView(_ row: ConflictComparison.Row) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(verbatim: ConflictText.label(row.id, environment))
        if row.differs {
          Image(systemName: "pencil.circle")
            .accessibilityLabel(ConflictText.t("sync.conflicts.differs", environment))
        }
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        cell(row.mine, differs: row.differs)
        cell(row.theirs, differs: row.differs)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func cell(_ cell: ConflictComparison.Cell, differs: Bool) -> some View {
    Text(verbatim: ConflictText.cell(cell, environment))
      .appFont(.callout.monospacedDigit())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(.background.secondary, in: .rect(cornerRadius: 8))
      .overlay {
        if differs {
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1)
        }
      }
  }

  private var deletedLine: some View {
    HStack(spacing: 8) {
      Label(ConflictText.t("sync.conflicts.deletedHere", environment), systemImage: "trash")
        .opacity(comparison.mineDeleted ? 1 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
      Label(ConflictText.t("sync.conflicts.deletedThere", environment), systemImage: "trash")
        .opacity(comparison.theirsDeleted ? 1 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .appFont(.caption)
  }
}
