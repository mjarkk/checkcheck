import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/api/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
    late StreamController<List<int>> body;
    late List<http.BaseRequest> opened;

    ApiClient streaming({
      int status = 200,
      Duration timeout = const Duration(seconds: 10),
    }) {
      body = StreamController();
      opened = [];
      return ApiClient(
        baseUrl: 'https://check.example.com',
        token: 's3cret',
        timeout: timeout,
        httpClient: MockClient.streaming((request, _) async {
          opened.add(request);
          if (status != 200) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{"error":"unauthorized"}')),
              status,
            );
          }
          return http.StreamedResponse(body.stream, 200);
        }),
      );
    }

    Future<void> abortOf(http.BaseRequest request) =>
        (request as http.Abortable).abortTrigger!;

    test('asks for the stream with the token', () async {
      final api = streaming();

      await api.events();

      final request = opened.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://check.example.com/api/events');
      expect(request.headers['Authorization'], 'Bearer s3cret');
      expect(request.headers['Accept'], 'text/event-stream');
    });

    test('yields preview events, however the bytes are split', () async {
      final api = streaming();
      final events = await api.events();
      final received = <PreviewEvent>[];
      final done = events.forEach(received.add);

      const text =
          ': ping\n\n'
          'event: preview\r\n'
          'data: {"link":"https://a.example","preview":\r\n'
          'data: {"title":"Ä","site_name":"A"}}\r\n'
          '\r\n'
          'event: other\n'
          'data: {"link":"https://b.example","preview":{"title":"B"}}\n'
          '\n'
          'data: {"link":"https://c.example","preview":{"title":"C"}}\n'
          '\n'
          'event: preview\n'
          'data: not json\n'
          '\n'
          'event:preview\n'
          'data:{"link":"https://d.example","preview":{"image":"https://d.example/i.png"}}\n'
          '\n'
          'event: preview\n'
          'data: {"link":"https://e.example","preview":{"title":"cut off"}}\n';
      final bytes = utf8.encode(text);
      for (var i = 0; i < bytes.length; i += 7) {
        body.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7));
        await pumpEventQueue();
      }
      await body.close();
      await done;

      expect(received, [
        (
          link: 'https://a.example',
          preview: const Preview(title: 'Ä', siteName: 'A'),
        ),
        (
          link: 'https://d.example',
          preview: const Preview(image: 'https://d.example/i.png'),
        ),
      ]);
    });

    test('a 401 is an UnauthorizedException', () {
      final api = streaming(status: 401);

      expect(api.events(), throwsA(isA<UnauthorizedException>()));
    });

    test('a lost connection fails the stream with NetworkException', () async {
      final api = streaming();
      final events = await api.events();

      body.addError(http.ClientException('Connection reset'));

      await expectLater(events, emitsError(isA<NetworkException>()));
    });

    // Cancelling the body is what makes IOClient close the socket.
    test('cancelling the stream stops reading the response', () async {
      final api = streaming();
      final subscription = (await api.events()).listen(null);
      var cancelled = false;
      body.onCancel = () => cancelled = true;

      await subscription.cancel();

      expect(cancelled, isTrue);
    });

    test('completing abort closes the connection', () async {
      final api = streaming();
      final abort = Completer<void>();
      await api.events(abort: abort.future);
      var aborted = false;
      abortOf(opened.single).then((_) => aborted = true);

      abort.complete();
      await pumpEventQueue();

      expect(aborted, isTrue);
    });

    test('only connecting has a timeout', () async {
      final slow = ApiClient(
        baseUrl: 'https://check.example.com',
        token: 't',
        timeout: const Duration(milliseconds: 10),
        httpClient: MockClient.streaming((_, _) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return http.StreamedResponse(const Stream.empty(), 200);
        }),
      );
      await expectLater(slow.events(), throwsA(isA<NetworkException>()));

      final api = streaming(timeout: const Duration(milliseconds: 10));
      final events = await api.events();
      final received = <PreviewEvent>[];
      events.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      body.add(
        utf8.encode(
          'event: preview\n'
          'data: {"link":"https://a.example","preview":{"title":"A"}}\n\n',
        ),
      );
      await pumpEventQueue();

      expect(received.single.link, 'https://a.example');
    });
  });
}
