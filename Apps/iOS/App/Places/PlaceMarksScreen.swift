import AppCore
import AppDatabase
import MapKit
import SwiftUI

/// «Места»: the owner's marks on the map, the switch for the hints near them and the map of
/// spending at them. Everything is off until switched on, and every coordinate stays on this
/// phone: the marks are not sent to another device, not in the CSV and not in a log.
struct PlaceMarksScreen: View {
  let deps: AppDependencies

  @State private var marks: [PlaceMark] = []
  @State private var hintsOn = PlaceHintsSettings.hintsEnabled()
  @State private var mapOn = PlaceHintsSettings.mapEnabled()
  @State private var naming: GeoPoint?
  @State private var newName = ""
  @State private var newCategory: UUID?
  @State private var cannotLocate = false
  @State private var failed = false

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: PlaceHintText.table) }

  private var repository: PlaceMarkRepository? {
    environment.stack.map { PlaceMarkRepository(stack: $0) }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: hintsBinding) { Text(verbatim: t("places.hints.toggle")) }
          .accessibilityIdentifier("places.hints.toggle")
      } footer: {
        Text(verbatim: t("places.hints.footer"))
      }
      Section {
        Button {
          Task { await markHere() }
        } label: {
          Label(t("places.mark.here"), systemImage: "mappin.and.ellipse")
        }
        .accessibilityIdentifier("places.mark.here")
        if cannotLocate {
          Text(verbatim: t("places.mark.cannotLocate")).secondaryInk()
        }
        ForEach(marks) { mark in
          row(mark)
        }
        .onDelete(perform: delete)
      } header: {
        Text(verbatim: t("places.marks.header"))
      } footer: {
        if marks.isEmpty { Text(verbatim: t("places.marks.empty")) }
      }
      Section {
        Toggle(isOn: mapBinding) { Text(verbatim: t("places.map.toggle")) }
          .accessibilityIdentifier("places.map.toggle")
        if mapOn {
          if marks.isEmpty {
            Text(verbatim: t("places.map.empty")).secondaryInk()
          } else {
            spendingMap
          }
        }
      } footer: {
        Text(verbatim: t("places.map.footer"))
      }
    }
    .navigationTitle(t("places.title"))
    .navigationBarTitleDisplayMode(.inline)
    .task { reload() }
    .sheet(item: Binding(get: { naming.map(Naming.init) }, set: { if $0 == nil { naming = nil } }))
    {
      item in
      nameSheet(point: item.point)
    }
    .alert(t("places.failed"), isPresented: $failed) {
      Button(environment.language("action.ok")) {}
    }
  }

  // MARK: Rows

  private func row(_ mark: PlaceMark) -> some View {
    Toggle(
      isOn: Binding(
        get: { mark.enabled },
        set: { on in
          try? repository?.setEnabled(on, id: mark.id)
          reload()
        })
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: mark.name)
        Text(
          verbatim: String(
            format: t("places.mark.radius"), locale: environment.language.locale,
            mark.radiusMeters)
        )
        .appFont(.caption)
        .secondaryInk()
      }
    }
  }

  // MARK: Map

  private var spendingMap: some View {
    let ledger = deps.compute.snapshot?.ledger
    let month = environment.today.monthKey
    let report = ledger.map { PlacesReport(ledger: $0, period: .month(month)) }
    return Map(initialPosition: .automatic) {
      ForEach(marks) { mark in
        let spent = mark.placeId.flatMap { id in report?.places.first { $0.placeId == id } }
        Marker(
          spent.map { "\(mark.name) · \(environment.money.rounded($0.mySpending))" } ?? mark.name,
          systemImage: "mappin",
          coordinate: mark.point.coordinate)
        MapCircle(center: mark.point.coordinate, radius: CLLocationDistance(mark.radiusMeters))
          .foregroundStyle(.tint.opacity(0.15))
      }
    }
    .frame(height: 280)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("places.map")
  }

  // MARK: Naming a new mark

  private struct Naming: Identifiable {
    let point: GeoPoint
    var id: String { "\(point.latitudeE7):\(point.longitudeE7)" }
  }

  private var categoryChoices: [CoreKit.Category] {
    (deps.compute.snapshot?.dataset.categories ?? [])
      .filter { $0.kind == .expense && $0.parentId == nil && !$0.archived }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func nameSheet(point: GeoPoint) -> some View {
    NavigationStack {
      Form {
        Section {
          TextField(t("places.mark.name"), text: $newName)
            .accessibilityIdentifier("places.mark.name")
        }
        Section {
          Picker(t("places.mark.category"), selection: $newCategory) {
            Text(verbatim: t("places.mark.noCategory")).tag(UUID?.none)
            ForEach(categoryChoices) { category in
              Text(verbatim: category.name).tag(UUID?.some(category.id))
            }
          }
        } footer: {
          Text(verbatim: t("places.mark.categoryFooter"))
        }
      }
      .navigationTitle(t("places.mark.new"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(environment.language("action.cancel")) { naming = nil }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(environment.language("action.save")) { save(at: point) }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }

  // MARK: Actions

  private var hintsBinding: Binding<Bool> {
    Binding(
      get: { hintsOn },
      set: { on in
        hintsOn = on
        PlaceHintsSettings.setHints(on)
        Task {
          if on { await PlaceHintsService.shared.askPermissions() }
          PlaceHintsService.shared.resume(deps: deps)
        }
      })
  }

  private var mapBinding: Binding<Bool> {
    Binding(
      get: { mapOn },
      set: { on in
        mapOn = on
        PlaceHintsSettings.setMap(on)
      })
  }

  private func reload() {
    marks = (try? repository?.all()) ?? []
  }

  private func markHere() async {
    cannotLocate = false
    guard let point = await PlaceGeofenceController.shared.currentPoint() else {
      cannotLocate = true
      return
    }
    newName = ""
    newCategory = nil
    naming = point
  }

  private func save(at point: GeoPoint) {
    let name = newName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let repository else { return }
    do {
      try repository.save(PlaceMark(name: name, point: point, categoryId: newCategory))
      naming = nil
      reload()
      PlaceHintsService.shared.resume(deps: deps)
    } catch {
      failed = true
    }
  }

  private func delete(at offsets: IndexSet) {
    for index in offsets { try? repository?.delete(id: marks[index].id) }
    reload()
    PlaceHintsService.shared.resume(deps: deps)
  }
}
