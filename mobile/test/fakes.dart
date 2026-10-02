import 'dart:async';
import 'dart:convert';

import 'package:checkcheck/api/link.dart';
import 'package:checkcheck/settings.dart';
import 'package:checkcheck/state/checklist_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory implementation of the /API.md contract.
class FakeServer {
  FakeServer({this.token = 'dev'});

  final String token;

  /// In creation order; the API lists them in [categoryOrder].
  final categories = <Map<String, Object?>>[];

  /// In list order. Responses add `link` (from the title) and `preview`
  /// (from [previews]).
  final items = <Map<String, Object?>>[];

  /// Recently deleted, most recently deleted first, each with `deleted_at`
  /// and without `category_id`.
  final deleted = <Map<String, Object?>>[];
  final requests = <http.Request>[];

  /// Every category id once plus one null for Uncategorized. Ids of
  /// categories removed from [categories] directly are skipped, and
  /// categories added to it directly are placed like new ones.
  List<int?> categoryOrder = [null];

  /// What the server found per link.
  final previews = <String, Map<String, Object?>>{};

  /// When set, the next authorized request answers with this status. Not
  /// `GET /api/events`, which a following model opens at any time.
  int? failNextWith;

  /// While set, requests it gives a status for answer with that status,
  /// like [failNextWith].
  int? Function(http.Request request)? failWhen;

  /// While set, `GET /api/events` answers with this status.
  int? failEventsWith;

  /// While true, requests fail as if the network were down. Open event
  /// streams stay open until [closeEvents].
  bool offline = false;

  /// While set, requests wait for it before they are handled; not
  /// `GET /api/events`.
  Completer<void>? gate;

  late final http.Client client = MockClient.streaming(_receive);

  var _nextId = 1;
  final _epoch = DateTime.utc(2026, 10, 1, 12);
  final _eventStreams = <StreamController<List<int>>>{};

  /// How many event streams are open.
  int get eventClients => _eventStreams.length;

  Map<String, Object?> addCategory(String name) {
    final order = _order();
    final category = {'id': _nextId, 'name': name, ..._timestamps()};
    categories.add(category);
    categoryOrder = _placed(order, category['id'] as int);
    return category;
  }

  Map<String, Object?> addItem(
    String title, {
    int? categoryId,
    bool checked = false,
  }) {
    final item = {
      'id': _nextId,
      'title': title,
      'checked': checked,
      'category_id': categoryId,
      ..._timestamps(),
    };
    items.add(item);
    return item;
  }

  /// Adds an item straight to Recently deleted, deleted at [deletedAt]
  /// (now by default), after the entries deleted no later.
  Map<String, Object?> addDeleted(
    String title, {
    bool checked = false,
    DateTime? deletedAt,
  }) {
    final item = {
      'id': _nextId,
      'title': title,
      'checked': checked,
      ..._timestamps(),
      'deleted_at': (deletedAt ?? _now()).toUtc().toIso8601String(),
    };
    _insertDeleted(item);
    return item;
  }

  // Whole seconds, like the real server.
  DateTime _now() {
    final now = DateTime.now().toUtc();
    return now.subtract(
      Duration(milliseconds: now.millisecond, microseconds: now.microsecond),
    );
  }

  void _insertDeleted(Map<String, Object?> item) {
    final at = DateTime.parse(item['deleted_at'] as String);
    final index = deleted.indexWhere(
      (d) => DateTime.parse(d['deleted_at'] as String).isBefore(at),
    );
    deleted.insert(index < 0 ? deleted.length : index, item);
  }

  /// Stores [preview] for [link] and sends it to every open event stream.
  void pushPreview(String link, Map<String, Object?> preview) {
    previews[link] = preview;
    sendEvent(
      'event: preview\n'
      'data: ${jsonEncode({'link': link, 'preview': preview})}\n\n',
    );
  }

  /// Writes [text] as is to every open event stream.
  void sendEvent(String text) {
    for (final stream in _eventStreams) {
      stream.add(utf8.encode(text));
    }
  }

  /// Ends every open event stream, as a restarting server would.
  void closeEvents() {
    final streams = [..._eventStreams];
    _eventStreams.clear();
    for (final stream in streams) {
      stream.close();
    }
  }

