import AppCore
import SwiftUI

/// The first step: every file with the account it goes to and what loading it would do, in counts;
/// the checks of the file against itself; «Кто вы в выписках».
struct StatementFilesStep: View {
  let model: StatementImportModel
  @Binding var picking: Bool
  @Binding var editsIdentity: Bool

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(model.files) { file in
          StatementFileCard(model: model, file: file)
        }
        HStack {
          Button {
            picking = true
          } label: {
            Label(t("import.addMore"), systemImage: "plus")
          }
          .accessibilityIdentifier("import.addMore")
          Button {
            editsIdentity = true
          } label: {
            Label(t("import.identity.open"), systemImage: "person.crop.circle")
          }
          .accessibilityIdentifier("import.identity.open")
          Spacer()
        }
        .buttonStyle(.link)
        Text(verbatim: t("import.identity.hint"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
    }
  }
}

/// One file as a card: name, format, account, counts and what stops or warns.
struct StatementFileCard: View {
  let model: StatementImportModel
  let file: StatementImportModel.LoadedFile

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: file.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "tablecells")
          .foregroundStyle(.secondary).accessibilityHidden(true)
        Text(verbatim: file.name).appFont(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button {
          model.remove(file: file.id)
        } label: {
          Label(t("import.remove"), systemImage: "xmark.circle")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(t("import.remove"))
        .accessibilityIdentifier("import.file.remove")
      }
      switch file.reading {
      case .parsed(let parsed):
        parsedBody(parsed)
      case .unknownFormat(let hint):
        problem("import.unknown.title", "import.unknown.body")
        UnknownFormatRequest(hint: hint)
      case .scan:
        problem("import.scan.title", "import.scan.body")
      case .unreadable, .failed:
        problem("import.unreadable.title", "import.unreadable.body")
      }
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import.file")
  }

  private func problem(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(t(title), systemImage: "exclamationmark.triangle")
        .appFont(.callout.weight(.semibold))
      Text(verbatim: t(body))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func parsedBody(_ parsed: StatementParseResult) -> some View {
    let bank = StatementProfiles.profile(id: parsed.profileID)?.bankName ?? parsed.profileID
    HStack(spacing: 8) {
      Text(verbatim: ImportText.format("import.format", environment, bank))
        .appFont(.callout).foregroundStyle(.secondary)
      if let period = file.preview?.period {
        Text(verbatim: "·").foregroundStyle(.secondary)
        Text(
          verbatim:
            "\(environment.dates.longDay(period.from)) – \(environment.dates.longDay(period.to))"
        )
        .appFont(.callout).foregroundStyle(.secondary)
      }
    }
    Picker(selection: accountBinding) {
      Text(verbatim: t("import.account.choose")).tag(UUID?.none)
      ForEach(model.accounts) { account in
        Text(verbatim: account.name).tag(UUID?.some(account.id))
      }
    } label: {
      Text(verbatim: t("import.account"))
    }
    .accessibilityIdentifier("import.account")
    if file.accountID == nil {
      Label(t("import.account.needed"), systemImage: "arrow.up")
        .appFont(.callout).foregroundStyle(.secondary)
    }
    if let preview = file.preview {
      counts(preview)
      checks(preview)
      notes(preview)
    }
  }

  private var accountBinding: Binding<UUID?> {
    Binding(get: { file.accountID }, set: { model.setAccount($0, for: file.id) })
  }

  private func counts(_ preview: StatementPreview) -> some View {
    HStack(spacing: 14) {
      count("plus.circle", "import.count.new", preview.newCount)
      count("equal.circle", "import.count.duplicate", preview.duplicateCount)
      count("arrow.triangle.2.circlepath", "import.count.changed", preview.changedCount)
      if preview.unparsedCount > 0 {
        count("questionmark.diamond", "import.count.unparsed", preview.unparsedCount)
      }
      if preview.declinedCount > 0 {
        count("xmark.circle", "import.count.declined", preview.declinedCount)
      }
    }
    .appFont(.callout)
  }

  private func count(_ symbol: String, _ key: String, _ number: Int) -> some View {
    Label {
      Text(verbatim: ImportText.counted(key, environment, number)).monospacedDigit()
    } icon: {
      Image(systemName: symbol)
    }
    .foregroundStyle(number == 0 ? .secondary : .primary)
  }

  @ViewBuilder
  private func checks(_ preview: StatementPreview) -> some View {
    ForEach(Array(preview.blockingFailures.enumerated()), id: \.offset) { _, check in
      VStack(alignment: .leading, spacing: 2) {
        Label(t("import.check.footer.title"), systemImage: "exclamationmark.octagon")
          .appFont(.callout.weight(.semibold)).foregroundStyle(.red)
        Text(
          verbatim: ImportText.format(
            "import.check.footer.body", environment,
            environment.money.exact(check.missingIncome),
            environment.money.exact(check.missingExpense))
        )
        .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("import.check.failed")
    }
  }

  @ViewBuilder
  private func notes(_ preview: StatementPreview) -> some View {
    if preview.unparsedCount > 0 {
      Label(
        ImportText.format(
          "import.note.unparsed", environment, preview.unparsedCount,
          environment.money.exact(preview.unparsedSum)), systemImage: "questionmark.diamond"
      )
      .appFont(.callout).foregroundStyle(.secondary)
    }
    if preview.usedLegacyEncoding {
      Label(t("import.note.encoding"), systemImage: "textformat")
        .appFont(.callout).foregroundStyle(.secondary)
    }
    if let before = file.loadedBefore {
      Label(
        ImportText.format(
          "import.note.loadedBefore", environment,
          environment.dates.longDay(environment.calendar.day(of: before))),
        systemImage: "clock.arrow.circlepath"
      )
      .appFont(.callout).foregroundStyle(.secondary)
      .accessibilityIdentifier("import.note.loadedBefore")
    }
  }
}

/// A format no profile knows: what the first line looked like, and a request for the bank that
/// can be sent on. The cells are shown to the person only.
struct UnknownFormatRequest: View {
  let hint: [String]
  @Dependency(\.environment) private var environment

  var body: some View {
    let text = ImportText.format("import.request.text", environment, hint.joined(separator: " | "))
    ShareLink(item: text) {
      Label(ImportText.t("import.request.share", environment), systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.link)
    .accessibilityIdentifier("import.request")
  }
}
