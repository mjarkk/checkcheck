import AppIntents
import WidgetKit

struct SelectListIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "List"
  static let description = IntentDescription("Choose which list the widget shows.")

  @Parameter(title: "List") var list: ListEntity?
}

struct ListEntity: AppEntity {
  static let all = ListEntity(id: "all", name: "All lists")

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
  static let defaultQuery = ListQuery()

  /// `all`, or a section's id (see `WidgetSection.id`).
  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ListQuery: EntityQuery {
  // Never drops an id: the provider decides from fresh data whether the
  // list still exists.
  func entities(for identifiers: [String]) async throws -> [ListEntity] {
    let known = WidgetConnection.load()
      .flatMap(ChecklistClient.kept(for:))
      .map(Self.lists(in:)) ?? []
    return identifiers.map { id in
      known.first { $0.id == id } ?? ListEntity(id: id, name: "List")
    }
  }

  func suggestedEntities() async throws -> [ListEntity] {
    guard let connection = WidgetConnection.load() else { return [.all] }
    let snapshot =
      (try? await ChecklistClient.load(connection)) ?? ChecklistClient.kept(for: connection)
    return snapshot.map(Self.lists(in:)) ?? [.all]
  }

  func defaultResult() async -> ListEntity? { .all }

  private static func lists(in snapshot: Snapshot) -> [ListEntity] {
    // Without categories, Uncategorized is the whole list.
    guard !snapshot.categories.isEmpty else { return [.all] }
    return [.all]
      + arrange(snapshot).map {
        ListEntity(id: sectionID(of: $0), name: $0?.name ?? "Uncategorized")
      }
  }
}

struct CheckItemIntent: AppIntent {
  static let title: LocalizedStringResource = "Check off item"
  static let isDiscoverable = false

  @Parameter(title: "Item") var itemID: Int

  init() {}

  init(itemID: Int) {
    self.itemID = itemID
  }

  func perform() async throws -> some IntentResult {
    // A failed tick is dropped: the reload after this shows the row as it was.
    if let connection = WidgetConnection.load(),
      (try? await ChecklistClient.check(itemID: itemID, connection)) != nil
    {
      JustChecked.mark(itemID)
    }
    return .result()
  }
}
