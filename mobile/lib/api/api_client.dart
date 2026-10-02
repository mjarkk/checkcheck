import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// A link preview the server found, from `GET /api/events`.
typedef PreviewEvent = ({String link, Preview preview});

sealed class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class UnauthorizedException extends ApiException {
  const UnauthorizedException(super.message);
}

final class ConflictException extends ApiException {
  const ConflictException(super.message);
}

final class NetworkException extends ApiException {
  const NetworkException(super.message);
}

/// Any other non-2xx status, or a 2xx body that isn't the documented JSON
/// (then [statusCode] is the 2xx status).
final class ServerException extends ApiException {
  const ServerException(this.statusCode, String message, {this.fromApi = false})
    : super(message);

  final int statusCode;

  /// Whether checkcheck itself answered with its `{"error"}` JSON, rather
  /// than, say, a proxy standing in for a server that is down.
  final bool fromApi;
}

/// Client for the REST contract in /API.md.
///
/// Every call throws an [ApiException] on failure. [httpClient] is not closed
/// by this class.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.token,
    required http.Client httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _http = httpClient;

  /// Normalised: scheme included, no trailing slash.
  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client _http;

  /// False when something answered but isn't a checkcheck server; throws
  /// [NetworkException] when nothing answered.
  Future<bool> checkHealth() async {
    final response = await _send('GET', '/api/health', authorized: false);
    if (response.statusCode != 200) return false;
    try {
      return switch (_decode(response)) {
        {'status': 'ok'} => true,
        _ => false,
      };
    } on FormatException {
      return false;
    }
  }

  Future<List<Category>> listCategories() async =>
      _parseList(await _request('GET', '/api/categories'), Category.fromJson);

  Future<Category> createCategory(String name) async => _parse(
    await _request('POST', '/api/categories', body: {'name': name}),
    Category.fromJson,
  );

  Future<Category> renameCategory(int id, String name) async => _parse(
    await _request('PATCH', '/api/categories/$id', body: {'name': name}),
    Category.fromJson,
  );

  Future<void> deleteCategory(int id) =>
      _request('DELETE', '/api/categories/$id');

  /// Every category id once plus one null for Uncategorized.
  Future<List<int?>> categoryOrder() async =>
      _parseOrder(await _request('GET', '/api/categories/order'));

  /// A 400 means [order] doesn't list exactly the server's categories plus
  /// one null.
  Future<List<int?>> setCategoryOrder(List<int?> order) async => _parseOrder(
    await _request('PUT', '/api/categories/order', body: {'order': order}),
  );

  Future<List<Item>> listItems() async =>
      _parseList(await _request('GET', '/api/items'), Item.fromJson);

  Future<Item> createItem(String title, {int? categoryId}) async => _parse(
    await _request(
      'POST',
      '/api/items',
      body: {'title': title, 'category_id': categoryId},
    ),
    Item.fromJson,
  );

  /// Sends only the fields given; `category: (id: null)` removes the
  /// category, `before: (id: null)` moves the item to the end of the list
  /// order.
  Future<Item> updateItem(
    int id, {
    String? title,
    bool? checked,
    ({int? id})? category,
    ({int? id})? before,
  }) async => _parse(
    await _request(
      'PATCH',
      '/api/items/$id',
      body: {
        'title': ?title,
        'checked': ?checked,
        if (category != null) 'category_id': category.id,
        if (before != null) 'before_id': before.id,
      },
    ),
    Item.fromJson,
  );

  Future<void> deleteItem(int id) => _request('DELETE', '/api/items/$id');

  /// Most recently deleted first.
  Future<List<DeletedItem>> listDeletedItems() async => _parseList(
    await _request('GET', '/api/items/deleted'),
    DeletedItem.fromJson,
  );

  /// A 404 means item [id] isn't in Recently deleted (any more).
  Future<Item> restoreItem(int id) async =>
      _parse(await _request('POST', '/api/items/$id/restore'), Item.fromJson);

  /// Opens the server's event stream (/API.md "Link previews") and completes
  /// once the server has accepted it, within [timeout]. The stream then has
  /// no timeout: it ends, or fails with a [NetworkException], when the
  /// connection does. Cancelling it, or completing [abort], closes the
  /// connection.
  Future<Stream<PreviewEvent>> events({Future<void>? abort}) async {
    final closed = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      Uri.parse('$baseUrl/api/events'),
      abortTrigger: abort == null
          ? closed.future
          : Future.any([closed.future, abort]),
    );
    _authorize(request, accept: 'text/event-stream');
    final http.StreamedResponse response;
    try {
      response = await _transfer(() => _http.send(request));
    } on NetworkException {
      closed.complete();
      rethrow;
    }
    if (!_ok(response.statusCode)) {
      closed.complete();
      _throwFor(await _transfer(() => http.Response.fromStream(response)));
    }
    return _readEvents(response.stream, closed);
  }

  // Plain transforms: an async* generator only sees a cancel at its next
  // yield (a quiet stream would stay open), and a controller in between
  // delivered the body's done event late, so the model never reconnected.
  Stream<PreviewEvent> _readEvents(
    Stream<List<int>> body,
    Completer<void> closed,
  ) {
    void close() {
      if (!closed.isCompleted) closed.complete();
    }

    final parser = _EventParser();
    return body
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .transform(
          StreamTransformer<String, PreviewEvent>.fromHandlers(
            handleData: (line, sink) {
              if (parser.add(line) case final event?) sink.add(event);
            },
            handleError: (_, _, sink) {
              close();
              sink
                ..addError(
                  const NetworkException('Lost the connection to the server'),
                )
                ..close();
            },
            handleDone: (sink) {
              close();
              sink.close();
            },
          ),
        );
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
  }) async {
    final response = await _send(method, path, body: body);
    if (!_ok(response.statusCode)) _throwFor(response);
    return response;
  }

  bool _ok(int status) => status >= 200 && status < 300;

  Never _throwFor(http.Response response) {
    final status = response.statusCode;
    final error = _apiError(response);
    final message = error ?? 'Server error ($status)';
    throw switch (status) {
      401 => UnauthorizedException(message),
      409 => ConflictException(message),
      _ => ServerException(status, message, fromApi: error != null),
    };
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    bool authorized = true,
  }) {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    if (authorized) {
      _authorize(request);
    } else {
      request.headers['Accept'] = 'application/json';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _transfer(() => _http.send(request).then(http.Response.fromStream));
  }

  void _authorize(
    http.BaseRequest request, {
    String accept = 'application/json',
  }) {
    request.headers['Accept'] = accept;
    request.headers['Authorization'] = 'Bearer $token';
  }

  Future<T> _transfer<T>(Future<T> Function() transfer) async {
    try {
      return await transfer().timeout(timeout);
    } on TimeoutException {
      throw const NetworkException('The server took too long to respond');
    } on Exception {
      // Not just http.ClientException: TLS failures (e.g. https:// against a
      // plain-HTTP server) surface as dart:io HandshakeException.
      throw const NetworkException("Can't reach the server");
    }
  }

  // Not response.body: package:http decodes that as Latin-1 when the
  // Content-Type has no charset, which mangles non-ASCII titles.
  Object? _decode(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes));

  String? _apiError(http.Response response) {
    try {
      if (_decode(response) case {'error': final String error}) return error;
    } on FormatException {
      // Fall through: proxies and non-checkcheck servers answer with HTML.
    }
    return null;
  }

  T _parse<T>(
    http.Response response,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    try {
      return fromJson(_decode(response) as Map<String, dynamic>);
    } on FormatException {
      throw _unexpected(response);
    } on TypeError {
      throw _unexpected(response);
    }
  }

  List<T> _parseList<T>(
    http.Response response,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    try {
      return [
        for (final entry in _decode(response) as List)
          fromJson(entry as Map<String, dynamic>),
      ];
    } on FormatException {
      throw _unexpected(response);
    } on TypeError {
      throw _unexpected(response);
    }
  }

  List<int?> _parseOrder(http.Response response) {
    try {
      if (_decode(response) case {'order': final List order}) {
        return [for (final id in order) id as int?];
      }
    } on FormatException {
      throw _unexpected(response);
    } on TypeError {
      throw _unexpected(response);
    }
    throw _unexpected(response);
  }

  ServerException _unexpected(http.Response response) => ServerException(
    response.statusCode,
    'Unexpected response from the server',
  );
}

/// Server-Sent Events, `event:` and `data:` fields only.
class _EventParser {
  var _type = '';
  final _data = <String>[];

  /// The preview event that [line] completes, if any.
  PreviewEvent? add(String line) {
    if (line.isEmpty) {
      final event = _type == 'preview' && _data.isNotEmpty
          ? _previewEvent(_data.join('\n'))
          : null;
      _type = '';
      _data.clear();
      return event;
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _type = value;
      case 'data':
        _data.add(value);
    }
    return null;
  }

  static PreviewEvent? _previewEvent(String data) {
    try {
      if (jsonDecode(data) case {
        'link': final String link,
        'preview': final Map<String, dynamic> preview,
      }) {
        return (link: link, preview: Preview.fromJson(preview));
      }
    } on FormatException {
      // Skipped like any event this client doesn't know.
    } on TypeError {
      // Likewise.
    }
    return null;
  }
}
