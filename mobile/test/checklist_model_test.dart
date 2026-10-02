import 'dart:async';
import 'dart:convert';

import 'package:checkcheck/api/api_client.dart';
import 'package:checkcheck/api/models.dart';
import 'package:checkcheck/state/checklist_model.dart';
import 'package:checkcheck/state/sections.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _link = 'https://example.com/post';

void main() {
  late FakeServer server;
  late MemoryChecklistCache cache;
  late ChecklistModel model;
  late int unauthorizedCalls;
  final models = <ChecklistModel>[];

  Future<ChecklistModel> open({
    String baseUrl = 'http://localhost:8081',
    String token = 'dev',
  }) async {
    final opened = await ChecklistModel.open(
      api: ApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: server.client,
        connectWebSocket: server.connect,
      ),
      cache: cache,
      onUnauthorized: () => unauthorizedCalls++,
    );
    models.add(opened);
    return opened;
  }

  void close(ChecklistModel model) {
    models.remove(model);
    model.dispose();
  }

  Iterable<String> sent() => server.requests
      .where((r) => r.method != 'GET')
      .map((r) => '${r.method} ${r.url.path} ${r.body}'.trim());

  int requestsTo(String path) =>
      server.requests.where((r) => r.url.path == path).length;

  List<String> titles([ChecklistModel? of]) => [
    for (final item in (of ?? model).items) item.title,
  ];

  List<Object?> serverTitles() => [for (final i in server.items) i['title']];

  List<ApiException> failuresOf(ChecklistModel model) {
    final failures = <ApiException>[];
    model.failures.listen(failures.add);
    return failures;
  }

  setUp(() async {
    server = FakeServer();
    cache = MemoryChecklistCache();
    unauthorizedCalls = 0;
    model = await open();
  });

  tearDown(() {
    for (final model in models) {
      model.dispose();
    }
    models.clear();
  });

  test('refresh loads categories in their order and items in list '
      'order', () async {
    server.addCategory('b');
    server.addCategory('A');
    server.addItem('one');
    server.addItem('two');
    server.categoryOrder = [null, 2, 1];

    await model.refresh();

    expect(model.loaded, isTrue);
    expect(model.categories.map((c) => c.name), ['A', 'b']);
    expect(model.categoryOrder, [null, 2, 1]);
    expect(titles(), ['one', 'two']);
  });

  test('a change shows at once and the server keeps it', () async {
    server.addItem('milk');
    await model.refresh();

    model.setChecked([model.items.single.id], true);
    expect(model.items.single.checked, isTrue);
    await pumpEventQueue();

    expect(server.items.single['checked'], isTrue);
    expect(model.items.single.checked, isTrue);
  });

  test('changes to a new item wait for its id from the server', () async {
    await model.refresh();

    final temporary = model.addItem('milk');
    model.setChecked([temporary], true);
    model.renameItem(temporary, 'oat milk');
    expect(model.itemById(temporary)!.title, 'oat milk');
    await pumpEventQueue();

    final id = server.items.single['id'];
    expect(sent(), [
      'POST /api/items {"title":"milk","category_id":null}',
      'PATCH /api/items/$id {"title":"oat milk","checked":true}',
    ]);
    expect(model.items.single.id, id);
    expect(model.itemById(temporary)!.id, id);
    expect(model.keyOf(model.items.single.id), temporary);
  });

  test('offline changes are kept and sent once the server is back', () async {
    final milk = server.addItem('milk');
    await model.refresh();
    server.offline = true;

    model.setChecked([milk['id'] as int], true);
    model.addItem('eggs');
    await expectLater(model.refresh(), throwsA(isA<NetworkException>()));
    expect(model.items.map((i) => (i.title, i.checked)), [
      ('milk', true),
      ('eggs', false),
    ]);
    expect(server.items.single['checked'], isFalse);

    server.offline = false;
    await model.refresh();

    expect(milk['checked'], isTrue);
    expect(serverTitles(), ['milk', 'eggs']);
    expect(titles(), ['milk', 'eggs']);
  });

  test('changes are applied on top of what others changed', () async {
    final milk = server.addItem('milk');
    await model.refresh();
    server.offline = true;

    model.setChecked([milk['id'] as int], true);
    await pumpEventQueue();
    milk['title'] = 'oat milk';
    server.addItem('eggs');
    server.offline = false;
    await model.refresh();

    expect(sent(), ['PATCH /api/items/${milk['id']} {"checked":true}']);
    expect(model.items.map((i) => (i.title, i.checked)), [
      ('oat milk', true),
      ('eggs', false),
    ]);
  });

  test('a change made during a fetch survives its result', () async {
    server.addItem('milk');
    await model.refresh();
    server.gate = Completer();

    final refreshed = model.refresh();
    await pumpEventQueue();
    model.setChecked([model.items.single.id], true);
    server.gate!.complete();
    server.gate = null;
    await refreshed;

    expect(model.items.single.checked, isTrue);
    await pumpEventQueue();
    expect(server.items.single['checked'], isTrue);
  });

  test(
    'a reopened model shows the saved list and sends what was left',
    () async {
      server.addItem('milk');
      await model.refresh();
      server.offline = true;
      model.setChecked([model.items.single.id], true);
      await pumpEventQueue();
      close(model);
      server.requests.clear();

      final reopened = await open();

      expect(reopened.loaded, isTrue);
      expect(reopened.items.single.checked, isTrue);
      expect(server.requests, isEmpty);

      server.offline = false;
      await reopened.refresh();
      expect(server.items.single['checked'], isTrue);
    },
  );

  test('a saved list from another server is ignored', () async {
    server.addItem('milk');
    await model.refresh();
    await pumpEventQueue();

    final other = await open(baseUrl: 'http://other:8081');

    expect(other.loaded, isFalse);
    expect(other.items, isEmpty);
  });

  test('a list saved by the previous version keeps its unsent '
      'changes', () async {
    final milk = server.addItem('milk');
    const at = '2026-10-01T12:00:00.000Z';
    cache.data = jsonEncode({
      'version': 1,
      'server': 'http://localhost:8081',
      'snapshot': {
        'categories': [
          {'id': 5, 'name': 'Groceries', 'created_at': at, 'updated_at': at},
        ],
        'items': [
          {
            'id': milk['id'],
            'title': 'milk',
            'checked': false,
            'category_id': null,
            'created_at': at,
            'updated_at': at,
          },
        ],
      },
      'pending': [
        {'type': 'update_item', 'id': milk['id'], 'checked': true},
      ],
      'next_temp_id': -1,
    });

    final reopened = await open();

    expect(reopened.items.single.checked, isTrue);
    expect(reopened.categoryOrder, [5, null]);
    await reopened.refresh();
    expect(milk['checked'], isTrue);
    await pumpEventQueue();
    final saved = jsonDecode(cache.data!) as Map<String, dynamic>;
    expect(saved['version'], 2);
    expect((saved['snapshot'] as Map)['category_order'], [null]);
  });

  test('a rejected change is dropped and reported', () async {
    server.addItem('milk');
    await model.refresh();
    final failures = failuresOf(model);
    server.failNextWith = 400;

    model.setChecked([model.items.single.id], true);
    await pumpEventQueue();

    expect(failures.single, isA<ServerException>());
    expect(model.items.single.checked, isFalse);
    expect(server.items.single['checked'], isFalse);
  });

  test('a 5xx keeps the change for the next try', () async {
    server.addItem('milk');
    await model.refresh();
    final failures = failuresOf(model);
    server.failNextWith = 503;

    model.setChecked([model.items.single.id], true);
    await pumpEventQueue();
    expect(model.items.single.checked, isTrue);

    await model.refresh();
    expect(server.items.single['checked'], isTrue);
    expect(failures, isEmpty);
  });

  test('deleting an item that was never sent sends nothing', () async {
    await model.refresh();
    server.offline = true;

    final milk = model.addItem('milk');
    await pumpEventQueue();
    model.setChecked([milk], true);
    await pumpEventQueue();
    model.deleteItems([milk]);
    server.offline = false;
    await model.refresh();

    expect(sent(), isEmpty);
    expect(model.items, isEmpty);
  });

  test('deleting an item someone else deleted is not an error', () async {
    server.addItem('milk');
    await model.refresh();
    final failures = failuresOf(model);
    server.items.clear();

    model.deleteItems([model.items.single.id]);
    await pumpEventQueue();

    expect(failures, isEmpty);
    expect(model.items, isEmpty);
  });

  test('checking and deleting several items notifies once', () async {
    for (final title in ['a', 'b', 'c']) {
      server.addItem(title);
    }
    await model.refresh();
    var notified = 0;
    model.addListener(() => notified++);

    model.setChecked([1, 2, 3], true);

    expect(notified, 1);
    expect(model.items.every((i) => i.checked), isTrue);
    await pumpEventQueue();
    expect(sent(), [
      for (final id in [1, 2, 3]) 'PATCH /api/items/$id {"checked":true}',
    ]);

    notified = 0;
    model.deleteItems([1, 2]);

    expect(notified, 1);
    expect(titles(), ['c']);
    await pumpEventQueue();
    expect(serverTitles(), ['c']);
  });

  test('a category made elsewhere meanwhile is used instead', () async {
    await model.refresh();
    server.offline = true;

    final temporary = model.addCategory('Groceries');
    model.addItem('milk', categoryId: temporary);
    final groceries = server.addCategory('groceries');
    server.offline = false;
    await model.refresh();

    expect(server.categories, hasLength(1));
    expect(server.items.single['category_id'], groceries['id']);
    expect(model.categories.single.id, groceries['id']);
    expect(model.categoryById(temporary)!.id, groceries['id']);
    expect(model.items.single.categoryId, groceries['id']);
  });

  test('an item added to a category deleted elsewhere is kept', () async {
    final groceries = server.addCategory('Groceries');
    await model.refresh();
    server.offline = true;

    model.addItem('milk', categoryId: groceries['id'] as int);
    server.categories.clear();
    server.offline = false;
    await model.refresh();

    expect(server.items.single['title'], 'milk');
    expect(server.items.single['category_id'], isNull);
    expect(model.items.single.categoryId, isNull);
  });

  group('idempotency keys', () {
    List<String?> postedKeys() => [
      for (final request in server.requests)
        if (request.method == 'POST') request.headers['Idempotency-Key'],
    ];

    test('every create gets its own, which the saved list keeps and a '
        'reopened model sends', () async {
      await model.refresh();
      server.offline = true;

      final work = model.addCategory('Work');
      model.addItem('report', categoryId: work);
      model.addItems(['milk', 'eggs']);
      await pumpEventQueue();
      final saved = jsonDecode(cache.data!) as Map<String, dynamic>;
      final keys = [
        for (final change in saved['pending'] as List) (change as Map)['key'],
      ];
      close(model);
      final reopened = await open();
      server.offline = false;
      await reopened.refresh();

      expect(keys, hasLength(4));
      expect(keys, everyElement(matches(RegExp(r'^[0-9a-f]{32}$'))));
      expect(keys.toSet(), hasLength(4));
      expect(postedKeys(), keys);
      expect(serverTitles(), ['report', 'milk', 'eggs']);
    });

    test('a create saved before keys existed is sent without one', () async {
      const at = '2026-10-01T12:00:00.000Z';
      cache.data = jsonEncode({
        'version': 2,
        'server': 'http://localhost:8081',
        'snapshot': {'categories': [], 'items': []},
        'pending': [
          {
            'type': 'create_item',
            'id': -1,
            'title': 'milk',
            'category_id': null,
            'created_at': at,
          },
          {
            'type': 'create_category',
            'id': -2,
            'name': 'Work',
            'created_at': at,
          },
        ],
        'next_temp_id': -3,
      });

      final reopened = await open();
      expect(titles(reopened), ['milk']);
      await reopened.refresh();

      expect(serverTitles(), ['milk']);
      expect(server.categories.single['name'], 'Work');
      expect(postedKeys(), [null, null]);
    });

    test('a create whose response was lost is not made twice', () async {
      await model.refresh();
      server.loseNextResponse = true;

      model.addItem('milk');
      await pumpEventQueue();
      expect(serverTitles(), ['milk']);
      await model.refresh();

      final keys = postedKeys();
      expect(keys, hasLength(2));
      expect(keys.first, isNotNull);
      expect(keys.last, keys.first);
      expect(serverTitles(), ['milk']);
      expect(titles(), ['milk']);
    });

    test('a create retried without its deleted category keeps its '
        'key', () async {
      final groceries = server.addCategory('Groceries');
      await model.refresh();
      server.offline = true;

      model.addItem('milk', categoryId: groceries['id'] as int);
      server.categories.clear();
      server.offline = false;
      await model.refresh();

      final keys = postedKeys();
      expect(keys, hasLength(2));
      expect(keys.first, isNotNull);
      expect(keys.last, keys.first);
      expect(serverTitles(), ['milk']);
    });

    test('a resent create of an item deleted elsewhere meanwhile is dropped '
        'quietly, with the changes waiting for it', () async {
      await model.refresh();
      final failures = failuresOf(model);
      server.loseNextResponse = true;

      final milk = model.addItem('milk');
      model.renameItem(milk, 'oat milk');
      await pumpEventQueue();
      server.items.clear();
      await model.refresh();

      expect(sent(), [
        'POST /api/items {"title":"milk","category_id":null}',
        'POST /api/items {"title":"milk","category_id":null}',
      ]);
      expect(failures, isEmpty);
      expect(model.items, isEmpty);
      expect(model.itemById(milk), isNull);
    });
  });

  test('deleting a category uncategorizes its items at once', () async {
    final groceries = server.addCategory('Groceries');
    server.addItem('milk', categoryId: groceries['id'] as int);
    await model.refresh();

    model.deleteCategory(model.categories.single.id);

    expect(model.categories, isEmpty);
    expect(model.categoryOrder, [null]);
    expect(model.items.single.categoryId, isNull);
    await pumpEventQueue();
    expect(server.categories, isEmpty);
  });

  test('a duplicate category name throws and changes nothing', () async {
    server.addCategory('Groceries');
    await model.refresh();

    expect(
      () => model.addCategory('groceries'),
      throwsA(isA<ConflictException>()),
    );

    await pumpEventQueue();
    expect(model.categories.map((c) => c.name), ['Groceries']);
    expect(sent(), isEmpty);
  });

  test('the saved list round-trips every kind of change', () async {
    final groceries = server.addCategory('Groceries');
    server.addItem('milk', categoryId: groceries['id'] as int);
    server.addItem('eggs');
    await model.refresh();
    server.offline = true;

    final milk = model.items.first.id;
    final work = model.addCategory('Work');
    model.renameCategory(groceries['id'] as int, 'Shopping');
    model.setCategoryOrder([work, null, groceries['id'] as int]);
    model.moveItem(milk, const ItemMove(category: (id: null)));
    model.renameItem(model.items.last.id, 'eggs $_link');
    final report = model.addItem('report', categoryId: work);
    model.moveItem(report, ItemMove(before: (id: milk)));
    model.deleteCategory(work);
    model.deleteItems([milk]);
    await pumpEventQueue();
    final saved = jsonDecode(cache.data!) as Map<String, dynamic>;
    final before = [for (final i in model.items) (i.title, i.categoryId)];
    close(model);

    final reopened = await open();

    expect(saved['pending'], hasLength(9));
    expect([for (final i in reopened.items) (i.title, i.categoryId)], before);
    expect(reopened.categories.map((c) => c.name), ['Shopping']);
    expect(reopened.categoryOrder, [null, groceries['id']]);
    expect(reopened.items.last.link, _link);
  });

  test('a 401 calls onUnauthorized and rethrows', () async {
    model = await open(token: 'stale');

    await expectLater(model.refresh(), throwsA(isA<UnauthorizedException>()));

    expect(unauthorizedCalls, 1);
    expect(model.loaded, isFalse);
  });

  group('moving items', () {
    setUp(() async {
      for (final title in ['a', 'b', 'c']) {
        server.addItem(title);
      }
      await model.refresh();
    });

    test('shows at once and sends before_id', () async {
      model.moveItem(3, const ItemMove(before: (id: 1)));

      expect(titles(), ['c', 'a', 'b']);
      await pumpEventQueue();
      expect(sent(), ['PATCH /api/items/3 {"before_id":1}']);
      expect(serverTitles(), ['c', 'a', 'b']);
      expect(titles(), ['c', 'a', 'b']);

      model.moveItem(3, const ItemMove(before: (id: null)));

      expect(titles(), ['a', 'b', 'c']);
      await pumpEventQueue();
      expect(serverTitles(), ['a', 'b', 'c']);
    });

    test('one drop is one request', () async {
      final groceries = server.addCategory('Groceries');
      await model.refresh();
      final id = groceries['id'];

      model.moveItem(
        1,
        ItemMove(checked: true, category: (id: id as int), before: (id: null)),
      );
      await pumpEventQueue();

      expect(sent(), [
        'PATCH /api/items/1 {"checked":true,"category_id":$id,"before_id":null}',
      ]);
      expect(model.items.last.categoryId, id);
    });

    test('waits for the ids of new items and categories', () async {
      server.offline = true;

      final later = model.addCategory('Later');
      final d = model.addItem('d');
      final e = model.addItem('e');
      model.moveItem(e, ItemMove(category: (id: later), before: (id: d)));
      expect(titles(), ['a', 'b', 'c', 'e', 'd']);
      server.offline = false;
      await model.refresh();

      final ids = {for (final i in server.items) i['title']: i['id']};
      expect(sent(), [
        'POST /api/categories {"name":"Later"}',
        'POST /api/items {"title":"d","category_id":null}',
        'POST /api/items {"title":"e","category_id":null}',
        'PATCH /api/items/${ids['e']} '
            '{"category_id":${server.categories.single['id']},'
            '"before_id":${ids['d']}}',
      ]);
      expect(serverTitles(), ['a', 'b', 'c', 'e', 'd']);
      expect(titles(), ['a', 'b', 'c', 'e', 'd']);
    });

    test('later changes to the same item merge while they wait', () async {
      final gate = server.gate = Completer();
      model.renameItem(2, 'B');
      await pumpEventQueue();

      model.moveItem(1, const ItemMove(before: (id: 3)));
      model.renameItem(1, 'A');
      model.moveItem(1, const ItemMove(before: (id: null)));
      expect(titles(), ['B', 'c', 'A']);
      server.gate = null;
      gate.complete();
      await model.refresh();

      expect(sent(), [
        'PATCH /api/items/2 {"title":"B"}',
        'PATCH /api/items/1 {"title":"A","before_id":null}',
      ]);
      expect(serverTitles(), ['B', 'c', 'A']);
    });

    test('a move before an item that is never created is dropped', () async {
      final gate = server.gate = Completer();
      model.renameItem(3, 'C');
      await pumpEventQueue();
      final d = model.addItem('d');

      model.moveItem(1, ItemMove(before: (id: d)));
      model.moveItem(2, ItemMove(checked: true, before: (id: d)));
      expect(titles(), ['C', 'a', 'b', 'd']);
      model.deleteItems([d]);
      expect(titles(), ['a', 'b', 'C']);
      server.gate = null;
      gate.complete();
      await model.refresh();

      expect(sent(), [
        'PATCH /api/items/3 {"title":"C"}',
        'PATCH /api/items/2 {"checked":true}',
      ]);
      expect(serverTitles(), ['a', 'b', 'C']);
    });

    test('a move made during a fetch survives its result', () async {
      server.gate = Completer();

      final refreshed = model.refresh();
      await pumpEventQueue();
      model.moveItem(3, const ItemMove(before: (id: 1)));
      server.addItem('d');
      server.gate!.complete();
      server.gate = null;
      await refreshed;

      expect(titles(), ['c', 'a', 'b', 'd']);
      await pumpEventQueue();
      expect(serverTitles(), ['c', 'a', 'b', 'd']);
    });

    test('a 400 retries without before_id, then without the '
        'category', () async {
      final gone = server.addCategory('Gone');
      await model.refresh();
      final failures = failuresOf(model);
      server.categories.clear();
      server.items.removeWhere((i) => i['id'] == 3);

      model.moveItem(
        1,
        ItemMove(
          checked: true,
          category: (id: gone['id'] as int),
          before: (id: 3),
        ),
      );
      await pumpEventQueue();

      final category = gone['id'];
      expect(sent(), [
        'PATCH /api/items/1 {"checked":true,"category_id":$category,"before_id":3}',
        'PATCH /api/items/1 {"checked":true,"category_id":$category}',
        'PATCH /api/items/1 {"checked":true}',
      ]);
      expect(failures, isEmpty);
      expect(server.items.first['checked'], isTrue);
      expect(titles(), ['a', 'b']);
      expect(model.categories, isEmpty);
    });

    test('a rejected move with nothing else is dropped and '
        'reported', () async {
      final failures = failuresOf(model);
      server.items.removeWhere((i) => i['id'] == 3);

      model.moveItem(1, const ItemMove(before: (id: 3)));
      await pumpEventQueue();

      expect(sent(), ['PATCH /api/items/1 {"before_id":3}']);
      expect(failures.single, isA<ServerException>());
      expect(titles(), ['a', 'b']);
    });

    test('several into a category show at once with one notification and '
        'are replayed in order, to the end', () async {
      server.offline = true;
      final later = model.addCategory('Later');
      var notified = 0;
      model.addListener(() => notified++);

      model.moveItems([1, 3], later);

      expect(notified, 1);
      expect(titles(), ['b', 'a', 'c']);
      expect([for (final i in model.items) i.categoryId], [null, later, later]);
      server.offline = false;
      await model.refresh();

      final category = server.categories.single['id'];
      expect(sent(), [
        'POST /api/categories {"name":"Later"}',
        for (final id in [1, 3])
          'PATCH /api/items/$id {"category_id":$category,"before_id":null}',
      ]);
      expect(serverTitles(), ['b', 'a', 'c']);
      expect(titles(), ['b', 'a', 'c']);
      expect(
        [for (final i in model.items) i.categoryId],
        [null, category, category],
      );
    });
  });

  group('adding several items', () {
    setUp(() async {
      for (final title in ['a', 'b', 'c']) {
        server.addItem(title);
      }
      await model.refresh();
    });

    test('adds them in order with one notification', () async {
      final groceries = server.addCategory('Groceries');
      await model.refresh();
      final category = groceries['id'] as int;
      var notified = 0;
      model.addListener(() => notified++);

      final ids = model.addItems(['x', 'y'], categoryId: category);

      expect(notified, 1);
      expect(ids, hasLength(2));
      expect(ids.every((id) => id < 0), isTrue);
      expect(titles(), ['a', 'b', 'c', 'x', 'y']);
      expect(
        [for (final id in ids) model.itemById(id)!.categoryId],
        [category, category],
      );
      await pumpEventQueue();

      expect(sent(), [
        'POST /api/items {"title":"x","category_id":$category}',
        'POST /api/items {"title":"y","category_id":$category}',
      ]);
      expect(serverTitles(), ['a', 'b', 'c', 'x', 'y']);
      expect(model.itemById(ids.last)!.id, server.items.last['id']);
    });

    test('checked and directly before an item', () async {
      final ids = model.addItems(['x', 'y'], checked: true, before: 2);

      expect(titles(), ['a', 'x', 'y', 'b', 'c']);
      expect([for (final id in ids) model.itemById(id)!.checked], [true, true]);
      await pumpEventQueue();

      final [_, x, y, ..._] = [for (final i in server.items) i['id']];
      expect(sent(), [
        'POST /api/items {"title":"x","category_id":null}',
        'PATCH /api/items/$x {"checked":true,"before_id":2}',
        'POST /api/items {"title":"y","category_id":null}',
        'PATCH /api/items/$y {"checked":true,"before_id":2}',
      ]);
      expect(serverTitles(), ['a', 'x', 'y', 'b', 'c']);
      expect(titles(), ['a', 'x', 'y', 'b', 'c']);
    });

    test('wait offline for the ids of new items and categories', () async {
      server.offline = true;
      final later = model.addCategory('Later');
      final d = model.addItem('d');

      model.addItems(['x', 'y'], categoryId: later, before: d);
      expect(titles(), ['a', 'b', 'c', 'x', 'y', 'd']);
      server.offline = false;
      await model.refresh();

      final category = server.categories.single['id'];
      expect(serverTitles(), ['a', 'b', 'c', 'x', 'y', 'd']);
      expect(
        server.items.where((i) => ['x', 'y'].contains(i['title'])),
        everyElement(containsPair('category_id', category)),
      );
      expect(titles(), ['a', 'b', 'c', 'x', 'y', 'd']);
    });
  });

  group('category order', () {
    test('shows at once and is saved', () async {
      server.addCategory('A');
      server.addCategory('B');
      await model.refresh();
      expect(model.categoryOrder, [1, 2, null]);

      model.setCategoryOrder([null, 2, 1]);

      expect(model.categoryOrder, [null, 2, 1]);
      expect(model.categories.map((c) => c.name), ['B', 'A']);
      await pumpEventQueue();
      expect(sent(), ['PUT /api/categories/order {"order":[null,2,1]}']);
      expect(server.categoryOrder, [null, 2, 1]);
    });

    test('a new category goes before Uncategorized only when that is '
        'last', () async {
      server.addCategory('A');
      await model.refresh();
      server.offline = true;

      final b = model.addCategory('B');
      expect(model.categoryOrder, [1, b, null]);
      model.setCategoryOrder([null, 1, b]);
      final c = model.addCategory('C');
      expect(model.categoryOrder, [null, 1, b, c]);
      server.offline = false;
      await model.refresh();

      final ids = {for (final c in server.categories) c['name']: c['id']};
      expect(sent(), [
        'POST /api/categories {"name":"B"}',
        'PUT /api/categories/order {"order":[null,1,${ids['B']}]}',
        'POST /api/categories {"name":"C"}',
      ]);
      expect(model.categoryOrder, [null, 1, ids['B'], ids['C']]);
      expect(
        [
          for (final id in model.categoryOrder)
            id == null ? null : model.keyOf(id),
        ],
        [null, 1, b, c],
      );
    });

    test('deleting a category leaves the rest of the order', () async {
      for (final name in ['A', 'B', 'C']) {
        server.addCategory(name);
      }
      server.categoryOrder = [3, null, 1, 2];
      await model.refresh();

      model.deleteCategory(1);

      expect(model.categoryOrder, [3, null, 2]);
      await model.refresh();
      expect(model.categoryOrder, [3, null, 2]);
    });

    test('is fitted to categories made or deleted elsewhere', () async {
      server.addCategory('A');
      server.addCategory('B');
      await model.refresh();
      final failures = failuresOf(model);
      server.addCategory('C');
      server.categories.removeAt(0);

      model.setCategoryOrder([2, null, 1]);
      await pumpEventQueue();

      expect(sent(), [
        'PUT /api/categories/order {"order":[2,null,1]}',
        'PUT /api/categories/order {"order":[2,null,3]}',
      ]);
      expect(failures, isEmpty);
      expect(model.categoryOrder, [2, null, 3]);
      expect(model.categories.map((c) => c.name), ['B', 'C']);
    });

    test('is dropped and reported when the retry is rejected too', () async {
      server.addCategory('A');
      await model.refresh();
      final failures = failuresOf(model);
      server.failWhen = (request) => request.method == 'PUT' ? 400 : null;

      model.setCategoryOrder([null, 1]);
      await pumpEventQueue();

      expect(sent(), [
        'PUT /api/categories/order {"order":[null,1]}',
        'PUT /api/categories/order {"order":[null,1]}',
      ]);
      expect(failures.single, isA<ServerException>());
      expect(model.categoryOrder, [1, null]);
    });

    test('unsent orders merge', () async {
      server.addCategory('A');
      server.addCategory('B');
      await model.refresh();
      final gate = server.gate = Completer();
      model.renameCategory(1, 'A2');
      await pumpEventQueue();

      model.setCategoryOrder([null, 1, 2]);
      model.setCategoryOrder([2, null, 1]);
      model.setCategoryOrder([2, 1, null]);
      server.gate = null;
      gate.complete();
      await model.refresh();

      expect(sent(), [
        'PATCH /api/categories/1 {"name":"A2"}',
        'PUT /api/categories/order {"order":[2,1,null]}',
      ]);
      expect(model.categoryOrder, [2, 1, null]);
    });
  });

  group('previews', () {
    const preview = Preview(title: 'A post', siteName: 'Example');
    const previewJson = {'title': 'A post', 'site_name': 'Example'};

    test('come from responses and are only ever added', () async {
      server.previews[_link] = previewJson;
      server.addItem('Read $_link');
      await model.refresh();

      expect(model.previewOf(model.items.single), preview);

      server.previews.remove(_link);
      await model.refresh();

      expect(model.items.single.preview, isNull);
      expect(model.previewOf(model.items.single), preview);
    });

    test('a new item gets its preview from the create response', () async {
      server.previews[_link] = previewJson;
      await model.refresh();

      final id = model.addItem('Read $_link');
      expect(model.previewOf(model.itemById(id)!), isNull);
      await pumpEventQueue();

      expect(model.previewOf(model.itemById(id)!), preview);
    });

    test('an item renamed to a known link shows its preview at '
        'once', () async {
      server.previews[_link] = previewJson;
      server.addItem('Read $_link');
      final milk = server.addItem('milk')['id'] as int;
      await model.refresh();

      model.renameItem(milk, 'also $_link');
      expect(model.previewOf(model.itemById(milk)!), preview);

      model.renameItem(milk, 'milk');
      expect(model.previewOf(model.itemById(milk)!), isNull);
    });

    test('events bring previews, which are saved', () async {
      server.addItem('Read $_link');
      await model.refresh();
      model.followEvents();
      await pumpEventQueue();
      expect(server.eventClients, 1);
      var notified = 0;
      model.addListener(() => notified++);

      server.pushPreview(_link, previewJson);
      await pumpEventQueue();

      expect(notified, 1);
      expect(model.previewOf(model.items.single), preview);
      final other = model.addItem('again $_link');
      expect(model.previewOf(model.itemById(other)!), preview);
      await pumpEventQueue();
      close(model);

      final reopened = await open();
      expect(reopened.previewOf(reopened.items.first), preview);
    });
  });

  group('events', () {
    test('following twice keeps one socket; stopping closes it', () async {
      model.followEvents();
      model.followEvents();
      await pumpEventQueue();

      expect(server.eventClients, 1);
      expect(server.eventConnects, 1);

      model.stopEvents();
      await pumpEventQueue();

      expect(server.eventClients, 0);
      model.followEvents();
      await pumpEventQueue();
      expect(server.eventClients, 1);
    });

    test('dispose closes the socket', () async {
      model.followEvents();
      await pumpEventQueue();

      close(model);
      await pumpEventQueue();

      expect(server.eventClients, 0);
    });

    testWidgets('every ready refreshes, the first one too, since events are '
        'not replayed', (tester) async {
      final model = await open();
      server.addItem('milk');
      model.followEvents();
      await tester.pump();

      expect(server.eventClients, 1);
      expect(requestsTo('/api/items'), 1);
      expect(titles(model), ['milk']);

      server.addItem('eggs');
      server.closeEvents();
      await tester.pump(const Duration(seconds: 1));

      expect(server.eventClients, 1);
      expect(requestsTo('/api/items'), 2);
      expect(titles(model), ['milk', 'eggs']);
      close(model);
    });

    testWidgets('a change made elsewhere refreshes once no changed event has '
        'come for 300 ms', (tester) async {
      final model = await open();
      model.followEvents();
      await tester.pump();
      expect(requestsTo('/api/items'), 1);

      server.addItem('milk');
      for (var i = 0; i < 3; i++) {
        server.sendEvent({'type': 'changed'});
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump(const Duration(milliseconds: 99));
      expect(requestsTo('/api/items'), 1);
      await tester.pump(const Duration(milliseconds: 1));

      expect(requestsTo('/api/items'), 2);
      expect(titles(model), ['milk']);
      close(model);
    });

    testWidgets('a write refreshes the other clients, not the one that made '
        'it', (tester) async {
      server.addItem('milk');
      final model = await open();
      final other = await open();
      model.followEvents();
      other.followEvents();
      await tester.pump();
      final fetches = requestsTo('/api/items');

      model.setChecked([model.items.single.id], true);
      await tester.pump(const Duration(seconds: 1));

      expect(server.items.single['checked'], isTrue);
      expect(requestsTo('/api/items'), fetches + 1);
      expect(other.items.single.checked, isTrue);
      close(model);
      close(other);
    });

    testWidgets('a rejected token calls onUnauthorized and stops', (
      tester,
    ) async {
      final model = await open(token: 'stale');

      model.followEvents();
      await tester.pump(const Duration(minutes: 1));

      expect(unauthorizedCalls, 1);
      expect(server.eventConnects, 1);
      close(model);
    });

    testWidgets('reconnects after 1s, doubling to 30s, until a ready resets '
        'it', (tester) async {
      final model = await open();
      server.refuseEvents = true;

      model.followEvents();
      await tester.pump();
      expect(server.eventConnects, 1);
      var attempts = 1;
      for (final seconds in [1, 2, 4, 8, 16, 30, 30]) {
        await tester.pump(Duration(seconds: seconds, milliseconds: -1));
        expect(server.eventConnects, attempts);
        await tester.pump(const Duration(milliseconds: 1));
        expect(server.eventConnects, ++attempts);
      }

      server.refuseEvents = false;
      await tester.pump(const Duration(seconds: 30));
      expect(server.eventClients, 1);
      server.closeEvents();
      await tester.pump(const Duration(seconds: 1));

      expect(server.eventClients, 1);
      expect(unauthorizedCalls, 0);
      close(model);
    });

    testWidgets('a ping keeps the socket open; 40 s of silence closes it and '
        'reconnects', (tester) async {
      final model = await open();
      model.followEvents();
      await tester.pump();

      await tester.pump(const Duration(seconds: 30));
      server.sendEvent({'type': 'ping'});
      await tester.pump(const Duration(seconds: 39));
      expect(server.eventClients, 1);
      expect(server.eventConnects, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(server.eventClients, 0);
      await tester.pump(const Duration(seconds: 1));

      expect(server.eventConnects, 2);
      expect(server.eventClients, 1);
      close(model);
    });
  });

  group('held server updates', () {
    test('fetches and events wait for the release; local changes '
        'do not', () async {
      final milk = server.addItem('milk')['id'] as int;
      server.addItem('eggs');
      await model.refresh();
      model.followEvents();
      await pumpEventQueue();

      model.holdServerUpdates();
      server.items.last['title'] = 'duck eggs';
      server.addItem('Read $_link');
      await model.refresh();
      server.pushPreview(_link, {'title': 'A post'});
      await pumpEventQueue();
      model.setChecked([milk], true);
      await pumpEventQueue();

      expect(titles(), ['milk', 'eggs']);
      expect(model.items.first.checked, isTrue);
      expect(server.items.first['checked'], isTrue);

      model.releaseServerUpdates();

      expect(titles(), ['milk', 'duck eggs', 'Read $_link']);
      expect(model.items.first.checked, isTrue);
      expect(model.previewOf(model.items.last), const Preview(title: 'A post'));
    });

    test('holds nest', () async {
      await model.refresh();
      model.holdServerUpdates();
      model.holdServerUpdates();
      server.addItem('milk');
      await model.refresh();

      model.releaseServerUpdates();
      expect(model.items, isEmpty);
      model.releaseServerUpdates();
      expect(titles(), ['milk']);
      model.releaseServerUpdates();
      expect(titles(), ['milk']);
    });
  });
}
