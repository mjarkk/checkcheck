import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException;

import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/api/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart' as ws;
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

void main() {
  late List<http.Request> requests;

  ApiClient client(
    http.Response Function(http.Request request) respond, {
    String baseUrl = 'https://check.example.com',
  }) {
    requests = [];
    return ApiClient(
      baseUrl: baseUrl,
      token: 's3cret',
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
  }

  http.Response json(int status, Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );

  const item = {
    'id': 7,
    'title': 'Milk',
    'checked': false,
    'category_id': 1,
    'created_at': '2026-10-01T15:04:05Z',
    'updated_at': '2026-10-01T15:04:06.123456789Z',
  };

  test('sends the bearer token and parses categories', () async {
    final api = client(
      (_) => json(200, [
        {
          'id': 1,
          'name': 'Groceries',
          'created_at': '2026-10-01T15:04:05Z',
          'updated_at': '2026-10-01T15:04:05Z',
        },
      ]),
    );

    final categories = await api.listCategories();

    expect(requests.single.method, 'GET');
    expect(
      requests.single.url.toString(),
      'https://check.example.com/api/categories',
    );
    expect(requests.single.headers['Authorization'], 'Bearer s3cret');
    expect(categories.single.id, 1);
    expect(categories.single.name, 'Groceries');
    expect(categories.single.createdAt, DateTime.utc(2026, 10, 1, 15, 4, 5));
  });

  test('parses items, including a null category_id', () async {
    final api = client(
      (_) => json(200, [
        item,
        {...item, 'id': 8, 'checked': true, 'category_id': null},
      ]),
    );

    final items = await api.listItems();

    expect(items.map((i) => i.id), [7, 8]);
    expect(items[0].categoryId, 1);
    expect(items[1].categoryId, isNull);
    expect(items[1].checked, isTrue);
    expect(items[0].updatedAt.toUtc().microsecond, 456);
  });

  test('decodes UTF-8 even without a charset in Content-Type', () async {
    final api = client(
      (_) => json(200, [
        {...item, 'title': 'Crème brûlée'},
      ]),
    );

    expect((await api.listItems()).single.title, 'Crème brûlée');
  });

  test('keeps a path prefix in the base URL', () async {
    final api = client(
      (_) => json(200, []),
      baseUrl: 'https://example.com/checkcheck',
    );

    await api.listItems();

    expect(requests.single.url.path, '/checkcheck/api/items');
  });

  test('createItem posts JSON with the category', () async {
    final api = client((_) => json(201, item));

    await api.createItem('Milk', categoryId: 1);

    expect(requests.single.method, 'POST');
    expect(
      requests.single.headers['Content-Type'],
      startsWith('application/json'),
    );
    expect(jsonDecode(requests.single.body), {
      'title': 'Milk',
      'category_id': 1,
    });
  });

  test('creates send their Idempotency-Key, and none without one', () async {
    final api = client(
      (request) => request.url.path == '/api/items'
          ? json(201, item)
          : json(201, {
              'id': 1,
              'name': 'Groceries',
              'created_at': '2026-10-01T15:04:05Z',
              'updated_at': '2026-10-01T15:04:05Z',
            }),
    );

    await api.createItem('Milk', key: 'item-key');
    await api.createCategory('Groceries', key: 'category-key');
    await api.createItem('Milk');
    await api.createCategory('Groceries');

    expect(
      [for (final r in requests) r.headers['Idempotency-Key']],
      ['item-key', 'category-key', null, null],
    );
  });

  test('every request carries the client id, which is per client', () async {
    final api = client(
      (request) => request.url.path == '/api/health'
          ? json(200, {'status': 'ok'})
          : json(200, []),
    );

    await api.checkHealth();
    await api.listItems();
    await api.listCategories();

    expect(api.clientId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect([
      for (final r in requests) r.headers['X-Checkcheck-Client'],
    ], everyElement(api.clientId));
    expect(client((_) => json(200, [])).clientId, isNot(api.clientId));
  });

  test('updateItem sends an explicit null category_id to clear it', () async {
    final api = client((_) => json(200, {...item, 'category_id': null}));

    final updated = await api.updateItem(7, category: (id: null));

    expect(requests.single.method, 'PATCH');
    expect(requests.single.url.path, '/api/items/7');
    expect(jsonDecode(requests.single.body), {'category_id': null});
    expect(updated.categoryId, isNull);
  });

  test('updateItem sends only the fields given', () async {
    final api = client((_) => json(200, {...item, 'checked': true}));

    await api.updateItem(7, checked: true);

    expect(jsonDecode(requests.single.body), {'checked': true});
  });

  test('updateItem sends before_id, null for the end', () async {
    final api = client((_) => json(200, item));

    await api.updateItem(7, before: (id: 3));
    await api.updateItem(7, checked: true, before: (id: null));

    expect(requests.map((r) => jsonDecode(r.body)), [
      {'before_id': 3},
      {'checked': true, 'before_id': null},
    ]);
  });

  test('parses the link and preview of an item', () async {
    final api = client(
      (_) => json(200, {
        ...item,
        'title': 'Read https://example.com/post',
        'link': 'https://example.com/post',
        'preview': {'title': 'A post', 'site_name': 'Example'},
      }),
    );

    final updated = await api.updateItem(7, title: 'Read');

    expect(updated.link, 'https://example.com/post');
    expect(
      updated.preview,
      const Preview(title: 'A post', siteName: 'Example'),
    );
  });

  test('categoryOrder reads the order with its null', () async {
    final api = client(
      (_) => json(200, {
        'order': [3, null, 1],
      }),
    );

    expect(await api.categoryOrder(), [3, null, 1]);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/categories/order');
  });

  test('setCategoryOrder puts the order and returns the saved one', () async {
    final api = client(
      (request) => json(200, jsonDecode(request.body) as Object),
    );

    expect(await api.setCategoryOrder([null, 2]), [null, 2]);
    expect(requests.single.method, 'PUT');
    expect(requests.single.url.path, '/api/categories/order');
    expect(jsonDecode(requests.single.body), {
      'order': [null, 2],
    });
  });

  test('an order of the wrong shape is a ServerException', () {
    final api = client((_) => json(200, {'order': 'no'}));

    expect(api.categoryOrder(), throwsA(isA<ServerException>()));
  });

  test('delete endpoints accept 204', () async {
    final api = client((_) => http.Response('', 204));

    await api.deleteItem(7);
    await api.deleteCategory(1);
  });

  test('maps 401 to UnauthorizedException', () {
    final api = client((_) => json(401, {'error': 'unauthorized'}));

    expect(api.listItems(), throwsA(isA<UnauthorizedException>()));
  });

  test('maps 409 to ConflictException', () {
    final api = client((_) => json(409, {'error': 'category exists'}));

    expect(api.createCategory('Groceries'), throwsA(isA<ConflictException>()));
  });

  test('maps other errors to ServerException with the server message', () {
    final api = client((_) => json(400, {'error': 'title is required'}));

    expect(
      api.createItem(''),
      throwsA(
        isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'title is required')
            .having((e) => e.fromApi, 'fromApi', isTrue),
      ),
    );
  });

  test('an error page from something else is not fromApi', () {
    final api = client((_) => http.Response('404 page not found', 404));

    expect(
      api.deleteItem(7),
      throwsA(
        isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.fromApi, 'fromApi', isFalse),
      ),
    );
  });

  test('a 2xx body of the wrong shape is a ServerException', () {
    final api = client((_) => http.Response('<html></html>', 200));

    expect(api.listItems(), throwsA(isA<ServerException>()));
  });

  test('transport failures become NetworkException', () {
    final api = ApiClient(
      baseUrl: 'https://check.example.com',
      token: 't',
      httpClient: MockClient(
        (_) => throw const HandshakeException('wrong version number'),
      ),
    );

    expect(api.listItems(), throwsA(isA<NetworkException>()));
  });

  test('a slow server becomes NetworkException after the timeout', () {
    final api = ApiClient(
      baseUrl: 'https://check.example.com',
      token: 't',
      timeout: const Duration(milliseconds: 10),
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response('[]', 200);
      }),
    );

    expect(api.listItems(), throwsA(isA<NetworkException>()));
  });

  group('checkHealth', () {
    test('is true for {"status":"ok"} and sends no token', () async {
      final api = client((_) => json(200, {'status': 'ok'}));

      expect(await api.checkHealth(), isTrue);
      expect(requests.single.url.path, '/api/health');
      expect(requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('is false for other servers', () async {
      expect(
        await client((_) => http.Response('<html>', 200)).checkHealth(),
        isFalse,
      );
      expect(
        await client((_) => json(200, {'ok': true})).checkHealth(),
        isFalse,
      );
      expect(
        await client((_) => http.Response('', 404)).checkHealth(),
        isFalse,
      );
    });
  });

  group('events', () {
    late List<Uri> opened;
    late List<Object?> signIns;
    late ws.WebSocket server;
    late bool closedByClient;

    ApiClient api({
      String baseUrl = 'https://check.example.com',
      Future<ws.WebSocket>? connecting,
    }) => ApiClient(
      baseUrl: baseUrl,
      token: 's3cret',
      httpClient: MockClient((_) async => http.Response('', 404)),
      connectWebSocket: (url) {
        opened.add(url);
        if (connecting != null) return AdapterWebSocketChannel(connecting);
        final (client, peer) = fakes();
        server = peer;
        peer.events.listen((event) {
          switch (event) {
            case ws.TextDataReceived(:final text):
              signIns.add(jsonDecode(text));
            case ws.CloseReceived():
              closedByClient = true;
            case ws.BinaryDataReceived():
          }
        });
        return AdapterWebSocketChannel(client);
      },
    );

    void send(Object message) => server.sendText(jsonEncode(message));

    setUp(() {
      opened = [];
      signIns = [];
      closedByClient = false;
    });

    test('opens wss:// and signs in with the token and client id', () async {
      final client = api();
      final subscription = client.events().listen(null);
      await pumpEventQueue();

      expect(opened.single.toString(), 'wss://check.example.com/api/events');
      expect(signIns, [
        {'type': 'auth', 'token': 's3cret', 'client': client.clientId},
      ]);
      await subscription.cancel();
    });

    test('opens ws:// for http and keeps a path prefix', () async {
      final subscription = api(
        baseUrl: 'http://192.168.1.5:8181/checkcheck',
      ).events().listen(null);
      await pumpEventQueue();

      expect(
        opened.single.toString(),
        'ws://192.168.1.5:8181/checkcheck/api/events',
      );
      await subscription.cancel();
    });

    test('passes on ready, changed and preview; skips pings, its own '
        'changes and what it does not know', () async {
      final client = api();
      final seen = <ServerEvent>[];
      final subscription = client.events().listen(seen.add);
      await pumpEventQueue();

      send({'type': 'ready'});
      send({'type': 'ping'});
      send({'type': 'changed', 'client': client.clientId});
      send({'type': 'changed', 'client': 'another client'});
      send({'type': 'changed'});
      send({
        'type': 'preview',
        'link': 'https://a.example',
        'preview': {'title': 'Ä', 'site_name': 'A'},
      });
      send({'type': 'preview', 'link': 'https://b.example'});
      send({'type': 'something new'});
      server.sendText('not json');
      await pumpEventQueue();

      expect(seen, [
        isA<ReadyEvent>(),
        isA<ChangedEvent>(),
        isA<ChangedEvent>(),
        isA<PreviewEvent>()
            .having((e) => e.link, 'link', 'https://a.example')
            .having(
              (e) => e.preview,
              'preview',
              const Preview(title: 'Ä', siteName: 'A'),
            ),
      ]);
      await subscription.cancel();
    });

    test(
      'close code 4401 ends the stream with UnauthorizedException',
      () async {
        final events = api().events();
        final ended = expectLater(
          events,
          emitsInOrder([emitsError(isA<UnauthorizedException>()), emitsDone]),
        );
        await pumpEventQueue();

        await server.close(4401, 'unauthorized');

        await ended;
      },
    );

    test('any other close ends it with NetworkException', () async {
      final events = api().events();
      final ended = expectLater(
        events,
        emitsInOrder([
          isA<ReadyEvent>(),
          emitsError(isA<NetworkException>()),
          emitsDone,
        ]),
      );
      await pumpEventQueue();
      send({'type': 'ready'});

      await server.close(4000);

      await ended;
    });

    test('a connection that fails is a NetworkException', () async {
      await expectLater(
        api(
          connecting: Future.error(ws.WebSocketException('refused')),
        ).events(),
        emitsInOrder([emitsError(isA<NetworkException>()), emitsDone]),
      );
    });

    test('cancelling closes the socket', () async {
      final subscription = api().events().listen(null);
      await pumpEventQueue();

      await subscription.cancel();
      await pumpEventQueue();

      expect(closedByClient, isTrue);
    });

    testWidgets('opening gives up after the timeout', (tester) async {
      final errors = <Object>[];
      api(
        connecting: Completer<ws.WebSocket>().future,
      ).events().listen(null, onError: errors.add);

      await tester.pump(const Duration(seconds: 9));
      expect(errors, isEmpty);
      await tester.pump(const Duration(seconds: 1));

      expect(errors.single, isA<NetworkException>());
    });

    testWidgets('40 s without a message closes the socket with '
        'NetworkException; a message restarts the wait', (tester) async {
      final errors = <Object>[];
      var done = false;
      api().events().listen(
        null,
        onError: errors.add,
        onDone: () => done = true,
      );
      await tester.pump();

      await tester.pump(const Duration(seconds: 30));
      send({'type': 'ping'});
      await tester.pump(const Duration(seconds: 39));
      expect(done, isFalse);
      expect(closedByClient, isFalse);
      await tester.pump(const Duration(seconds: 1));

      expect(errors.single, isA<NetworkException>());
      expect(done, isTrue);
      expect(closedByClient, isTrue);
    });
  });
}
