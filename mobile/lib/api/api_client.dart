import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

final _random = Random.secure();

/// 128 random bits in hex, for an `Idempotency-Key` or a client id.
String randomKey() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// What [ApiClient.events] passes on from `GET /api/events` (/API.md "Live
/// updates"). Pings only keep the connection alive and aren't passed on.
sealed class ServerEvent {
  const ServerEvent();
}

/// Subscribed: every event from now on arrives, but nothing from before.
final class ReadyEvent extends ServerEvent {
  const ReadyEvent();
}

/// Something a list endpoint returns was changed by another client or MCP;
/// the event says no more than that.
final class ChangedEvent extends ServerEvent {
  const ChangedEvent();
}

/// A link preview the server found.
final class PreviewEvent extends ServerEvent {
  const PreviewEvent({required this.link, required this.preview});

  final String link;
  final Preview preview;
}

/// Opens a WebSocket; [WebSocketChannel.connect] outside tests.
typedef WebSocketConnect = WebSocketChannel Function(Uri url);

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

  /// Whether CheckCheck itself answered with its `{"error"}` JSON, rather
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
    WebSocketConnect? connectWebSocket,
  }) : _http = httpClient,
       _connectWebSocket = connectWebSocket ?? WebSocketChannel.connect;

  /// Normalised: scheme included, no trailing slash.
  final String baseUrl;
  final String token;
  final Duration timeout;

  /// Sent as `X-Checkcheck-Client`, so this client can skip the `changed`
  /// events its own requests caused.
  final String clientId = randomKey();

  final http.Client _http;
  final WebSocketConnect _connectWebSocket;

  /// False when something answered but isn't a CheckCheck server; throws
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

  /// [key] is the create's `Idempotency-Key`, so resending it can't make a
  /// second one.
  Future<Category> createCategory(String name, {String? key}) async => _parse(
    await _request(
      'POST',
      '/api/categories',
      body: {'name': name},
      idempotencyKey: key,
    ),
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

  /// [key] is the create's `Idempotency-Key`, so resending it can't make a
  /// second one.
  Future<Item> createItem(String title, {int? categoryId, String? key}) async =>
      _parse(
        await _request(
          'POST',
          '/api/items',
          body: {'title': title, 'category_id': categoryId},
          idempotencyKey: key,
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

  /// Follows the server's live updates (/API.md "Live updates"): listening
  /// opens the WebSocket and signs in, cancelling closes it. Opening has
  /// [timeout]. The stream ends with an error: [UnauthorizedException] when
  /// the server rejects the token, otherwise [NetworkException], also after
  /// 40 s without a message (the server pings every 15 s). `changed` events
  /// that this client's own requests caused are left out, as it already has
  /// their responses.
  Stream<ServerEvent> events() {
    late final StreamController<ServerEvent> events;
    WebSocketChannel? socket;
    StreamSubscription<Object?>? messages;

    // Opening's timeout, then the silence one.
    Timer? deadline;

    void end([ApiException? error]) {
      if (events.isClosed) return;
      deadline?.cancel();
      messages?.cancel();
      socket?.sink.close().ignore();
      if (error != null) events.addError(error);
      events.close().ignore();
    }

    void heard() {
      deadline?.cancel();
      deadline = Timer(
        const Duration(seconds: 40),
        () => end(const NetworkException('The server stopped answering')),
      );
    }

    Future<void> open() async {
      deadline = Timer(
        timeout,
        () =>
            end(const NetworkException('The server took too long to respond')),
      );
      final WebSocketChannel channel;
      try {
        channel = socket = _connectWebSocket(_eventsUrl());
        await channel.ready;
      } on Exception {
        end(const NetworkException("Can't reach the server"));
        return;
      }
      if (events.isClosed) return;
      heard();
      messages = channel.stream.listen(
        (message) {
          heard();
          if (_event(message) case final event?) events.add(event);
        },
        onError: (Object _) =>
            end(const NetworkException('Lost the connection to the server')),
        onDone: () => end(
          channel.closeCode == 4401
              ? const UnauthorizedException('Token rejected')
              : const NetworkException('Lost the connection to the server'),
        ),
      );
      channel.sink.add(
        jsonEncode({'type': 'auth', 'token': token, 'client': clientId}),
      );
    }

    events = StreamController(onListen: open, onCancel: end);
    return events.stream;
  }

  Uri _eventsUrl() {
    final url = Uri.parse('$baseUrl/api/events');
    return url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws');
  }

  /// Null for pings, for what this client doesn't know, and for its own
  /// changes.
  ServerEvent? _event(Object? message) {
    if (message is! String) return null;
    try {
      return switch (jsonDecode(message)) {
        {'type': 'ready'} => const ReadyEvent(),
        {'type': 'changed', 'client': final String client}
            when client == clientId =>
          null,
        {'type': 'changed'} => const ChangedEvent(),
        {
          'type': 'preview',
          'link': final String link,
          'preview': final Map<String, dynamic> preview,
        } =>
          PreviewEvent(link: link, preview: Preview.fromJson(preview)),
        _ => null,
      };
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
    String? idempotencyKey,
  }) async {
    final response = await _send(
      method,
      path,
      body: body,
      idempotencyKey: idempotencyKey,
    );
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
    String? idempotencyKey,
  }) {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers['Accept'] = 'application/json';
    request.headers['X-Checkcheck-Client'] = clientId;
    if (authorized) request.headers['Authorization'] = 'Bearer $token';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _transfer(() => _http.send(request).then(http.Response.fromStream));
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
      // Fall through: proxies and non-CheckCheck servers answer with HTML.
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
