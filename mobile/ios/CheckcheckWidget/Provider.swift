import WidgetKit

struct Provider: AppIntentTimelineProvider {
  /// How long a ticked row stays on the widget, checked, before it leaves.
  private static let checkedLinger: TimeInterval = 1

  func placeholder(in context: Context) -> ChecklistEntry { .sample }

  func snapshot(for configuration: SelectListIntent, in context: Context) async
    -> ChecklistEntry
  {
    if context.isPreview { return .sample }
    return await entries(for: configuration).last ?? .sample
  }

  func timeline(for configuration: SelectListIntent, in context: Context) async
    -> Timeline<ChecklistEntry>
  {
    Timeline(
      entries: await entries(for: configuration),
      policy: .after(.now.addingTimeInterval(15 * 60))
    )
  }

  /// One entry, or two when items were just ticked: the first shows them
  /// checked in place, the second, a moment later, without them.
  private func entries(for configuration: SelectListIntent) async -> [ChecklistEntry] {
    guard let connection = WidgetConnection.load() else {
      return [ChecklistEntry(date: .now, list: nil, state: .notConnected)]
    }
    let snapshot: Snapshot
    do {
      snapshot = try await ChecklistClient.load(connection)
    } catch ClientError.unauthorized {
      return [ChecklistEntry(date: .now, list: nil, state: .notConnected)]
    } catch {
      guard let kept = ChecklistClient.kept(for: connection) else {
        return [ChecklistEntry(date: .now, list: nil, state: .failed)]
      }
      snapshot = kept
    }
    let list = configuration.list?.id
    let ticked = JustChecked.recent()
    guard !ticked.isEmpty else { return [entry(snapshot, list: list, ticked: [], date: .now)] }
    return [
      entry(snapshot, list: list, ticked: ticked, date: .now),
      entry(snapshot, list: list, ticked: [], date: .now.addingTimeInterval(Self.checkedLinger)),
    ]
  }

  func entry(_ snapshot: Snapshot, list: String?, ticked: Set<Int>, date: Date)
    -> ChecklistEntry
  {
    let hasCategories = !snapshot.categories.isEmpty
    let known = Set(snapshot.categories.map(\.id))
    var all = arrange(snapshot)
    var listName: String?
    if hasCategories, let chosen = all.first(where: { sectionID(of: $0) == list }) {
      all = [chosen]
      listName = chosen?.name ?? "Uncategorized"
    }
    let sections = all.compactMap { category -> WidgetSection? in
      let items = snapshot.items.filter { item in
        let own = known.contains(item.categoryID ?? -1) ? item.categoryID : nil
        return own == category?.id && (!item.checked || ticked.contains(item.id))
      }
      guard !items.isEmpty else { return nil }
      return WidgetSection(
        id: sectionID(of: category),
        title: category?.name ?? (hasCategories ? "Uncategorized" : nil),
        items: items.map { WidgetItem(id: $0.id, title: $0.title, checked: $0.checked) }
      )
    }
    return ChecklistEntry(date: date, list: listName, state: .loaded(sections: sections))
  }
}

/// The app's `arrange`: categories in the order, nil where Uncategorized
/// goes. Categories the order lacks go after the known ones, and
/// Uncategorized last if the order lacks it.
func arrange(_ snapshot: Snapshot) -> [Snapshot.Category?] {
  let byID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
  let known: [Snapshot.Category?] = snapshot.order.compactMap { id in
    guard let id else { return .some(nil) }
    return byID[id].map { .some($0) }
  }
  let listed = Set(snapshot.order.compactMap { $0 })
  let unlisted: [Snapshot.Category?] = snapshot.categories.filter { !listed.contains($0.id) }
  let uncategorized: [Snapshot.Category?] = known.contains { $0 == nil } ? [] : [nil]
  return known + unlisted + uncategorized
}

func sectionID(of category: Snapshot.Category?) -> String {
  category.map { "c\($0.id)" } ?? "none"
}
