import WidgetKit

struct WidgetItem: Hashable, Identifiable {
  let id: Int
  let title: String
  /// Only for an item ticked on the widget moments ago, shown in place until
  /// the timeline's next entry drops it.
  let checked: Bool
}

/// One of the app's sections, Uncategorized included.
struct WidgetSection: Hashable, Identifiable {
  /// `c<id>` for a category, `none` for Uncategorized, like the app's keys.
  let id: String
  /// Nil when there are no categories, like the app's one unheaded section.
  let title: String?
  /// Open items in list order.
  let items: [WidgetItem]
}

enum ChecklistState: Hashable {
  case notConnected
  /// The server couldn't be reached and there is no kept copy to show.
  case failed
  /// `sections` are in the category order and leave out the ones without
  /// items.
  case loaded(sections: [WidgetSection])
}

struct ChecklistEntry: TimelineEntry {
  let date: Date
  /// The configured list's name, or nil for all lists.
  let list: String?
  let state: ChecklistState
}

extension ChecklistEntry {
  /// The widget gallery's preview and the placeholder while loading.
  static let sample = ChecklistEntry(
    date: .now,
    list: nil,
    state: .loaded(
      sections: [
        WidgetSection(
          id: "c1",
          title: "Groceries",
          items: [
            WidgetItem(id: 1, title: "Oat milk", checked: false),
            WidgetItem(id: 2, title: "Sourdough loaf", checked: false),
            WidgetItem(id: 3, title: "Fresh basil", checked: false),
          ]
        ),
        WidgetSection(
          id: "c2",
          title: "Lisbon weekend",
          items: [
            WidgetItem(id: 4, title: "Book the train to Sintra", checked: false),
            WidgetItem(id: 5, title: "Pack the travel adapter", checked: false),
          ]
        ),
      ]
    )
  )
}