  Map<String, String> _timestamps() {
    final at = _epoch.add(Duration(seconds: _nextId++)).toIso8601String();
    return {'created_at': at, 'updated_at': at};
  }

  /// [categoryOrder] fitted to [categories].
  List<int?> _order() {
    final unlisted = [for (final c in categories) c['id'] as int];
    var order = <int?>[];
    var uncategorized = false;
    for (final id in categoryOrder) {
      if (id == null ? !uncategorized : unlisted.remove(id)) order.add(id);
      uncategorized |= id == null;
    }
    if (!uncategorized) order.add(null);
    for (final id in unlisted) {
      order = _placed(order, id);
    }
    return categoryOrder = order;
  }

  // Directly before Uncategorized when that is last, otherwise at the end.
  List<int?> _placed(List<int?> order, int id) =>
      [...order]
        ..insert(order.last == null ? order.length - 1 : order.length, id);

  Map<String, Object?> _itemJson(Map<String, Object?> item) {
    final link = findLink(item['title'] as String);
    return {...item, 'link': link, 'preview': previews[link]};
  }

  Future<http.StreamedResponse> _receive(
    http.BaseRequest base,
    http.ByteStream body,
  ) async {
    // Read first, like MockClient's non-streaming handler: tests that go
    // offline right after a change rely on that change still getting
    // through.
    final bytes = await body.toBytes();
    if (offline) throw http.ClientException('offline');
    final request = http.Request(base.method, base.url)
      ..headers.addAll(base.headers)
      ..bodyBytes = bytes;
    requests.add(request);
    if (request.url.path == '/api/events') return _events(base);
    final response = await _handle(request);
    return http.StreamedResponse(
      http.ByteStream.fromBytes(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  http.StreamedResponse _events(http.BaseRequest request) {
    final status = request.headers['Authorization'] != 'Bearer $token'
        ? 401
        : failEventsWith;
    if (status != null) {
      final error = _json(status, {'error': 'failure $status'});
      return http.StreamedResponse(
        http.ByteStream.fromBytes(error.bodyBytes),
        status,
        headers: error.headers,
      );
    }
    final stream = StreamController<List<int>>();
    stream.onCancel = () => _eventStreams.remove(stream);
    _eventStreams.add(stream);
    // MockClient leaves aborting to the handler; IOClient does it like this.
    if (request case http.Abortable(:final abortTrigger?)) {
      abortTrigger.whenComplete(() {
        if (!_eventStreams.remove(stream)) return;
        stream
          ..addError(http.RequestAbortedException(request.url))
          ..close();
      });
    }
    return http.StreamedResponse(
      stream.stream,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  Future<http.Response> _handle(http.Request request) async {
    if (gate case final gate?) await gate.future;
    final segments = request.url.pathSegments;
    if (request.url.path == '/api/health') return _json(200, {'status': 'ok'});
    if (request.headers['Authorization'] != 'Bearer $token') {
      return _json(401, {'error': 'unauthorized'});
    }
    if (failNextWith case final status?) {
      failNextWith = null;
      return _json(status, {'error': 'failure $status'});
    }
    if (failWhen?.call(request) case final status?) {
      return _json(status, {'error': 'failure $status'});
    }
    final body = request.body.isEmpty ? null : jsonDecode(request.body) as Map;
    if (request.url.path == '/api/categories/order') {
      return _categoryOrder(request.method, body);
    }
    if ((request.method, segments) case ('GET', ['api', 'items', 'deleted'])) {
      final cutoff = _now().subtract(const Duration(days: 30));
      return _json(200, [
        for (final item in deleted)
          if (!DateTime.parse(item['deleted_at'] as String).isBefore(cutoff))
            item,
      ]);
    }
    if ((request.method, segments) case (
      'POST',
      ['api', 'items', final id, 'restore'],
    )) {
      return _restore(int.parse(id));
    }
    final id = segments.length > 2 ? int.parse(segments[2]) : null;
    final resource = segments[1];
    final list = resource == 'categories' ? categories : items;
    if (resource == 'items' &&
        body != null &&
        body['before_id'] != null &&
        body['before_id'] == id) {
      return _json(400, {'error': 'an item cannot be moved before itself'});
    }
    final existing = id == null
        ? null
        : list.where((entry) => entry['id'] == id).firstOrNull;
    if (id != null && existing == null) {
      return _json(404, {'error': 'not found'});
    }
    if (resource == 'items' &&
        body != null &&
        body['category_id'] != null &&
        !categories.any((c) => c['id'] == body['category_id'])) {
      return _json(400, {'error': 'category does not exist'});
    }
    if (resource == 'items' &&
        body != null &&
        body['before_id'] != null &&
        !items.any((i) => i['id'] == body['before_id'])) {
      return _json(400, {'error': 'item does not exist'});
    }

    switch ((request.method, resource, id)) {
      case ('GET', 'categories', null):
        final byId = {for (final c in categories) c['id']: c};
        return _json(200, [for (final id in _order()) ?byId[id]]);
      case ('POST', 'categories', null):
        final name = body!['name'] as String;
        if (categories.any(
          (c) => (c['name'] as String).toLowerCase() == name.toLowerCase(),
        )) {
          return _json(409, {'error': 'category already exists'});
        }
        return _json(201, addCategory(name));
      case ('PATCH', 'categories', _):
        existing!['name'] = body!['name'];
        return _json(200, existing);
      case ('DELETE', 'categories', _):
        categories.remove(existing);
        for (final item in items) {
          if (item['category_id'] == id) item['category_id'] = null;
        }
        return http.Response('', 204);
      case ('GET', 'items', null):
        return _json(200, [for (final item in items) _itemJson(item)]);
      case ('POST', 'items', null):
        final item = addItem(
          body!['title'] as String,
          categoryId: body['category_id'] as int?,
        );
        return _json(201, _itemJson(item));
      case ('PATCH', 'items', _):
        for (final key in ['title', 'checked', 'category_id']) {
          if (body!.containsKey(key)) existing![key] = body[key];
        }
        if (body!.containsKey('before_id')) {
          items.remove(existing);
          final at = items.indexWhere((i) => i['id'] == body['before_id']);
          items.insert(at < 0 ? items.length : at, existing!);
        }
        return _json(200, _itemJson(existing!));
      case ('DELETE', 'items', _):
        items.remove(existing);
        _insertDeleted({
          for (final MapEntry(:key, :value) in existing!.entries)
            if (key != 'category_id') key: value,
          'deleted_at': _now().toIso8601String(),
        });
        return http.Response('', 204);
    }
    return _json(404, {'error': 'no route'});
  }

  http.Response _restore(int id) {
    final entry = deleted.where((d) => d['id'] == id).firstOrNull;
    if (entry == null) return _json(404, {'error': 'not found'});
    deleted.remove(entry);
    final item = {
      for (final MapEntry(:key, :value) in entry.entries)
        if (key != 'deleted_at') key: value,
      'category_id': null,
    };
    items.add(item);
    return _json(200, _itemJson(item));
  }

  http.Response _categoryOrder(String method, Map? body) {
    if (method == 'GET') return _json(200, {'order': _order()});
    final order = (body!['order'] as List).cast<int?>();
    final ids = {for (final c in categories) c['id']};
    final valid =
        order.where((id) => id == null).length == 1 &&
        order.nonNulls.toSet().length == order.length - 1 &&
        order.nonNulls.every(ids.contains) &&
        order.length == ids.length + 1;
    if (!valid) {
      return _json(400, {
        'error':
            'order must list every category id once plus one null for '
            'Uncategorized',
      });
    }
    categoryOrder = [...order];
    return _json(200, {'order': order});
  }

  // UTF-8 bytes without a charset parameter, like the Go server sends.
  http.Response _json(int status, Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );
}

class FakeSettingsStore implements SettingsStore {
  FakeSettingsStore({this.url, this.token});

  String? url;
  String? token;

  @override
  Future<({String? url, String? token})> load() async =>
      (url: url, token: token);

  @override
  Future<void> save(ServerSettings settings) async {
    url = settings.url;
    token = settings.token;
  }

  @override
  Future<void> clearToken() async => token = null;
}

class MemoryChecklistCache implements ChecklistCache {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String data) async => this.data = data;

  @override
  Future<void> clear() async => data = null;
}
