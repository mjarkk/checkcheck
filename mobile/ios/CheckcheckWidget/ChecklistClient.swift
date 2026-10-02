import Foundation

struct Snapshot: Codable {
  struct Category: Codable {
    let id: Int
    let name: String
  }

  struct Item: Codable {
    let id: Int
    let title: String
    var checked: Bool
    let categoryID: Int?

    enum CodingKeys: String, CodingKey {
      case id, title, checked
      case categoryID = "category_id"
    }
  }

  /// The server the snapshot came from, so a reconnect to another server
  /// never shows the old one's list.
  let server: String
  let categories: [Category]
  /// Category ids with one nil for Uncategorized, as `/api/categories/order`.
  let order: [Int?]
  var items: [Item]
}

enum ClientError: Error {
  case notConnected
  case unauthorized
  case failed
}

/// The widget's own line to the server; the app's offline queue never sees
/// what it sends.
enum ChecklistClient {
  private static let defaults = UserDefaults(suiteName: WidgetConnection.appGroup)
  private static let snapshotKey = "snapshot"

  /// Saves what it loaded for `kept(for:)`.
  static func load(_ connection: WidgetConnection) async throws -> Snapshot {
    async let categories: [Snapshot.Category] = get("/api/categories", connection)
    async let order: OrderBody = get("/api/categories/order", connection)
    async let items: [Snapshot.Item] = get("/api/items", connection)
    let snapshot = try await Snapshot(
      server: connection.server,
      categories: categories,
      order: order.order,
      items: items
    )
    keep(snapshot)
    return snapshot
  }

  static func check(itemID: Int, _ connection: WidgetConnection) async throws {
    var patch = try request("/api/items/\(itemID)", connection)
    patch.httpMethod = "PATCH"
    patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
    patch.httpBody = try JSONEncoder().encode(["checked": true])
    _ = try await send(patch)
    if var snapshot = kept(for: connection),
      let index = snapshot.items.firstIndex(where: { $0.id == itemID })
    {
      snapshot.items[index].checked = true
      keep(snapshot)
    }
  }

  /// The last successful load from `connection`'s server.
  static func kept(for connection: WidgetConnection) -> Snapshot? {
    guard let data = defaults?.data(forKey: snapshotKey),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.server == connection.server
    else { return nil }
    return snapshot
  }

  private static func keep(_ snapshot: Snapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults?.set(data, forKey: snapshotKey)
  }

  private struct OrderBody: Decodable {
    let order: [Int?]
  }

  private static func get<T: Decodable>(_ path: String, _ connection: WidgetConnection)
    async throws -> T
  {
    let data = try await send(request(path, connection))
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      // A proxy's or captive portal's HTML page.
      throw ClientError.failed
    }
  }

  private static func request(_ path: String, _ connection: WidgetConnection) throws
    -> URLRequest
  {
    guard let url = URL(string: connection.server + path) else {
      throw ClientError.notConnected
    }
    // WidgetKit gives a reload only a few seconds more than this.
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private static func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw ClientError.failed
    }
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200..<300: return data
    case 401: throw ClientError.unauthorized
    default: throw ClientError.failed
    }
  }
}

/// Items ticked on the widget in the last few seconds, which the next
/// timeline shows checked in place before dropping them.
enum JustChecked {
  private static let defaults = UserDefaults(suiteName: WidgetConnection.appGroup)
  private static let key = "justChecked"
  private static let window: TimeInterval = 5

  static func mark(_ itemID: Int) {
    var marks = current()
    marks[String(itemID)] = Date.now.timeIntervalSince1970
    defaults?.set(marks, forKey: key)
  }

  static func recent() -> Set<Int> {
    let marks = current()
    defaults?.set(marks, forKey: key)
    return Set(marks.keys.compactMap(Int.init))
  }

  private static func current() -> [String: Double] {
    let since = Date.now.timeIntervalSince1970 - window
    let stored = defaults?.dictionary(forKey: key) as? [String: Double] ?? [:]
    return stored.filter { $0.value >= since }
  }
}
