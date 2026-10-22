import AppCore
import SwiftUI

/// What quick entry says above the line: the corrected operation waiting for «Исправить», the
/// text of a bank that was read, the places that begin like the word being typed, the parts of
/// a «;» line still waiting, «Запишу потом» and the drafts. Nothing here writes by itself: each
/// button is the owner's word. It stands on one glass panel, like the ↓ panel it shares a
/// container with; the buttons on it are plain.
struct QuickEntryStrip: View {
  @Bindable var model: QuickEntryModel
  @Binding var text: String
  /// The line is written again with the owner's correction; the bar clears the line.
  let applyCorrection: () -> Void
  /// Puts the keyboard back in the line.
  let refocus: () -> Void

  @Dependency(\.environment) private var environment

  var body: some View {
    if hasContent {
      GlassPanel {
        VStack(alignment: .leading, spacing: 8) {
          if let correction = model.correction { correctionRow(correction) }
          if let bank = model.bank { bankRows(bank) }
          if !model.suggestions.isEmpty { suggestionRow }
          if !model.waitingParts.isEmpty { queueRow }
          if let failure = model.failure { failureRow(failure) }
          if let notice = model.notice { noticeRow(notice) }
          draftRow
        }
        .appFont(.callout)
      }
      .accessibilityIdentifier("quick.strip")
    }
  }

  private var hasContent: Bool {
    model.correction != nil || model.bank != nil || !model.suggestions.isEmpty
      || !model.waitingParts.isEmpty || model.failure != nil || model.notice != nil
      || showsDraftRow
  }

  private func t(_ key: String) -> String { QuickText.t(key, environment) }

  // MARK: Correction

  private func correctionRow(_ offer: QuickCorrection.Offer) -> some View {
    HStack(spacing: 10) {
      Label {
        Text(verbatim: QuickText.correction(offer, environment))
      } icon: {
        Image(systemName: "pencil.line")
      }
      Spacer(minLength: 8)
      Button(t("quick.correction.apply"), action: applyCorrection)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityIdentifier("quick.correction.apply")
      Button(environment.language("action.cancel")) {
        model.correction = nil
        refocus()
      }
      .controlSize(.small)
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: Text of a bank

  @ViewBuilder
  private func bankRows(_ offer: BankOffer) -> some View {
    HStack(spacing: 10) {
      Label {
        Text(verbatim: QuickText.bank(offer, environment))
      } icon: {
        Image(systemName: "building.columns")
      }
      Spacer(minLength: 8)
      if case .unknown(let last4) = offer.question {
        Button(t("quick.bank.askCard")) {
          model.cardAsk = QuickEntryModel.CardAsk(last4: last4, candidates: [])
        }
        .controlSize(.small)
        .accessibilityIdentifier("quick.bank.askCard")
      }
      Button {
        model.bank = nil
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: environment.language("action.close")))
    }
    if let balance = QuickText.balance(offer, environment) {
      Toggle(
        isOn: Binding(
          get: { model.bank?.reconcileAfter ?? false },
          set: { model.bank?.reconcileAfter = $0 })
      ) {
        Text(verbatim: balance)
      }
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("quick.bank.reconcile")
    }
  }

  // MARK: Places

  private var suggestionRow: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(model.suggestions, id: \.placeId) { suggestion in
          Button {
            text = model.choose(suggestion, in: text)
            refocus()
          } label: {
            Label {
              Text(verbatim: QuickText.suggestion(suggestion, environment))
            } icon: {
              Image(systemName: "mappin.circle")
            }
          }
          .controlSize(.small)
          .accessibilityIdentifier("quick.suggestion")
        }
      }
    }
    .scrollIndicators(.never)
    .accessibilityLabel(Text(verbatim: t("quick.suggest.label")))
  }

  // MARK: Parts of a line with «;»

  private var queueRow: some View {
    HStack(spacing: 10) {
      Label {
        Text(
          verbatim: QuickText.counted("quick.queue.waiting", environment, model.waitingParts.count))
      } icon: {
        Image(systemName: "list.number")
      }
      Spacer(minLength: 8)
      Button(t("quick.queue.cancel")) {
        model.dropWaitingParts()
        refocus()
      }
      .controlSize(.small)
    }
  }

  // MARK: Failure and notice

  private func failureRow(_ key: String) -> some View {
    Label {
      Text(verbatim: t(key))
    } icon: {
      Image(systemName: "exclamationmark.triangle")
    }
    .foregroundStyle(.orange)
    .accessibilityIdentifier("quick.failure")
  }

  private func noticeRow(_ text: String) -> some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: "checkmark.circle")
    }
    .foregroundStyle(.secondary)
  }

  // MARK: Drafts

  private var waitingDrafts: Int { model.drafts.waiting.count }

  /// A line with words and no amount is unfinished: «Запишу потом» keeps it. The drafts that
  /// wait are listed while the line is empty.
  private var canKeep: Bool {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !typed.isEmpty, model.bank == nil else { return false }
    return model.parser(environment).parse(typed, today: environment.today).amount == nil
  }

  private var showsDraftRow: Bool {
    canKeep || (waitingDrafts > 0 && text.isEmpty)
  }

  @ViewBuilder
  private var draftRow: some View {
    if showsDraftRow {
      HStack(spacing: 10) {
        if canKeep {
          Button {
            if model.keepForLater(text, environment: environment) {
              text = ""
              model.bank = nil
            }
          } label: {
            Label(t("quick.draft.later"), systemImage: "clock.arrow.circlepath")
          }
          .controlSize(.small)
          .accessibilityIdentifier("quick.draft.later")
        }
        if waitingDrafts > 0 && text.isEmpty {
          Button {
            model.showsDrafts = true
          } label: {
            Label(
              QuickText.counted("quick.draft.list", environment, waitingDrafts),
              systemImage: "tray.full")
          }
          .controlSize(.small)
          .accessibilityIdentifier("quick.draft.list")
        }
        Spacer(minLength: 0)
      }
    }
  }
}
